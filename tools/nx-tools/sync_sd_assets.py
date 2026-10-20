#!/usr/bin/env python3
"""
Writes the official asset files listed in an installer manifest into a folder, straight from the git objects of the
assets submodule: the SD card of Citron, or a folder to copy to the console over MTP/FTP. Files that already have
the right size are skipped. This is the "copied from a computer" case of the installer.

  python3 tools/nx-tools/sync_sd_assets.py                                  # Citron's SD card
  python3 tools/nx-tools/sync_sd_assets.py --dest /path/to/sd/switch/Friday-Night-Funkin/assets
  python3 tools/nx-tools/sync_sd_assets.py --clear                          # empty Citron's assets folder
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
DEFAULT_MANIFEST = os.path.join(ROOT, 'export', 'release', 'switch', 'sd-romfs', 'nx', 'assets-manifest.tsv')
CITRON_ASSETS = os.path.expanduser('~/.local/share/citron/sdmc/switch/Friday-Night-Funkin/assets')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--manifest', default=DEFAULT_MANIFEST)
    ap.add_argument('--dest', default=CITRON_ASSETS)
    ap.add_argument('--clear', action='store_true', help='delete the destination folder instead')
    args = ap.parse_args()

    if args.clear:
        if os.path.basename(os.path.normpath(args.dest)) != 'assets':
            sys.exit('[sync_sd_assets] --clear only removes a folder named "assets"')
        shutil.rmtree(args.dest, ignore_errors=True)
        print(f'[sync_sd_assets] removed {args.dest}')
        return

    rows = []
    with open(args.manifest, encoding='utf-8') as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            rows.append(line.rstrip('\n').split('\t'))
    todo = []
    for path, size, _sha, blob, _group, _text in rows:
        dest = os.path.join(args.dest, path)
        if os.path.exists(dest) and os.path.getsize(dest) == int(size):
            continue
        todo.append((dest, blob))

    proc = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=os.path.join(ROOT, 'assets'), stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    written = 0
    for dest, blob in todo:
        proc.stdin.write((blob + '\n').encode())
        proc.stdin.flush()
        size = int(proc.stdout.readline().split()[2])
        data = proc.stdout.read(size)
        proc.stdout.read(1)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'wb') as out:
            out.write(data)
        written += size
    proc.stdin.close()
    proc.wait()
    print(f'[sync_sd_assets] {len(todo)} of {len(rows)} files written ({written / 1e6:.1f} MB) to {args.dest}')


if __name__ == '__main__':
    main()
