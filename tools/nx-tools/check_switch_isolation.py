#!/usr/bin/env python3
"""
Checks that the Switch port leaves the official game untouched on every other platform.

For each Haxe file the port changed under source/ and templates/ (outside source/nx/), the script resolves the
conditional compilation the way a non-Switch build sees it: `switch` and every define starting with `NX_`/`nx_`
are false, everything else is unknown and left as it is. The result must be identical to the official file at
the given tag. Any remaining difference is code that also changes PC, mobile or web.

Files outside source/ and templates/ (project.hxp, hmm.json, .gitignore...) are listed for manual review, since
project.hxp decides Switch behaviour at build time with isSwitch() instead of #if.

  python3 tools/nx-tools/check_switch_isolation.py               # against v0.8.7, summary + diffs
  python3 tools/nx-tools/check_switch_isolation.py --base v0.8.6
  python3 tools/nx-tools/check_switch_isolation.py --summary     # only the file list

Exit code 1 if any Haxe file differs on non-Switch platforms.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))

SWITCH_SYMBOL = re.compile(r'^(switch|NX_\w*|nx_\w*)$')

# Value given to `switch` while resolving conditions: False for the non-Switch view, True for the Switch view
# (NX_/nx_ defines stay unknown in the Switch view, since builds differ on them).
SWITCH_VALUE = False


def git(*args):
    return subprocess.run(['git', '-C', ROOT] + list(args), check=True, capture_output=True, text=True).stdout


# ------------------------------------------------------------------ condition simplification
# A condition becomes True, False, or a canonical string when it still depends on other defines.

def tokenize_condition(text):
    return re.findall(r'\(|\)|&&|\|\||[<>=!]=|[<>]|!|[A-Za-z_][\w.]*|[\d.]+|"[^"]*"|\'[^\']*\'', text)


class CondParser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def parse_or(self):
        left = self.parse_and()
        while self.peek() == '||':
            self.take()
            right = self.parse_and()
            if left is True or right is True:
                left = True
            elif left is False:
                left = right
            elif right is not False:
                left = f'({left} || {right})'
        return left

    def parse_and(self):
        left = self.parse_cmp()
        while self.peek() == '&&':
            self.take()
            right = self.parse_cmp()
            if left is False or right is False:
                left = False
            elif left is True:
                left = right
            elif right is not True:
                left = f'({left} && {right})'
        return left

    def parse_cmp(self):
        left = self.parse_unary()
        if self.peek() in ('<', '>', '<=', '>=', '==', '!='):
            op = self.take()
            right = self.parse_unary()
            return f'({left} {op} {right})'
        return left

    def parse_unary(self):
        tok = self.take()
        if tok == '!':
            v = self.parse_unary()
            return (not v) if isinstance(v, bool) else f'!{v}'
        if tok == '(':
            v = self.parse_or()
            if self.peek() == ')':
                self.take()
            return v
        if tok is None:
            return ''
        if tok == 'switch':
            return SWITCH_VALUE
        if SWITCH_SYMBOL.match(tok) and not SWITCH_VALUE:
            return False
        return tok


def simplify_condition(text):
    """True/False when a non-Switch build can decide it, otherwise a canonical string without outer parentheses."""
    v = CondParser(tokenize_condition(text)).parse_or()
    if isinstance(v, str) and v.startswith('(') and v.endswith(')'):
        depth = 0
        for k, ch in enumerate(v):
            depth += ch == '('
            depth -= ch == ')'
            if depth == 0 and k < len(v) - 1:
                return v
        v = v[1:-1]
    return v


# ------------------------------------------------------------------ preprocessor parsing

DIRECTIVE = re.compile(r'#(if|elseif|else|end)\b')


def read_condition(src, pos):
    """Reads the condition after #if/#elseif starting at pos; returns (text, end)."""
    n = len(src)
    while pos < n and src[pos] in ' \t':
        pos += 1
    start = pos
    if pos < n and src[pos] == '!':
        pos += 1
        while pos < n and src[pos] in ' \t':
            pos += 1
    if pos < n and src[pos] == '(':
        depth = 0
        while pos < n:
            if src[pos] == '(':
                depth += 1
            elif src[pos] == ')':
                depth -= 1
                if depth == 0:
                    pos += 1
                    break
            pos += 1
    else:
        m = re.match(r'[A-Za-z_][\w.]*', src[pos:])
        if m:
            pos += m.end()
    return src[start:pos], pos


def tokens(src):
    """Splits the source into text chunks and directives, skipping strings and comments."""
    out = []
    i = 0
    last = 0
    n = len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i) or src.startswith('/*', i):
            out.append(('text', src[last:i]))
            if src[i + 1] == '/':
                j = src.find('\n', i)
                i = n if j < 0 else j
            else:
                j = src.find('*/', i + 2)
                i = n if j < 0 else j + 2
            last = i
            continue
        if src.startswith('~/', i):
            j = i + 2
            while j < n and src[j] not in '/\n':
                j += 2 if src[j] == '\\' else 1
            i = j + 1
            continue
        if c in ('"', "'"):
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            i = j + 1
            continue
        if c == '#':
            m = DIRECTIVE.match(src, i)
            if m:
                out.append(('text', src[last:i]))
                kind = m.group(1)
                end = m.end()
                cond = None
                if kind in ('if', 'elseif'):
                    cond, end = read_condition(src, end)
                out.append((kind, cond, src[i:end]))
                i = last = end
                continue
        i += 1
    out.append(('text', src[last:]))
    return out


