#!/usr/bin/env python3
"""
tools/nx-tools/prepare_switch_assets.py

Generates the Nintendo Switch cutscene assets (Sparrow sheets + Vorbis audio) from the ORIGINAL
videos shipped in the official Funkin.assets submodule (assets/videos/videos/*.mp4|*.mkv).

Nothing derived from the official content is committed anywhere: every developer generates these
files locally on the first Switch build (project.hxp runs this script automatically) and the output
lives in export/nx-generated/, which is ignored by git.

Every audio track is validated against lime-nx's OGG decoder bug (INC-37): lime allocates
ov_pcm_total * channels * 2 bytes and calls ov_read until EOF without bounds checks, so a file that
decodes more samples than it declares corrupts the heap. Audio is always encoded through a WAV
intermediate; if a file still overflows, alternative encodings are tried automatically.

Usage:
    python3 tools/nx-tools/prepare_switch_assets.py              # generate what is missing or outdated
    python3 tools/nx-tools/prepare_switch_assets.py --force      # regenerate everything
    python3 tools/nx-tools/prepare_switch_assets.py --verify     # only verify the generated audio
    python3 tools/nx-tools/prepare_switch_assets.py --censored   # also generate censored variants

Requirements: ffmpeg, Pillow, gcc + libvorbis development files (for the overflow verifier).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.abspath(os.path.join(TOOLS_DIR, "..", ".."))
SOURCE_DIR = os.path.join(REPO_DIR, "assets", "videos", "videos")
OUTPUT_DIR = os.path.join(REPO_DIR, "export", "nx-generated", "videos", "converted")
MANIFEST = os.path.join(OUTPUT_DIR, "manifest.json")
CHECKER_SRC = os.path.join(TOOLS_DIR, "check_ogg_overflow.c")

# Bump when the conversion pipeline changes, so existing outputs are regenerated.
PIPELINE_VERSION = 2

# Cutscenes used by the game scripts, with the parameters tuned for Switch memory and frame budget
# (sheet streaming in NXVideoPlayer keeps at most 2 sheets in RAM).
CUTSCENES = {
    "darnellCutscene": {"fps": 12, "width": 480, "height": 270},
    "2hotCutscene": {"fps": 16, "width": 512, "height": 288},
    "blazinCutscene": {"fps": 16, "width": 512, "height": 288},
    "ughCutscene": {"fps": 18, "width": 640, "height": 360},
    "gunsCutscene": {"fps": 18, "width": 640, "height": 360},
    "stressCutscene": {"fps": 16, "width": 512, "height": 288},
    "stressPicoCutscene": {"fps": 16, "width": 512, "height": 288},
}
CENSORED = ["darnellCutscene-censored", "stressCutscene-censored", "stressPicoCutscene-censored"]

sys.path.insert(0, TOOLS_DIR)
import convert_video  # noqa: E402  (extract_frames, pack_sparrow_atlas)


def log(msg):
    print(f"[prepare_switch_assets] {msg}", flush=True)


def find_source(name):
    for ext in (".mp4", ".mkv", ".webm"):
        path = os.path.join(SOURCE_DIR, name + ext)
        if os.path.exists(path):
            return path
    return None


def load_manifest():
    try:
        with open(MANIFEST) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_manifest(data):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    with open(MANIFEST, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)


def source_signature(path, params):
    st = os.stat(path)
    return {"size": st.st_size, "mtime": int(st.st_mtime), "params": params, "pipeline": PIPELINE_VERSION}


def outputs_exist(name):
    return os.path.exists(os.path.join(OUTPUT_DIR, name + ".ogg")) and (
        os.path.exists(os.path.join(OUTPUT_DIR, name + ".png")) or os.path.exists(os.path.join(OUTPUT_DIR, name + "_0.png"))
    )


def build_checker(workdir):
    """Compiles the libvorbisfile-based overflow checker. Returns its path or None."""
    if shutil.which("gcc") is None:
        return None
    binary = os.path.join(workdir, "check_ogg_overflow")
    res = subprocess.run(["gcc", "-O2", "-o", binary, CHECKER_SRC, "-lvorbisfile"], capture_output=True, text=True)
    if res.returncode != 0:
        log(f"WARNING: cannot build the OGG overflow checker (install libvorbis headers): {res.stderr.strip()}")
        return None
    return binary


def check_overflow(checker, ogg):
    """Returns (ok, extra_bytes). ok=None if the checker is unavailable."""
    if checker is None:
        return None, 0
    out = subprocess.run([checker, ogg], capture_output=True, text=True).stdout.strip().split()
    if not out:
        return False, -1
    return out[0] == "ok", int(out[3]) if len(out) > 3 else 0


def run(cmd):
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:4])}...: {res.stderr.strip()[-400:]}")


def make_audio(source, output_ogg, checker, workdir):
    """Encodes the audio through a WAV intermediate and validates it; tries alternatives if needed."""
    wav = os.path.join(workdir, "audio.wav")
    run(["ffmpeg", "-y", "-v", "error", "-i", source, "-vn", "-f", "wav", wav])
    variants = [
        ("q5", ["-acodec", "libvorbis", "-aq", "5"]),
        ("q6", ["-acodec", "libvorbis", "-aq", "6"]),
        ("q5-48k", ["-acodec", "libvorbis", "-aq", "5", "-ar", "48000"]),
        ("q5-44k", ["-acodec", "libvorbis", "-aq", "5", "-ar", "44100"]),
    ]
    for label, args in variants:
        run(["ffmpeg", "-y", "-v", "error", "-i", wav] + args + [output_ogg])
        ok, extra = check_overflow(checker, output_ogg)
        if ok is None:
            log(f"  audio encoded ({label}), NOT verified (checker unavailable)")
            return
        if ok:
            log(f"  audio encoded ({label}), verified: no decoder overflow")
            return
        log(f"  audio variant {label} overflows lime's decoder by {extra} bytes, trying the next one...")
    raise RuntimeError(f"every audio variant overflows lime's OGG decoder: {output_ogg}")


def convert(name, params, checker):
    source = find_source(name)
    if source is None:
        log(f"SKIP {name}: no source video in {SOURCE_DIR}")
        return False
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    base = os.path.join(OUTPUT_DIR, name)
    for f in os.listdir(OUTPUT_DIR):
        if f == name + ".ogg" or f.startswith(name + ".") or f.startswith(name + "_"):
            os.remove(os.path.join(OUTPUT_DIR, f))

    log(f"Converting {name} ({params['fps']} fps, {params['width']}x{params['height']}) from {os.path.relpath(source, REPO_DIR)}")
    with tempfile.TemporaryDirectory(prefix="nxconv_") as tmp:
        make_audio(source, base + ".ogg", checker, tmp)
        frames_dir = os.path.join(tmp, "frames")
        os.makedirs(frames_dir)
        frames = convert_video.extract_frames(source, frames_dir, params["fps"], params["width"], params["height"])
        convert_video.pack_sparrow_atlas(frames_dir, frames, base, params["width"], params["height"], fps=params["fps"])
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", action="store_true", help="regenerate every cutscene")
    parser.add_argument("--verify", action="store_true", help="only verify the generated audio")
    parser.add_argument("--censored", action="store_true", help="also generate the censored cutscene variants")
    args = parser.parse_args()

    for tool in ("ffmpeg",):
        if shutil.which(tool) is None:
            log(f"ERROR: {tool} not found in PATH")
            return 1

    jobs = dict(CUTSCENES)
    if args.censored:
        for name in CENSORED:
            jobs[name] = CUTSCENES[name.replace("-censored", "")]

    with tempfile.TemporaryDirectory(prefix="nxcheck_") as tmp:
        checker = build_checker(tmp)
        if args.verify:
            bad = 0
            for name in jobs:
                ogg = os.path.join(OUTPUT_DIR, name + ".ogg")
                if not os.path.exists(ogg):
                    continue
                ok, extra = check_overflow(checker, ogg)
                log(f"{name}.ogg: {'ok' if ok else ('UNVERIFIED' if ok is None else f'OVERFLOW +{extra} bytes')}")
                bad += 0 if ok else 1
            return 1 if bad else 0

        manifest = load_manifest()
        converted = 0
        for name, params in jobs.items():
            source = find_source(name)
            if source is None:
                log(f"SKIP {name}: source video not found")
                continue
            signature = source_signature(source, params)
            if not args.force and manifest.get(name) == signature and outputs_exist(name):
                continue
            try:
                if convert(name, params, checker):
                    manifest[name] = signature
                    save_manifest(manifest)
                    converted += 1
            except Exception as e:  # noqa: BLE001
                log(f"ERROR converting {name}: {e}")
                return 1
        log(f"Done: {converted} converted, {len(jobs) - converted} up to date. Output: {os.path.relpath(OUTPUT_DIR, REPO_DIR)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
