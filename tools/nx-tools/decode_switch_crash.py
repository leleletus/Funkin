#!/usr/bin/env python3
"""
Decode native Nintendo Switch crash addresses into C++/Haxe file:line using
aarch64-none-elf-addr2line against the Funkin.elf produced by `lime build switch`.

Supported inputs (auto-detected, can be mixed in one file):
  * Citron / yuzu backtraces (citron_log.txt):
        Funkin.nro          0000000080123456 0000000080123456 0000000000123456 symbol
    -> the 4th column (module offset) is used.
  * Atmosphere crash reports from real hardware (/atmosphere/crash_reports/*.log):
        ReturnAddress[00]:       0000007100abcdef (Funkin + 0xabcdef)
    -> any "(<module> + 0x<offset>)" is used.
  * Haxe crash-*.log files (already symbolic "in file#line" frames are echoed as-is).
  * Raw addresses given on the command line or in a file (0x...). Absolute addresses
    need --base <module load address>; small values are treated as ELF offsets.

Usage:
  decode_switch_crash.py [FILE ...]                 # decode files (default: citron_log.txt + newest crash-*.log)
  decode_switch_crash.py --addr 0x123456 0x7890ab   # decode raw offsets
  decode_switch_crash.py --addr 0x80123456 --base 0x80004000
  decode_switch_crash.py --elf path/to/Funkin.elf FILE
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_ELF = os.path.join(REPO, "export", "release", "switch", "bin", "Funkin.elf")
ADDR2LINE_CANDIDATES = [
    "/opt/devkitpro/devkitA64/bin/aarch64-none-elf-addr2line",
    "aarch64-none-elf-addr2line",
]
CITRON_LOG = os.path.expanduser("~/.local/share/citron/log/citron_log.txt")
SDMC_LOGS = os.path.expanduser("~/.local/share/citron/sdmc/switch/Friday-Night-Funkin/logs")

# Citron/yuzu: "<module>  <address> <original_address> <offset> [symbol]"
RE_CITRON = re.compile(r"(?P<module>[\w.\-]+)\s+(?P<addr>[0-9A-Fa-f]{16})\s+(?P<orig>[0-9A-Fa-f]{16})\s+(?P<off>[0-9A-Fa-f]{16})(?:\s+(?P<sym>\S.*))?$")
# Atmosphere: "(Funkin + 0xabcdef)"
RE_AMS = re.compile(r"\((?P<module>[\w.\-]+)\s*\+\s*0x(?P<off>[0-9A-Fa-f]+)\)")
# Citron fault lines, e.g. "Unmapped Write64 @ 0x..." or "pc=..."
RE_FAULT = re.compile(r"(Unmapped|Invalid memory|Data Abort|Prefetch Abort|svcBreak|Backtrace|panic|Fatal)", re.I)
# Haxe frames: "in funkin/play/PlayState.hx#1053"
RE_HAXE = re.compile(r"^\s*in\s+\S+#\d+")
RE_RAW = re.compile(r"0x[0-9A-Fa-f]+")

GAME_MODULES = ("funkin", "funkin.nro", "main", "application")


def find_addr2line():
    for cand in ADDR2LINE_CANDIDATES:
        path = cand if os.path.isabs(cand) else shutil.which(cand)
        if path and os.path.exists(path):
            return path
    sys.exit("ERROR: aarch64-none-elf-addr2line not found (install devkitA64 under /opt/devkitpro).")


def addr2line(tool, elf, offsets):
    """Returns {offset: [(function, file:line), ...]} (inlined frames included)."""
    if not offsets:
        return {}
    out = subprocess.run(
        [tool, "-e", elf, "-f", "-C", "-i", "-a"] + [hex(o) for o in offsets],
        capture_output=True, text=True, check=False,
    ).stdout.splitlines()
    result, current = {}, None
    i = 0
    while i < len(out):
        line = out[i].strip()
        if line.startswith("0x") and re.fullmatch(r"0x[0-9a-fA-F]+", line):
            current = int(line, 16)
            result[current] = []
            i += 1
            continue
        if current is not None and i + 1 < len(out):
            result[current].append((line, out[i + 1].strip()))
            i += 2
            continue
        i += 1
    return result


def is_game_module(name):
    return name.lower() in GAME_MODULES or name.lower().startswith("funkin")


def collect_from_text(text):
    """Returns (frames, context) where frames is a list of (label, offset or None, raw line)."""
    frames, context = [], []
    for raw in text.splitlines():
        line = raw.rstrip()
        m = RE_CITRON.search(line)
        if m:
            off = int(m.group("off"), 16) if is_game_module(m.group("module")) else None
            frames.append((m.group("module"), off, line.strip()))
            continue
        ams = RE_AMS.findall(line)
        if ams:
            for module, off in ams:
                frames.append((module, int(off, 16) if is_game_module(module) else None, line.strip()))
            continue
        if RE_HAXE.match(line):
            frames.append(("haxe", None, line.strip()))
            continue
        if RE_FAULT.search(line):
            context.append(line.strip())
    return frames, context


def default_inputs():
    files = []
    if os.path.exists(CITRON_LOG):
        files.append(CITRON_LOG)
    crashes = sorted(glob.glob(os.path.join(SDMC_LOGS, "crash-*.log")), key=os.path.getmtime)
    if crashes:
        files.append(crashes[-1])
    return files


def print_frame(label, off, raw, symbols):
    if off is None:
        print(f"  {raw}")
        return
    entries = symbols.get(off) or [("??", "??:0")]
    first = True
    for func, loc in entries:
        prefix = f"  [{label}+0x{off:x}]" if first else "      (inlined by)"
        print(f"{prefix} {func}\n        at {loc}")
        first = False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="log files to scan (default: citron_log.txt + newest crash-*.log)")
    ap.add_argument("--elf", default=DEFAULT_ELF, help=f"ELF with debug info (default: {DEFAULT_ELF})")
    ap.add_argument("--addr", nargs="+", help="raw addresses/offsets to decode")
    ap.add_argument("--base", help="module load address to subtract from absolute --addr values / raw hex in files")
    ap.add_argument("--max-frames", type=int, default=64, help="max native frames to print per file")
    args = ap.parse_args()

    if not os.path.exists(args.elf):
        sys.exit(f"ERROR: ELF not found: {args.elf} (build first: haxelib run lime build switch -release)")
    tool = find_addr2line()
    base = int(args.base, 16) if args.base else 0

    if args.addr:
        offsets = []
        for a in args.addr:
            v = int(a, 16)
            offsets.append(v - base if base and v >= base else v)
        symbols = addr2line(tool, args.elf, offsets)
        print(f"== Raw addresses (base=0x{base:x}) against {args.elf}")
        for o in offsets:
            print_frame("Funkin", o, "", symbols)
        return

    files = args.files or default_inputs()
    if not files:
        sys.exit("No input files found. Pass a log file or --addr.")

    for path in files:
        try:
            with open(path, "r", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print(f"== {path}: cannot read ({e})")
            continue

        frames, context = collect_from_text(text)
        if base:
            # Raw absolute addresses inside the file (e.g. pasted register dumps).
            for raw in RE_RAW.findall(text):
                v = int(raw, 16)
                if v >= base:
                    frames.append(("Funkin", v - base, raw))

        native = [f for f in frames if f[1] is not None][: args.max_frames]
        symbols = addr2line(tool, args.elf, sorted({f[1] for f in native}))

        print(f"== {path}")
        if context:
            print("-- Fault context:")
            for c in context[-15:]:
                print(f"  {c}")
        if not frames:
            print("-- No backtrace frames found.")
            continue
        print(f"-- Frames ({len(native)} native, {len(frames) - len(native)} other):")
        shown = 0
        for label, off, raw in frames:
            if off is not None:
                if shown >= args.max_frames:
                    continue
                shown += 1
            print_frame(label, off, raw, symbols)


if __name__ == "__main__":
    main()
