#!/usr/bin/env python3
"""
PC test of the installer downloader against the real GitHub: takes a small part of a manifest (text files, a
path with spaces and a few larger files), downloads it into an empty folder with install_download_cli, then checks
every file with the full verification of install_core_cli. Needs libcurl and internet.

  python3 tools/nx-tools/installer-test/run_download_test.py <assets-manifest.tsv> [--files N]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manifest')
    ap.add_argument('--files', type=int, default=40)
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix='nx-download-test-')
    flags = ['-O2', '-Wall', '-Wno-unused-function']
    subprocess.run(['gcc'] + flags + ['-o', f'{work}/download', f'{HERE}/install_download_cli.c', '-lcurl'], check=True)
    subprocess.run(['gcc'] + flags + ['-o', f'{work}/core', f'{HERE}/install_core_cli.c'], check=True)

    header, rows = [], []
    with open(args.manifest, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            (header if line.startswith('#') else rows).append(line)
    rows = [r for r in rows if r]
    spaced = [r for r in rows if ' ' in r.split('\t')[0]][:2]
    big = sorted(rows, key=lambda r: -int(r.split('\t')[1]))[:2]
    small = [r for r in rows if r not in spaced and r not in big][:max(0, args.files - len(spaced) - len(big))]
    subset = spaced + big + small
    manifest = f'{work}/manifest.tsv'
    with open(manifest, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(header + subset) + '\n')
    root = f'{work}/sd/assets'
    os.makedirs(root)

    print(f'downloading {len(subset)} files (spaces: {len(spaced)}, largest: {[r.split(chr(9))[0] for r in big]})')
    out = subprocess.run([f'{work}/download', manifest, root], capture_output=True, text=True)
    print(out.stdout.strip() or out.stderr.strip())
    verify = subprocess.run([f'{work}/core', 'verify', manifest, root], capture_output=True, text=True)
    first = verify.stdout.splitlines()[0] if verify.stdout else verify.stderr
    print(first)
    ok = out.returncode == 0 and f'ok={len(subset)} ' in first
    parts = [p for d, _, fs in os.walk(root) for p in fs if p.endswith('.part')]
    print(f'.part files left: {len(parts)}')
    print('PASS' if ok and not parts else 'FAIL')
    shutil.rmtree(work, ignore_errors=True)
    return 0 if ok and not parts else 1


if __name__ == '__main__':
    sys.exit(main())
