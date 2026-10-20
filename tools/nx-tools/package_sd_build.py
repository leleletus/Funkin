#!/usr/bin/env python3
"""
Repacks a Switch build made with -DNX_SD_ASSETS into the asset-less .nro: its RomFS only keeps what is not
FunkinCrew content (lime's asset manifests, the installer manifest, the code licence and changelog), and the NACP
names the port, not The Funkin' Crew.

  haxelib run lime build switch -release -DNX_SD_ASSETS            # public build (add -DNX_DEV_TOOLS for tests)
  python3 tools/nx-tools/package_sd_build.py                        # -> export/release/switch/bin/Funkin-sd.nro

Steps: writes romfs/nx/assets-manifest.tsv with gen_asset_manifest.py (official files of this version, at the commit
of the official tag), copies the allowed files into a staging RomFS, creates the NACP with nacptool and runs elf2nro.
The build fails if anything outside the allow list would end up in the RomFS.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
BIN = os.path.join(ROOT, 'export', 'release', 'switch', 'bin')
DEVKITPRO = os.environ.get('DEVKITPRO', '/opt/devkitpro')

TITLE = "Friday Night Funkin' (unofficial port)"
AUTHOR = 'FunkinNX port'

# Everything the asset-less RomFS may contain (paths relative to the RomFS root).
ALLOWED = re.compile(r'^(manifest/[A-Za-z0-9_-]+\.json|nx/assets-manifest\.tsv|LICENSE\.md|CHANGELOG\.md)$')


def game_version():
    with open(os.path.join(ROOT, 'project.hxp'), encoding='utf-8') as f:
        return re.search(r'static final VERSION:String = "([^"]+)"', f.read()).group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=os.path.join(BIN, 'Funkin-sd.nro'))
    args = ap.parse_args()

    elf = os.path.join(BIN, 'Funkin.elf')
    built_romfs = os.path.join(BIN, 'SWITCH_ASSETS', 'romfs')
    if not os.path.exists(elf) or not os.path.isdir(os.path.join(built_romfs, 'manifest')):
        sys.exit('[package_sd_build] build for Switch with -DNX_SD_ASSETS first')

    staging = os.path.join(ROOT, 'export', 'release', 'switch', 'sd-romfs')
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(os.path.join(staging, 'manifest'))
    os.makedirs(os.path.join(staging, 'nx'))

    manifests = os.path.join(built_romfs, 'manifest')
    for name in sorted(os.listdir(manifests)):
        with open(os.path.join(manifests, name), encoding='utf-8') as f:
            text = f.read()
        if '"version":2' in text.replace(' ', '') and 'assets%2Fpreload%2F' not in text and name == 'default.json':
            sys.exit('[package_sd_build] the manifests use RomFS paths: this build was not made with -DNX_SD_ASSETS')
        shutil.copy2(os.path.join(manifests, name), os.path.join(staging, 'manifest', name))
    for name in ('LICENSE.md', 'CHANGELOG.md'):
        if os.path.exists(os.path.join(ROOT, name)):
            shutil.copy2(os.path.join(ROOT, name), os.path.join(staging, name))

    subprocess.run([sys.executable, os.path.join(HERE, 'gen_asset_manifest.py'), '--manifests', manifests, '--out',
                    os.path.join(staging, 'nx', 'assets-manifest.tsv')], check=True)

    for dirpath, _, files in os.walk(staging):
        for name in files:
            rel = os.path.relpath(os.path.join(dirpath, name), staging).replace(os.sep, '/')
            if not ALLOWED.match(rel):
                sys.exit(f'[package_sd_build] not allowed in the asset-less RomFS: {rel}')

    nacp = os.path.join(ROOT, 'export', 'release', 'switch', 'Funkin-sd.nacp')
    subprocess.run([os.path.join(DEVKITPRO, 'tools', 'bin', 'nacptool'), '--create', TITLE, AUTHOR, game_version(), nacp], check=True,
                   stdout=subprocess.DEVNULL)
    icon = os.path.join(HERE, 'branding', 'icon.jpg')
    subprocess.run([os.path.join(DEVKITPRO, 'tools', 'bin', 'elf2nro'), elf, args.out, f'--nacp={nacp}', f'--icon={icon}', f'--romfsdir={staging}'],
                   check=True, stdout=subprocess.DEVNULL)

    romfs_bytes = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(staging) for f in fs)
    print(f'[package_sd_build] {args.out}: {os.path.getsize(args.out) / 1e6:.1f} MB (RomFS {romfs_bytes / 1e3:.0f} KB, '
          f'{sum(len(fs) for _, _, fs in os.walk(staging))} files)')


if __name__ == '__main__':
    main()