def build_tree(toks):
    """Nested list: str for text, ('chain', [(kind, cond, raw, children)...], end_raw) for #if chains."""
    root = []
    stack = [root]
    chains = []
    for tok in toks:
        if tok[0] == 'text':
            stack[-1].append(tok[1])
        elif tok[0] == 'if':
            branch = ['if', tok[1], tok[2], []]
            chain = ['chain', [branch], '#end']
            stack[-1].append(chain)
            chains.append(chain)
            stack.append(branch[3])
        elif tok[0] in ('elseif', 'else'):
            if not chains:
                stack[-1].append(tok[2])
                continue
            stack.pop()
            branch = [tok[0], tok[1], tok[2], []]
            chains[-1][1].append(branch)
            stack.append(branch[3])
        else:  # end
            if not chains:
                stack[-1].append(tok[2])
                continue
            chains[-1][2] = tok[2]
            chains.pop()
            stack.pop()
    return root


def render(nodes):
    out = []
    for node in nodes:
        if isinstance(node, str):
            out.append(node)
            continue
        _, branches, end_raw = node
        kept = []
        resolved = None
        for kind, cond, raw, children in branches:
            value = True if kind == 'else' else simplify_condition(cond)
            if value is False:
                continue
            if value is True and not kept:
                resolved = children
                break
            if value is True:
                kept.append(('else', None, raw, children))  # always taken after the undecided branches
                break
            kept.append((kind, value, raw, children))
        if resolved is not None:
            out.append(render(resolved))
            continue
        if not kept:
            continue
        for idx, (kind, cond, raw, children) in enumerate(kept):
            if kind == 'else':
                raw = '#else'
            else:
                raw = ('#if ' if idx == 0 else '#elseif ') + cond
            out.append('\n' + raw + '\n')
            out.append(render(children))
        out.append('\n#end\n')
    return ''.join(out)


def non_switch_view(src):
    """Non-empty, stripped lines of the source as a non-Switch build compiles it (formatting is ignored)."""
    lines = []
    for line in render(build_tree(tokens(src))).split('\n'):
        line = re.sub(r'\s+', ' ', line).strip()
        line = re.sub(r'\s*([^\w\s])\s*', r'\1', line)
        if line:
            lines.append(line)
    return lines


# ------------------------------------------------------------------ guard mode

def balanced(lines):
    """True when the lines open and close their own #if blocks (no stray #else/#elseif/#end)."""
    depth = 0
    for tok in tokens('\n'.join(lines)):
        kind = tok[0]
        if kind == 'if':
            depth += 1
        elif kind in ('else', 'elseif'):
            if depth == 0:
                return False
        elif kind == 'end':
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def comment_at_line_start(lines):
    """For each line index, whether that line starts inside a /* */ comment (strings are skipped)."""
    flags = []
    in_comment = False
    for line in lines:
        flags.append(in_comment)
        i = 0
        n = len(line)
        while i < n:
            if in_comment:
                j = line.find('*/', i)
                if j < 0:
                    break
                in_comment = False
                i = j + 2
                continue
            if line.startswith('//', i):
                break
            if line.startswith('/*', i):
                in_comment = True
                i += 2
                continue
            if line[i] in ('"', "'"):
                q = line[i]
                i += 1
                while i < n and line[i] != q:
                    i += 2 if line[i] == '\\' else 1
            i += 1
    flags.append(in_comment)
    return flags


