#!/usr/bin/env python3
"""
Puts every git library of hmm.json at its exact pinned commit in the local .haxelib repository.

hmm 3.1.0 (and stock haxelib) check out the head of a git library's branch instead of its "ref", so after
"hmm install" libraries can sit on newer commits than hmm.json says. This script compares each git dependency
with a "ref" against .haxelib/<name>/git, points "origin" at the hmm.json URL if it differs, fetches the commit
when it is missing and checks it out (detached). Run it after switching between branches whose hmm.json differs.

  python3 tools/nx-tools/sync_haxelibs.py          # fix mismatches
  python3 tools/nx-tools/sync_haxelibs.py --check  # only report (exit code 1 if anything differs)
"""
import json
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))


def git(path, *args, check=True):
    return subprocess.run(['git', '-C', path] + list(args), check=check, capture_output=True, text=True)


def main():
    check_only = '--check' in sys.argv
    with open(os.path.join(ROOT, 'hmm.json')) as f:
        deps = json.load(f)['dependencies']
    mismatches = 0
    for dep in deps:
        if dep.get('type') != 'git' or not dep.get('ref'):
            continue
        name, url, ref = dep['name'], dep['url'], dep['ref']
        path = os.path.join(ROOT, '.haxelib', name.replace('.', ','), 'git')
        if not os.path.isdir(path):
            print(f'MISSING  {name}: {path} (run hmm install first)')
            mismatches += 1
            continue
        head = git(path, 'rev-parse', 'HEAD').stdout.strip()
        origin = git(path, 'remote', 'get-url', 'origin', check=False).stdout.strip()
        same_url = origin.rstrip('/').removesuffix('.git') == url.rstrip('/').removesuffix('.git')
        if head == ref and same_url:
            print(f'ok       {name} {ref[:9]}')
            continue
        mismatches += 1
        print(f'DIFFERS  {name}: {head[:9]} from {origin or "?"} -> {ref[:9]} from {url}')
        if check_only:
            continue
        if not same_url:
            git(path, 'remote', 'set-url', 'origin', url)
        if git(path, 'cat-file', '-e', ref + '^{commit}', check=False).returncode != 0:
            fetched = git(path, 'fetch', '--quiet', 'origin', ref, check=False)
            if fetched.returncode != 0:
                git(path, 'fetch', '--quiet', 'origin', check=False)
        result = git(path, 'checkout', '--quiet', '--detach', ref, check=False)
        if result.returncode != 0:
            print(f'FAILED   {name}: {result.stderr.strip()}')
            continue
        if os.path.exists(os.path.join(path, '.gitmodules')):
            git(path, 'submodule', 'update', '--init', '--recursive', '--quiet', check=False)
        print(f'fixed    {name} {git(path, "rev-parse", "HEAD").stdout.strip()[:9]}')
    if check_only and mismatches:
        sys.exit(1)


if __name__ == '__main__':
    main()
