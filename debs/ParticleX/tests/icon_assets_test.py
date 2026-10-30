"""Dependency-free PNG checks for PreferenceLoader rounded icon assets."""
from pathlib import Path
import struct, zlib

def rgba_png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    p = 8
    compressed = bytearray()
    while p < len(data):
        n = struct.unpack_from('>I', data, p)[0]
        kind = data[p+4:p+8]
        chunk = data[p+8:p+8+n]
        crc = struct.unpack_from('>I', data, p+8+n)[0]
        assert zlib.crc32(kind+chunk) & 0xffffffff == crc
        if kind == b'IHDR':
            w, h, bits, color, comp, filt, interlace = struct.unpack('>IIBBBBB', chunk)
            assert bits == 8 and color == 6 and comp == filt == interlace == 0
        if kind == b'IDAT': compressed.extend(chunk)
        p += n + 12
        if kind == b'IEND': break
    stride = w * 4
    raw = zlib.decompress(compressed)
    assert len(raw) == (stride + 1) * h
    rows = []
    previous = bytearray(stride)
    for y in range(h):
        offset = y * (stride + 1)
        method = raw[offset]
        row = bytearray(raw[offset+1:offset+1+stride])
        assert method in (0, 1, 2, 3, 4)
        for i in range(stride):
            left = row[i-4] if i >= 4 else 0
            above = previous[i]
            upper_left = previous[i-4] if i >= 4 else 0
            if method == 1: value = left
            elif method == 2: value = above
            elif method == 3: value = (left + above) // 2
            elif method == 4:
                q = left + above - upper_left
                distances = (abs(q-left), abs(q-above), abs(q-upper_left))
                value = (left, above, upper_left)[distances.index(min(distances))]
            else: value = 0
            row[i] = (row[i] + value) & 255
        rows.append(row)
        previous = row
    return w, h, rows

def check_icons(root):
    for size, suffix in ((29, ''), (58, '@2x'), (87, '@3x')):
        path = root / 'Prefs/Resources' / ('icon' + suffix + '.png')
        w, h, rows = rgba_png(path)
        assert (w, h) == (size, size), path
        alpha = lambda x,y: rows[y][x*4+3]
        assert all(alpha(x,y) == 0 for x,y in ((0,0),(w-1,0),(0,h-1),(w-1,h-1))), 'opaque corners'
        assert all(alpha(x,y) == 255 for x,y in ((w//2,0),(w//2,h-1),(0,h//2),(w-1,h//2),(w//2,h//2))), 'artwork/padding changed'
        assert any(0 < a < 255 for row in rows for a in row[3::4]), 'edges must be antialiased'
    return True

if __name__ == '__main__':
    check_icons(Path(__file__).resolve().parents[1])
    print('PASS icon PNGs: 29/58/87, RGBA, transparent corners, opaque centers, antialiased edges')