def guard_file(path, base_text):
    """
    Wraps every changed region of the file that also changes non-Switch builds in
    #if switch <port code> #else <official code> #end. Regions that only change Switch, or only comments and
    formatting, are left alone. Returns the list of regions that could not be wrapped automatically.
    """
    with open(path, encoding='utf-8') as f:
        head_text = f.read()
    base = base_text.split('\n')
    head = head_text.split('\n')
    view = non_switch_view(head_text)
    base_view = non_switch_view(base_text)
    matcher = difflib.SequenceMatcher(None, base, head, autojunk=False)
    in_comment = comment_at_line_start(head)
    out = []
    manual = []
    last = 0
    prev_end = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == 'equal':
            continue
        # Directives must not land inside a /* */ comment: grow the region over the unchanged comment lines.
        while j1 > prev_end and in_comment[j1]:
            j1 -= 1
            i1 -= 1
        while j2 < len(head) and in_comment[j2] and i2 < len(base) and base[i2] == head[j2]:
            j2 += 1
            i2 += 1
        if in_comment[j1] or in_comment[j2]:
            manual.append(f'{path}:{j1 + 1}-{j2} (inside a comment)')
            prev_end = j2
            continue
        prev_end = j2
        reverted = head[:j1] + base[i1:i2] + head[j2:]
        if non_switch_view('\n'.join(reverted)) == view:
            continue  # the region only changes Switch (or comments)
        head_part, base_part = head[j1:j2], base[i1:i2]
        if not (balanced(head_part) and balanced(base_part)):
            manual.append(f'{path}:{j1 + 1}-{j2}')
            continue
        sample = next((l for l in head_part + base_part if l.strip()), '')
        indent = sample[:len(sample) - len(sample.lstrip())]
        out.append((j1, j2, head_part, base_part, indent))
    if not out:
        return manual
    result = []
    for j1, j2, head_part, base_part, indent in out:
        result.extend(head[last:j1])
        if head_part and base_part:
            result += [indent + '#if switch'] + head_part + [indent + '#else'] + base_part + [indent + '#end']
        elif head_part:
            result += [indent + '#if switch'] + head_part + [indent + '#end']
        else:
            result += [indent + '#if !switch'] + base_part + [indent + '#end']
        last = j2
    result.extend(head[last:])
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(result))
    if non_switch_view('\n'.join(result)) != base_view:
        manual.append(f'{path}: still differs after wrapping (check the remaining regions by hand)')
    return manual


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='v0.8.7')
    ap.add_argument('--summary', action='store_true')
    ap.add_argument('--switch-against', metavar='REV',
                    help='instead, compare the Switch view of every changed Haxe file with the same file at REV')
    ap.add_argument('--guard', nargs='+', metavar='FILE',
                    help='wrap the regions of these files that change other platforms in #if switch ... #else ... #end')
    args = ap.parse_args()

    if args.switch_against:
        global SWITCH_VALUE
        SWITCH_VALUE = True
        rows = git('diff', '--name-status', args.switch_against).splitlines()
        rows += [f'A\t{p}' for p in git('ls-files', '--others', '--exclude-standard').splitlines()]
        differs = 0
        for row in rows:
            status, path = row.split('\t')[0], row.split('\t')[-1]
            if not (path.startswith(('source/', 'templates/')) and path.endswith('.hx')):
                continue
            now = ''
            if status != 'D':
                with open(os.path.join(ROOT, path), encoding='utf-8') as f:
                    now = f.read()
            before = git('show', f'{args.switch_against}:{path}') if status != 'A' else ''
            a, b = non_switch_view(before), non_switch_view(now)
            if a != b:
                differs += 1
                print('\n'.join(difflib.unified_diff(a, b, f'{args.switch_against}:{path}', path, lineterm='', n=1)))
        print(f'[isolation] Switch view against {args.switch_against}: {differs} files differ')
        return 1 if differs else 0

    if args.guard:
        manual = []
        for path in args.guard:
            rel = os.path.relpath(os.path.abspath(path), ROOT)
            manual += guard_file(os.path.join(ROOT, rel), git('show', f'{args.base}:{rel}'))
        for m in manual:
            print(f'[isolation] wrap by hand: {m}')
        return 1 if manual else 0

    # Working tree against the official tag (committed or not).
    changed = git('diff', '--name-status', args.base).splitlines()
    changed += [f'A\t{p}' for p in git('ls-files', '--others', '--exclude-standard').splitlines()]
    haxe_bad = []
    manual = []
    clean = 0
    for row in changed:
        parts = row.split('\t')
        status, path = parts[0], parts[-1]
        if path.startswith(('source/nx/', 'tools/nx-tools/', 'docs/')):
            continue
        if not (path.startswith(('source/', 'templates/')) and path.endswith('.hx')):
            manual.append(f'{status}\t{path}')
            continue
        head = ''
        if status != 'D':
            with open(os.path.join(ROOT, path), encoding='utf-8') as f:
                head = f.read()
        base = git('show', f'{args.base}:{path}') if status != 'A' else ''
        head_view = non_switch_view(head)
        base_view = non_switch_view(base)
        if status == 'A' and all(l.startswith('package ') for l in head_view):
            head_view = []  # a new file that is empty outside Switch builds
        if head_view == base_view:
            clean += 1
            continue
        diff = list(difflib.unified_diff(base_view, head_view, f'{args.base}:{path}', path, lineterm='', n=1))
        haxe_bad.append((path, diff))

    print(f'[isolation] base {args.base}: {clean} Haxe files only change Switch, {len(haxe_bad)} also change other platforms')
    for path, diff in haxe_bad:
        changes = sum(1 for l in diff if l[:1] in '+-' and not l.startswith(('+++', '---')))
        print(f'  DIFFERS  {path}  ({changes} lines)')
    if manual:
        print('[isolation] review by hand (not Haxe source):')
        for m in manual:
            print(f'  {m}')
    if not args.summary:
        for path, diff in haxe_bad:
            print()
            print('\n'.join(diff))
    return 1 if haxe_bad else 0


if __name__ == '__main__':
    sys.exit(main())
