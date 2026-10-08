"""steamstub.py <in.exe> <out.exe> : remove SteamStub variant 3.1 (x86) from the player's own Steam executable.

Steam's DRM wraps the game: the entry point moves into a `.bind` section, and the code section is AES-256-CBC
encrypted with its first 16 bytes stored in the stub's header. This decrypts the code section in place and puts the
original entry point back. Every section stays where it was (same RVAs and file offsets), so the result is the
executable as the developer linked it, plus an unused `.bind`. Layout from Steamless (atom0s,
Steamless.Unpacker.Variant31.x86). AES: the `cryptography` module if installed, else the system `openssl`."""
import os, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE

HDR = 0xF0                         # SteamStub32Var31Header
SIG = 0xC0DEC0DF
NO_ENCRYPTION = 0x04


def steam_xor(b, key=0):
    """The header's XOR chain: each dword is XORed with the previous encoded dword (the first one is the key)."""
    b = bytearray(b); o = 0
    if not key: key = struct.unpack_from('<I', b, 0)[0]; o = 4
    for i in range(o, len(b) & ~3, 4):
        v = struct.unpack_from('<I', b, i)[0]; struct.pack_into('<I', b, i, v ^ key); key = v
    return bytes(b)


def aes_decrypt(mode, key, iv, data):
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        d = Cipher(algorithms.AES(key), modes.ECB() if mode == 'ecb' else modes.CBC(iv)).decryptor()
        return d.update(data) + d.finalize()
    except ImportError:
        cmd = ['openssl', 'enc', '-d', '-aes-256-' + mode, '-nopad', '-K', key.hex()] + (['-iv', iv.hex()] if mode == 'cbc' else [])
        return subprocess.run(cmd, input=data, stdout=subprocess.PIPE, check=True).stdout


def header(pe):
    o = pe.off(pe.entry) - HDR
    h = steam_xor(pe.data[o:o + HDR])
    f = {}
    (f['xor'], f['sig'], f['image_base'], f['ep'], f['bind_off'], _, f['oep'], _, f['payload_size'], f['drmp_off'],
     f['drmp_size'], f['appid'], f['flags'], f['bind_vsize'], _, f['code_va'], f['code_size']) = \
        struct.unpack_from('<IIQQIIQIIIIIIIIQQ', h, 0)
    o = struct.calcsize('<IIQQIIQIIIIIIIIQQ')
    f['aes_key'], f['aes_iv'], f['stolen'] = h[o:o + 32], h[o + 32:o + 48], h[o + 48:o + 64]
    return f


def unpack(src, dst):
    pe = PE(src)
    if not any(s[0] == '.bind' for s in pe.sections): raise SystemExit('%s: no .bind section (not SteamStub)' % src)
    h = header(pe)
    if h['sig'] != SIG: raise SystemExit('%s: SteamStub header signature %#x, not variant 3.1 x86' % (src, h['sig']))
    d = bytearray(pe.data)
    if not h['flags'] & NO_ENCRYPTION:
        co = pe.off(pe.base + h['code_va']); n = h['code_size']
        iv = aes_decrypt('ecb', h['aes_key'], None, h['aes_iv'])
        plain = aes_decrypt('cbc', h['aes_key'], iv, h['stolen'] + bytes(d[co:co + n]))
        d[co:co + n] = plain[:n]
    po = struct.unpack_from('<I', d, 0x3c)[0] + 24
    struct.pack_into('<I', d, po + 16, h['oep'])                   # AddressOfEntryPoint
    struct.pack_into('<I', d, po + 64, 0)                          # CheckSum
    open(dst, 'wb').write(d)
    return h


if __name__ == '__main__':
    h = unpack(sys.argv[1], sys.argv[2])
    print('SteamStub 3.1: app %d, flags %#x, code %#x+%#x %s, entry point %#x -> %#x'
          % (h['appid'], h['flags'], h['code_va'], h['code_size'],
             'not encrypted' if h['flags'] & NO_ENCRYPTION else 'decrypted', h['ep'], h['oep']))
