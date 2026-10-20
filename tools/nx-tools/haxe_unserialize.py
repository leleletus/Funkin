"""
Minimal reader for the Haxe serialization format used by lime asset manifests (the "assets" field).

Supports what the manifests contain: arrays, anonymous objects, strings (with the string cache), integers,
floats, booleans and null.
"""
import urllib.parse


def unserialize(text):
    return _Reader(text).read()


class _Reader:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.strings = []

    def _int(self):
        start = self.i
        if self.s[self.i] == '-':
            self.i += 1
        while self.i < len(self.s) and self.s[self.i].isdigit():
            self.i += 1
        return int(self.s[start:self.i])

    def _string(self):
        length = self._int()
        assert self.s[self.i] == ':'
        self.i += 1
        raw = self.s[self.i:self.i + length]
        self.i += length
        value = urllib.parse.unquote(raw)
        self.strings.append(value)
        return value

    def read(self):
        c = self.s[self.i]
        self.i += 1
        if c == 'n':
            return None
        if c == 't':
            return True
        if c == 'f':
            return False
        if c == 'z':
            return 0
        if c == 'i':
            return self._int()
        if c == 'd':
            start = self.i
            while self.i < len(self.s) and self.s[self.i] in '0123456789.-+eE':
                self.i += 1
            return float(self.s[start:self.i])
        if c == 'y':
            return self._string()
        if c == 'R':
            return self.strings[self._int()]
        if c == 'a':
            out = []
            while self.s[self.i] != 'h':
                if self.s[self.i] == 'u':
                    self.i += 1
                    out.extend([None] * self._int())
                else:
                    out.append(self.read())
            self.i += 1
            return out
        if c == 'o':
            out = {}
            while self.s[self.i] != 'g':
                key = self.read()
                out[key] = self.read()
            self.i += 1
            return out
        raise ValueError(f'unsupported Haxe serialization tag {c!r} at {self.i - 1}')
