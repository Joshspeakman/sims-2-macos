#!/usr/bin/env python3
"""Identify an input executable before applying address-specific DS2 hooks."""
import argparse
import hashlib
from pathlib import Path

GOG_23 = 'c17e1cc9e01b5d2439a92e06b905040379ad4bb8618b822582c46f5fa29db4e2'
# Only verified layouts may use the GOG-address hooks and native hot loops.

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('exe', type=Path)
    args = parser.parse_args()
    try:
        with args.exe.open('rb') as f: digest = hashlib.file_digest(f, 'sha256').hexdigest()
    except OSError as error: parser.exit(1, f'{error}\n')
    if digest == GOG_23:
        print('GOG 2.3 (installer 37617): supported executable layout')
        return 0
    print(f'Unsupported executable layout: SHA-256 {digest}')
    print('This build currently requires the original GOG 2.3 executable (installer 37617).')
    print('Steam/Broken World executables need separate address profiles; changing the hash check is not sufficient.')
    print('Your original executable has not been modified.')
    return 1

if __name__ == '__main__': raise SystemExit(main())
