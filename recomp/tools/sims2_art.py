#!/usr/bin/env python3
"""sims2_art.py <art folder> [<game folder>]

The launch window's art (install.sh), written to the data folder's art/ and a copy in the app (never to this project),
from Steam's store page for The Sims 2 Legacy Collection (app 3314070):
  logo.png      the game's logo, with transparency
  backdrop.jpg  the store page's background (a dim blue scene): the window's background
  shot.jpg      the library banner (a crowd of Sims against the sky): the right of the window's banner
  portrait.jpg  the library capsule (600x900): the framed portrait
  slide-<n>.jpg the store page's screenshots: the backdrop's slides
With the game folder, from the player's own copy: intro-<n>.jpg, frames of the game's intro movie
(Base/TSData/Res/Movies/intro_eng_audio.movie, EA's MAD video, decoded with ffmpeg when it is installed): slides too.
Each one that can't be made is left out; without the logo the window writes the title. Standard library only.
"""
import json, os, shutil, subprocess, sys, urllib.request

FRAMES = (330, 560, 760, 940, 1130, 1330)   # the intro's frames (15 a second): the street, the helicopter, a home, the park, ...

CDN = 'https://cdn.cloudflare.steamstatic.com/steam/apps/3314070/'
ART = (('logo.png', 'logo.png', b'\x89PNG'), ('backdrop.jpg', 'page_bg_generated_v6b.jpg', b'\xff\xd8\xff'),
       ('shot.jpg', 'library_hero.jpg', b'\xff\xd8\xff'))

def download(url, path, magic, least=8000):
    try:
        with urllib.request.urlopen(url, timeout=20) as r: data = r.read()
    except Exception:
        return False
    if not data.startswith(magic) or len(data) < least: return False
    with open(path + '.part', 'wb') as f: f.write(data)
    os.replace(path + '.part', path); return True

def main():
    out = sys.argv[1]; os.makedirs(out, exist_ok=True); got = []
    for name, remote, magic in ART:
        if download(CDN + remote, os.path.join(out, name), magic): got.append(name)
    if download('https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/3314070/library_600x900_2x.jpg', os.path.join(out, 'portrait.jpg'), b'\xff\xd8\xff'):
        got.append('portrait.jpg')
    try:
        with urllib.request.urlopen('https://store.steampowered.com/api/appdetails?appids=3314070&filters=screenshots', timeout=20) as r:
            shots = [x['path_full'].split('?')[0] for x in json.load(r)['3314070']['data']['screenshots']]
    except Exception:
        shots = []
    for k, u in enumerate(shots[:6]):
        if download(u, os.path.join(out, 'slide-%d.jpg' % (k + 1)), b'\xff\xd8\xff'): got.append('slide-%d.jpg' % (k + 1))
    movie = os.path.join(sys.argv[2], 'Base', 'TSData', 'Res', 'Movies', 'intro_eng_audio.movie') if len(sys.argv) > 2 else ''
    ffmpeg = shutil.which('ffmpeg') or next((p for p in ('/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg') if os.path.exists(p)), None)
    if movie and os.path.exists(movie) and ffmpeg:
        sel = '+'.join('eq(n\\,%d)' % n for n in FRAMES)
        tmp = os.path.join(out, 'intro-part-%d.jpg')
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', movie, '-an', '-vf', "select='%s',scale=1280:-2:flags=lanczos,unsharp=5:5:0.6" % sel,
                        '-fps_mode', 'vfr', '-q:v', '2', tmp], capture_output=True)
        for k in range(1, len(FRAMES) + 1):
            part = tmp % k
            if os.path.exists(part) and os.path.getsize(part) > 30000: os.replace(part, os.path.join(out, 'intro-%d.jpg' % k)); got.append('intro-%d.jpg' % k)
            elif os.path.exists(part): os.remove(part)
    print('art: %s' % (', '.join(got) if got else 'none (no connection?): the launch window writes the title'))

if __name__ == '__main__':
    main()
