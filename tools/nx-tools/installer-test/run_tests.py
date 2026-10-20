#!/usr/bin/env python3
"""
PC tests for the installer core (source/nx/installer/nx_install_core.h).

Builds install_core_cli with gcc, writes the official files of a manifest into a temporary folder straight from the
git objects of the assets submodule, and checks each case: complete folder, missing file, changed byte, truncated
file, text file copied with Windows line endings (repaired), unknown extra files, and the state file.

  python3 tools/nx-tools/installer-test/run_tests.py <assets-manifest.tsv> [--files N] [--work DIR]

--files N uses N entries of the manifest (default 300, text files first); --files 0 uses all of them.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
ASSETS = os.path.join(ROOT, 'assets')


def build_cli(work):
    exe = os.path.join(work, 'install_core_cli')
    subprocess.run(['gcc', '-O2', '-Wall', '-Wextra', '-Wno-unused-function', '-o', exe, os.path.join(HERE, 'install_core_cli.c')],
                   check=True)
    return exe


def read_manifest(path):
    header, rows = [], []
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('#'):
                header.append(line)
            elif line:
                rows.append(line.split('\t'))
    return header, rows


def write_tree(rows, root):
    proc = subprocess.Popen(['git', 'cat-file', '--batch'], cwd=ASSETS, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    for row in rows:
        proc.stdin.write((row[3] + '\n').encode())
        proc.stdin.flush()
        size = int(proc.stdout.readline().split()[2])
        data = proc.stdout.read(size)
        proc.stdout.read(1)
        dest = os.path.join(root, row[0])
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, 'wb') as f:
            f.write(data)
    proc.stdin.close()
    proc.wait()


def run(exe, *args):
    out = subprocess.run([exe] + list(args), capture_output=True, text=True)
    lines = out.stdout.splitlines()
    tokens = lines[0].split() if lines else []
    summary = dict(kv.split('=', 1) for kv in tokens) if tokens and all('=' in kv for kv in tokens) else {}
    return out.returncode, summary, lines[1:], out.stdout + out.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('manifest')
    ap.add_argument('--files', type=int, default=300)
    ap.add_argument('--work')
    args = ap.parse_args()

    work = args.work or tempfile.mkdtemp(prefix='nx-install-test-')
    exe = build_cli(work)
    header, rows = read_manifest(args.manifest)
    if args.files:
        texts = [r for r in rows if r[5] == '1']
        binaries = [r for r in rows if r[5] != '1']
        rows = (texts[:args.files // 2] + binaries[:args.files - min(len(texts), args.files // 2)])[:args.files]
    manifest = os.path.join(work, 'manifest.tsv')
    with open(manifest, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(header) + '\n' + '\n'.join('\t'.join(r) for r in rows) + '\n')
    root = os.path.join(work, 'sd', 'assets')
    shutil.rmtree(root, ignore_errors=True)
    write_tree(rows, root)

    failures = []

    def expect(name, cond, detail):
        print(f'{"PASS" if cond else "FAIL"}  {name}')
        if not cond:
            failures.append(name)
            print(detail)

    rc, s, bad, raw = run(exe, 'quick', manifest, root)
    expect('quick check, complete folder', rc == 0 and s.get('ok') == str(len(rows)) and not bad, raw)
    rc, s, bad, raw = run(exe, 'verify', manifest, root)
    expect('full verify, complete folder', rc == 0 and s.get('ok') == str(len(rows)) and not bad, raw)

    text_row = next(r for r in rows if r[5] == '1' and int(r[1]) > 0)
    binary_rows = [r for r in rows if r[5] != '1' and int(r[1]) > 16]
    missing, flipped, truncated = binary_rows[0], binary_rows[1], binary_rows[2]

    os.remove(os.path.join(root, missing[0]))
    with open(os.path.join(root, flipped[0]), 'r+b') as f:
        f.seek(int(flipped[1]) // 2)
        b = f.read(1)
        f.seek(int(flipped[1]) // 2)
        f.write(bytes([b[0] ^ 0xFF]))
    with open(os.path.join(root, truncated[0]), 'r+b') as f:
        f.truncate(int(truncated[1]) - 7)
    text_path = os.path.join(root, text_row[0])
    with open(text_path, 'rb') as f:
        original_text = f.read()
    crlf = original_text.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    with open(text_path, 'wb') as f:
        f.write(crlf)
    with open(os.path.join(root, 'preload', 'unknown-mod-file.txt'), 'w') as f:
        f.write('not in the manifest')
    os.makedirs(os.path.join(root, '__MACOSX'), exist_ok=True)

    rc, s, bad, raw = run(exe, 'quick', manifest, root)
    expected_quick = {f'missing {missing[0]}', f'wrong-size {truncated[0]}'}
    if crlf != original_text:
        expected_quick.add(f'wrong-size {text_row[0]}')
    expect('quick check finds missing and truncated files (not the changed byte)', set(bad) == expected_quick, raw)

    rc, s, bad, raw = run(exe, 'verify', manifest, root)
    expected_full = {f'missing {missing[0]}', f'wrong-hash {flipped[0]}', f'wrong-size {truncated[0]}'}
    if crlf != original_text:
        expected_full.add(f'wrong-hash {text_row[0]}')
    expect('full verify finds the changed byte too, ignores unknown files', set(bad) == expected_full, raw)

    rc, s, bad, raw = run(exe, 'verify', manifest, root, 'repair')
    expected_repair = {f'missing {missing[0]}', f'wrong-hash {flipped[0]}', f'wrong-size {truncated[0]}'}
    if crlf != original_text:
        expected_repair.add(f'repaired {text_row[0]}')
    expect('verify with repair rewrites the CRLF text file', set(bad) == expected_repair, raw)
    with open(text_path, 'rb') as f:
        expect('repaired file has the official bytes', f.read() == original_text, '')

    needed = int(missing[1]) + int(flipped[1]) + int(truncated[1])
    expect('bytes still needed are the three broken files', s.get('needed') == str(needed), raw)

    rc, s, bad, raw = run(exe, 'state', manifest, root)
    expect('state file written, read back and matching the manifest', rc == 0 and 'matches=1' in raw, raw)

    with open(manifest + '.bad', 'w') as f:
        f.write('#commit abc\n../escape\t1\t' + '0' * 64 + '\t' + '0' * 40 + '\tcore\t0\n')
    rc, s, bad, raw = run(exe, 'quick', manifest + '.bad', root)
    expect('manifest with an unsafe path is rejected', rc == 2, raw)

    print(f'\n{len(rows)} files, work folder {work}')
    if failures:
        print(f'{len(failures)} FAILED')
        return 1
    print('all passed')
    if not args.work:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
