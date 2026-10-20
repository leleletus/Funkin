#!/usr/bin/env python3
"""
Writes the asset manifest the Switch installer uses: every file of the official FunkinCrew/funkin.assets
repository that this build needs, with its size and hashes, at the exact commit of the game version.

The file list comes from the lime manifests of the Switch build itself (what the game really references),
mapped back to paths inside the assets repository:
  - "assets/<x>" is "<x>" in the repository, or "preload/<x>" for the default library;
  - fonts and the embedded Spaghetti audio are listed by id instead of path;
  - "assets/videos/native/<name>" (the native video player) is the original "videos/videos/<name>";
  - converted cutscene sheets, flixel's own files and the "art" library are not FunkinCrew asset files.
credits.json (exclude/data/credits.json) is always added: the public build reads the credits from the SD card.

Hashes come from the git objects of the assets submodule at its commit, never from the working tree. The script
fails if the submodule has local changes or is not at the commit the official game tag points to.

  python3 tools/nx-tools/gen_asset_manifest.py                       # after a Switch build
  python3 tools/nx-tools/gen_asset_manifest.py --out path/to/assets-manifest.tsv

Output format (tab separated, one file per line after the header):
  #nx-assets 1
  #game_version 0.8.7
  #repo FunkinCrew/funkin.assets
  #commit <sha>
  <path in repo>  <size>  <sha256>  <git blob id>  <group: core|cutscene>  <text: 0|1>
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from haxe_unserialize import unserialize  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
ASSETS = os.path.join(ROOT, 'assets')
DEFAULT_MANIFESTS = os.path.join(ROOT, 'export', 'release', 'switch', 'bin', 'SWITCH_ASSETS', 'romfs', 'manifest')
DEFAULT_OUT = os.path.join(ROOT, 'export', 'release', 'switch', 'nx-assets-manifest.tsv')

REPO = 'FunkinCrew/funkin.assets'

# Commit of the assets submodule at each official game tag (git ls-tree <tag> assets).
OFFICIAL_ASSET_COMMITS = {
    '0.8.1': '39d4b3fc9506cbeb2a9eb04525d4117d527e4b81',
    '0.8.3': 'cd36d5bfcbd615796e7a8e4cac96713ba53b72eb',
    '0.8.7': '724eba9de9e76761d9cefd52169926bc51c760a5',
}

ALWAYS_INCLUDED = ['exclude/data/credits.json']

# Files lime/OpenFL add to the game's manifests that come from those libraries, not from the assets repository.
LIBRARY_ASSET_PREFIXES = ('flixel/', 'assets/videos/converted/', 'assets/fonts/Noto')

TEXT_EXTENSIONS = {'.json', '.xml', '.txt', '.hxc', '.hx', '.frag', '.vert', '.fnt', '.md', '.csv', '.srt', '.ass', '.tsv'}

# FS_MAX_PATH on Switch, minus "sdmc:/switch/Friday-Night-Funkin/assets/" and ".part".
MAX_REPO_PATH = 0x301 - len('sdmc:/switch/Friday-Night-Funkin/assets/') - len('.part') - 1


def run(*args, cwd=ROOT):
    return subprocess.run(list(args), cwd=cwd, check=True, capture_output=True, text=True).stdout


def game_version():
    with open(os.path.join(ROOT, 'project.hxp'), encoding='utf-8') as f:
        m = re.search(r'static final VERSION:String = "([^"]+)"', f.read())
    if not m:
        sys.exit('[gen_asset_manifest] VERSION not found in project.hxp')
    return m.group(1)


def check_submodule(version):
    if run('git', 'status', '--porcelain', cwd=ASSETS).strip():
        sys.exit('[gen_asset_manifest] the assets submodule has local changes; it must be an official commit')
    head = run('git', 'rev-parse', 'HEAD', cwd=ASSETS).strip()
    expected = OFFICIAL_ASSET_COMMITS.get(version)
    if expected is None:
        sys.exit(f'[gen_asset_manifest] no official assets commit known for {version}; add it to OFFICIAL_ASSET_COMMITS')
    if head != expected:
        sys.exit(f'[gen_asset_manifest] assets submodule is at {head}, the official v{version} commit is {expected}')
    return head


def repo_tree(commit):
    tree = {}
    for line in run('git', 'ls-tree', '-r', '-l', commit, cwd=ASSETS).splitlines():
        meta, path = line.split('\t', 1)
        _, kind, blob, size = meta.split()
        if kind == 'blob':
            tree[path] = (blob, int(size))
    return tree


def repo_path_for(asset_id, tree):
    """Maps a lime asset id or path to a repository path, or None when it is not a FunkinCrew asset file."""
    if not asset_id.startswith('assets/'):
        return None
    rel = asset_id[len('assets/'):]
    if rel.startswith('videos/converted/'):
        return None
    if rel.startswith('videos/native/'):
        rel = 'videos/videos/' + rel[len('videos/native/'):]
    for candidate in (rel, 'preload/' + rel):
        if candidate in tree:
            return candidate
    return None


def collect(manifest_dir, tree):
    needed = set(ALWAYS_INCLUDED)
    unresolved = []
    for path in sorted(glob.glob(os.path.join(manifest_dir, '*.json'))):
        library = os.path.basename(path)[:-len('.json')]
        if library == 'art':
            continue
        with open(path, encoding='utf-8') as f:
            entries = unserialize(json.load(f)['assets'])
        for entry in entries:
            asset = entry.get('path') or entry.get('id') or ''
            if asset.startswith(LIBRARY_ASSET_PREFIXES):
                continue
            repo_path = repo_path_for(asset, tree)
            if repo_path is None:
                unresolved.append(f'{library}: {asset}')
            else:
                needed.add(repo_path)
    return needed, unresolved


def blob_contents(blobs):
    """Yields (blob id, bytes) for every blob through one git cat-file process."""
    proc = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=ASSETS, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for blob in blobs:
            proc.stdin.write((blob + '\n').encode())
            proc.stdin.flush()
            header = proc.stdout.readline().decode().split()
            size = int(header[2])
            data = proc.stdout.read(size)
            proc.stdout.read(1)
            yield blob, data
    finally:
        proc.stdin.close()
        proc.wait()


def check_path(path):
    if path.startswith('/') or '\\' in path or '..' in path.split('/') or len(path) > MAX_REPO_PATH:
        sys.exit(f'[gen_asset_manifest] unsafe path in manifest: {path}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--manifests', default=DEFAULT_MANIFESTS)
    ap.add_argument('--out', default=DEFAULT_OUT)
    args = ap.parse_args()

    if not os.path.isdir(args.manifests):
        sys.exit(f'[gen_asset_manifest] no lime manifests at {args.manifests}; build for Switch first')
    version = game_version()
    commit = check_submodule(version)
    tree = repo_tree(commit)
    needed, unresolved = collect(args.manifests, tree)
    if unresolved:
        print('[gen_asset_manifest] not found in the assets repository:', file=sys.stderr)
        for u in unresolved:
            print(f'  {u}', file=sys.stderr)
        sys.exit(1)

    paths = sorted(needed)
    for p in paths:
        check_path(p)
    blob_to_paths = {}
    for p in paths:
        blob_to_paths.setdefault(tree[p][0], []).append(p)

    rows = {}
    totals = {}
    for blob, data in blob_contents(list(blob_to_paths)):
        digest = hashlib.sha256(data).hexdigest()
        for p in blob_to_paths[blob]:
            group = 'cutscene' if p.startswith('videos/videos/') else 'core'
            text = int(os.path.splitext(p)[1].lower() in TEXT_EXTENSIONS and b'\0' not in data)
            rows[p] = f'{p}\t{len(data)}\t{digest}\t{blob}\t{group}\t{text}'
            count, size = totals.get(group, (0, 0))
            totals[group] = (count + 1, size + len(data))

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(f'#nx-assets 1\n#game_version {version}\n#repo {REPO}\n#commit {commit}\n')
        for p in paths:
            f.write(rows[p] + '\n')

    files = sum(c for c, _ in totals.values())
    size = sum(s for _, s in totals.values())
    detail = ', '.join(f'{g} {c} ({s / 1e6:.1f} MB)' for g, (c, s) in sorted(totals.items()))
    print(f'[gen_asset_manifest] v{version} {commit[:9]}: {files} files, {size / 1e6:.1f} MB ({detail}) -> {args.out}')


if __name__ == '__main__':
    main()
