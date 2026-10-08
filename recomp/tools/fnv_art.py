#!/usr/bin/env python3
"""fnv_art.py <game folder> <out folder>: the launch window's art from the player's own Fallout: New Vegas archives (the
main menu's title and the loading screen's desk), decoded from DDS (DXT1/3/5 or 32-bit) to title.png and backdrop.png.
Nothing from the game is stored in the project; install.sh runs this into the data folder. No Pillow needed."""
import os, struct, sys, zlib

TITLE = 'textures\\interface\\main\\main_title.dds'
DESK = 'textures\\interface\\loading\\loading_desktop01.dds'


def read_bsa_files(path, wanted):
    """{name: bytes} for the files (lower-case archive paths) in a Fallout NV (version 104) BSA"""
    out = {}
    with open(path, 'rb') as f:
        magic, ver, off, aflags, nfold, nfile, foldlen, filelen, fflags = struct.unpack('<4sIIIIIIII', f.read(36))
        if magic != b'BSA\0' or ver != 104:
            return out
        f.seek(off)
        folders = [struct.unpack('<QII', f.read(16)) for _ in range(nfold)]
        entries = []
        for _, count, _ in folders:
            n = f.read(1)[0]
            folder = f.read(n).rstrip(b'\0').decode('latin1')
            for _ in range(count):
                _, size, o = struct.unpack('<QII', f.read(16))
                entries.append((folder, size, o))
        names = f.read(filelen).split(b'\0')
        for (folder, size, o), name in zip(entries, names):
            full = (folder + '\\' + name.decode('latin1')).lower()
            if full not in wanted:
                continue
            comp = bool(aflags & 4) != bool(size & 0x40000000)
            size &= 0x3fffffff
            f.seek(o)
            b = f.read(size)
            if aflags & 0x100:
                b = b[1 + b[0]:]
            out[full] = zlib.decompress(b[4:]) if comp else b
    return out


def rgb565(c):
    return (((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31)


def color_block(b):
    c0, c1, bits = struct.unpack_from('<HHI', b)
    p0, p1 = rgb565(c0), rgb565(c1)
    if c0 > c1:
        pal = [p0 + (255,), p1 + (255,), tuple((2 * a + c) // 3 for a, c in zip(p0, p1)) + (255,), tuple((a + 2 * c) // 3 for a, c in zip(p0, p1)) + (255,)]
    else:
        pal = [p0 + (255,), p1 + (255,), tuple((a + c) // 2 for a, c in zip(p0, p1)) + (255,), (0, 0, 0, 0)]
    return [pal[(bits >> (2 * k)) & 3] for k in range(16)]


def alpha5(b):
    a0, a1 = b[0], b[1]
    bits = int.from_bytes(b[2:8], 'little')
    pal = [a0, a1] + ([((6 - k) * a0 + (k + 1) * a1) // 7 for k in range(6)] if a0 > a1 else [((4 - k) * a0 + (k + 1) * a1) // 5 for k in range(4)] + [0, 255])
    return [pal[(bits >> (3 * k)) & 7] for k in range(16)]


def decode_dds(d):
    """(width, height, rows of RGBA tuples) for a DDS's top level"""
    h, w = struct.unpack_from('<II', d, 12)
    fourcc = d[84:88]
    data = d[128:]
    px = [[(0, 0, 0, 255)] * w for _ in range(h)]
    if fourcc in (b'DXT1', b'DXT3', b'DXT5'):
        bs = 8 if fourcc == b'DXT1' else 16
        o = 0
        for by in range(0, h, 4):
            for bx in range(0, w, 4):
                blk = data[o:o + bs]
                o += bs
                if fourcc == b'DXT1':
                    cols = color_block(blk)
                else:
                    cols = color_block(blk[8:])
                    if fourcc == b'DXT3':
                        al = [((int.from_bytes(blk[:8], 'little') >> (4 * k)) & 15) * 17 for k in range(16)]
                    else:
                        al = alpha5(blk[:8])
                    cols = [c[:3] + (a,) for c, a in zip(cols, al)]
                for k in range(16):
                    y, x = by + k // 4, bx + k % 4
                    if y < h and x < w:
                        px[y][x] = cols[k]
    else:                                                  # uncompressed 32-bit BGRA
        for y in range(h):
            for x in range(w):
                b, g, r, a = data[4 * (y * w + x):4 * (y * w + x) + 4]
                px[y][x] = (r, g, b, a)
    return w, h, px


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b''.join(b'\0' + bytes(v for p in r for v in p) for r in rows)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def main(game, out):
    found = {}
    data = os.path.join(game, 'Data')
    for bsa in sorted(os.listdir(data)):
        if bsa.lower().endswith('.bsa') and 'texture' in bsa.lower():
            found.update(read_bsa_files(os.path.join(data, bsa), {TITLE, DESK}))
    os.makedirs(out, exist_ok=True)
    for name, png in ((TITLE, 'title.png'), (DESK, 'backdrop.png')):
        if name not in found:
            print('fnv_art: %s not in the archives' % name)
            continue
        w, h, px = decode_dds(found[name])
        write_png(os.path.join(out, png), px)
        print('fnv_art: %s %dx%d' % (png, w, h))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
