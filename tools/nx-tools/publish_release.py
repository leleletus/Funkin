#!/usr/bin/env python3
"""
Publishes a public release of the Switch port on GitHub, from the build to the uploaded .nro.

  python3 tools/nx-tools/publish_release.py v0.8.7-nx-release-2
  python3 tools/nx-tools/publish_release.py v0.8.7-nx-release-1 --replace-asset   # same release, new .nro

The notes are tools/nx-tools/store/release-notes/<tag>.md: a short "What's new" list written for players. The
Homebrew App Store bot copies the release text into the store's changelog, so it must stay short; install steps,
licences and credits live in the README.

Steps, each one stops the script if it fails:
  1. Checks: tag name, notes, nx-develop with no uncommitted changes, Citron closed, gh logged in.
  2. Public build without assets (-DNX_SD_ASSETS, no -DNX_DEV_TOOLS) and package_sd_build.py.
  3. No test code in the binary: "Toggled Botplay" and "[DEVTOOLS]" must not appear in Funkin.elf.
  4. PUBLIC_SMOKE in Citron with that .nro.
  5. tools/nx-tools/store/pkgbuild.json gets the new version, URL and changelog, and is committed.
  6. Push of nx-develop, annotated tag with the notes, GitHub release (marked latest) with Funkin.nro.
  7. The .nro is downloaded back from GitHub and its SHA-256 compared with the local one.
  8. With --sync-branches, the feature branches are fast-forwarded to nx-develop when possible.

After that the store bot notices the new tag and opens its own update pull request on fortheusers/switch-hbas-repo
(the description, icon, banner and screenshots only change with a manual pull request, see the tracker).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
BIN = os.path.join(ROOT, 'export', 'release', 'switch', 'bin')
STORE = os.path.join(HERE, 'store')
NOTES_DIR = os.path.join(STORE, 'release-notes')

REMOTE = 'personal'
REPO = 'leleletus/Funkin'
BRANCH = 'nx-develop'
FEATURE_BRANCHES = ['feature/switch-performance', 'feature/switch-lime83-sdl3']
TAG_RE = re.compile(r'^v(\d+\.\d+\.\d+)-nx-release-(\d+)$')
NOTES_LIMIT = 1500  # characters; longer notes make an unreadable store changelog
TEST_STRINGS = [b'Toggled Botplay', b'[DEVTOOLS]']


def step(msg):
    print(f'\n[publish] {msg}', flush=True)


def fail(msg):
    sys.exit(f'[publish] ERROR: {msg}')


def run(cmd, dry=False, capture=False, check=True, cwd=ROOT):
    print('  $ ' + ' '.join(cmd), flush=True)
    if dry:
        return ''
    res = subprocess.run(cmd, cwd=cwd, text=True, capture_output=capture)
    if check and res.returncode != 0:
        fail(f'command failed ({res.returncode}): {" ".join(cmd)}' + (f'\n{res.stderr}' if capture else ''))
    return res.stdout if capture else res.returncode


def git(*args, capture=True):
    return run(['git', *args], capture=capture).strip()


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def notes_changelog(notes):
    """The notes as the store shows them: plain lines, without Markdown headings, links or emphasis."""
    lines = []
    for line in notes.splitlines():
        if line.startswith('#'):
            continue
        line = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', line).replace('**', '').replace('`', '')
        lines.append(line.rstrip())
    return '\n'.join(lines).strip()


def checks(args, tag, notes_path):
    step('Checks')
    if not TAG_RE.match(tag):
        fail(f'tag "{tag}" is not vX.Y.Z-nx-release-N')
    if not os.path.isfile(notes_path):
        fail(f'missing notes: {os.path.relpath(notes_path, ROOT)} (a short "What\'s new" list in English)')
    notes = open(notes_path, encoding='utf-8').read()
    if len(notes) > NOTES_LIMIT:
        fail(f'notes are {len(notes)} characters; keep them under {NOTES_LIMIT}, the store shows them as the changelog')
    if git('rev-parse', '--abbrev-ref', 'HEAD') != BRANCH:
        fail(f'not on {BRANCH}')
    if git('status', '--porcelain', '--untracked-files=no'):
        fail('there are uncommitted changes; commit them first')
    if subprocess.run(['pgrep', '-x', 'citron'], capture_output=True).returncode == 0 or \
            subprocess.run(['pgrep', '-f', 'citron.*AppImage'], capture_output=True).returncode == 0:
        fail('Citron is running; close it first (the build must not change the .nro while it runs)')
    run(['gh', 'auth', 'status'], capture=True)
    tag_exists = subprocess.run(['git', 'rev-parse', '-q', '--verify', f'refs/tags/{tag}'], cwd=ROOT,
                                capture_output=True).returncode == 0
    if tag_exists and not args.replace_asset:
        fail(f'tag {tag} already exists; use --replace-asset to upload a new .nro to that release')
    if args.replace_asset and not tag_exists:
        fail(f'--replace-asset needs the existing tag {tag}')
    return notes, tag_exists


def build(args):
    if args.skip_build:
        step('Build skipped (--skip-build): using the .nro already in export/')
    else:
        step('Public build without assets')
        run(['haxelib', 'run', 'lime', 'build', 'switch', '-release', '-DHXCPP_COMPILE_THREADS=4', '-DNX_SD_ASSETS'],
            dry=args.dry_run)
        run([sys.executable, os.path.join(HERE, 'package_sd_build.py')], dry=args.dry_run)
    nro = os.path.join(BIN, 'Funkin-sd.nro')
    elf = os.path.join(BIN, 'Funkin.elf')
    if args.dry_run:
        return nro
    for path in (nro, elf):
        if not os.path.isfile(path):
            fail(f'missing {os.path.relpath(path, ROOT)}')
    step('No test code in the binary')
    data = open(elf, 'rb').read()
    for s in TEST_STRINGS:
        if s in data:
            fail(f'"{s.decode()}" is in Funkin.elf: this is a test build (-DNX_DEV_TOOLS); rebuild without it')
        print(f'  "{s.decode()}": 0')
    return nro


def smoke(args, nro):
    if args.skip_smoke:
        step('PUBLIC_SMOKE skipped (--skip-smoke)')
        return
    step('PUBLIC_SMOKE in Citron (about 90 s; do not close the Citron window)')
    if not args.dry_run:
        shutil.copy2(nro, os.path.join(BIN, 'Funkin.nro'))  # the runner launches export/release/switch/bin/Funkin.nro
    run([os.path.join(HERE, 'run_citron_autotest.sh'), 'PUBLIC_SMOKE', '90'], dry=args.dry_run)


def update_store_package(args, tag, version, notes):
    step('Store package (tools/nx-tools/store/pkgbuild.json)')
    path = os.path.join(STORE, 'pkgbuild.json')
    pkg = json.load(open(path, encoding='utf-8'))
    pkg['info']['version'] = version
    pkg['changelog'] = f'{version}\n{notes_changelog(notes)}'
    for asset in pkg['assets']:
        if asset.get('type') == 'update' and asset['url'].endswith('.nro'):
            asset['url'] = f'https://github.com/{REPO}/releases/download/{tag}/Funkin.nro'
    text = json.dumps(pkg, indent=4, ensure_ascii=False) + '\n'
    if text == open(path, encoding='utf-8').read():
        print('  already up to date')
        return
    if args.dry_run:
        print(f'  would set version {version} and commit')
        return
    open(path, 'w', encoding='utf-8').write(text)
    git('add', path)
    git('commit', '-m', f'docs(switch): store package for {tag}')


def publish(args, tag, version, notes_path, nro, tag_exists):
    step('GitHub')
    run(['git', 'push', REMOTE, BRANCH], dry=args.dry_run)
    if not tag_exists:
        run(['git', 'tag', '-a', tag, '-F', notes_path], dry=args.dry_run)
    run(['git', 'push', REMOTE, tag], dry=args.dry_run)

    # The release asset is always called Funkin.nro (the store package points at that name).
    stage = os.path.join(ROOT, 'export', 'release', 'switch', 'release', tag)
    asset = os.path.join(stage, 'Funkin.nro')
    if not args.dry_run:
        os.makedirs(stage, exist_ok=True)
        shutil.copy2(nro, asset)
        print(f'  Funkin.nro: {os.path.getsize(asset) / 1048576:.1f} MB, sha256 {sha256(asset)}')

    n = TAG_RE.match(tag).group(2)
    title = f"Friday Night Funkin' V-Slice {version.split('-')[0]} for Nintendo Switch — release {n}"
    exists = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO], cwd=ROOT,
                            capture_output=True).returncode == 0
    if exists:
        run(['gh', 'release', 'upload', tag, asset, '--repo', REPO, '--clobber'], dry=args.dry_run)
        run(['gh', 'release', 'edit', tag, '--repo', REPO, '--notes-file', notes_path], dry=args.dry_run)
    else:
        run(['gh', 'release', 'create', tag, asset, '--repo', REPO, '--title', title, '--notes-file', notes_path,
             '--latest'], dry=args.dry_run)
    return asset


def verify(args, tag, asset):
    if args.dry_run:
        return
    step('Downloading the .nro back from GitHub')
    with tempfile.TemporaryDirectory() as tmp:
        run(['gh', 'release', 'download', tag, '--repo', REPO, '-p', 'Funkin.nro', '-D', tmp])
        remote = sha256(os.path.join(tmp, 'Funkin.nro'))
    local = sha256(asset)
    if remote != local:
        fail(f'the uploaded .nro differs (GitHub {remote}, local {local})')
    print(f'  same SHA-256 on GitHub: {remote}')


def sync_branches(args):
    if not args.sync_branches:
        return
    step('Feature branches (fast-forward only)')
    for b in FEATURE_BRANCHES:
        code = run(['git', 'push', REMOTE, f'{BRANCH}:{b}'], dry=args.dry_run, check=False)
        if code:
            print(f'  {b} has its own commits; left as it is')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('tag', help='vX.Y.Z-nx-release-N')
    ap.add_argument('--notes', help='notes file (default: tools/nx-tools/store/release-notes/<tag>.md)')
    ap.add_argument('--replace-asset', action='store_true', help='upload a new .nro to an existing release')
    ap.add_argument('--skip-build', action='store_true', help='use the .nro already built')
    ap.add_argument('--skip-smoke', action='store_true', help='do not run PUBLIC_SMOKE in Citron')
    ap.add_argument('--sync-branches', action='store_true', help='fast-forward the feature branches')
    ap.add_argument('--dry-run', action='store_true', help='print the commands without running them')
    args = ap.parse_args()

    tag = args.tag
    notes_path = os.path.abspath(args.notes or os.path.join(NOTES_DIR, f'{tag}.md'))
    notes, tag_exists = checks(args, tag, notes_path)
    version = tag[1:]
    nro = build(args)
    smoke(args, nro)
    if not tag_exists:
        update_store_package(args, tag, version, notes)
    asset = publish(args, tag, version, notes_path, nro, tag_exists)
    verify(args, tag, asset)
    sync_branches(args)
    step(f'Done: https://github.com/{REPO}/releases/tag/{tag}')
    print('  The Homebrew App Store bot will open its update pull request on its next pass.')


if __name__ == '__main__':
    main()
