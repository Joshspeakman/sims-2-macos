#!/usr/bin/env python3
"""Build and install the experimental Linux port from the player's own GOG files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from check_edition import GOG_23
from steam_data_view import make_view
from prepare_linux_icon import prepare_icon

ROOT=Path(__file__).resolve().parents[2]

def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser(description=__doc__)
    source=p.add_mutually_exclusive_group(required=True)
    source.add_argument('--game-dir',type=Path)
    source.add_argument('--gog-installer',type=Path)
    p.add_argument('--steam-data',type=Path,help='optional Steam base-game assets; GOG executable remains required')
    p.add_argument('--use-build',type=Path,help='install an existing build instead of recompiling')
    p.add_argument('--data-dir',type=Path,default=Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))/'dungeon-siege-2-linux')
    args=p.parse_args()
    data=args.data_dir.expanduser().resolve()
    if args.gog_installer:
        tool=os.environ.get('INNOEXTRACT','innoextract')
        if not shutil.which(tool): p.error('Install innoextract, or set INNOEXTRACT to its executable path.')
        game=data/'gog-game'
        if game.exists(): p.error(f'{game} already exists; use --game-dir for the extracted copy.')
        game.mkdir(parents=True)
        subprocess.run([tool,'-s','-d',str(game),str(args.gog_installer.resolve())],check=True)
    else: game=args.game_dir.expanduser().resolve()
    exe=game/'DungeonSiege2.exe'
    if not exe.is_file() or digest(exe)!=GOG_23: p.error('The original GOG 2.3 executable (installer 37617) is required for this first build.')
    out=args.use_build.resolve() if args.use_build else ROOT/'recomp/work/full'
    if not args.use_build: subprocess.run([str(ROOT/'recomp/build.sh'),str(exe),str(out)],check=True)
    if not (out/'app/DungeonSiege2Linux').is_file() or digest(out/'DungeonSiege2.exe')!=GOG_23:
        p.error('The supplied build is missing or uses a different executable.')
    app=data/'app'; app.mkdir(parents=True,exist_ok=True)
    for src in (out/'app').iterdir():
        if src.is_file():
            temp=app/(src.name+'.tmp'); shutil.copy2(src,temp); temp.replace(app/src.name)
    shutil.copy2(out/'DungeonSiege2.exe',app/'DungeonSiege2.exe')
    icon=prepare_icon(app/'DungeonSiege2.exe',app)
    shutil.copytree(ROOT/'recomp/host/linux_launcher',app/'launcher',dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__'))
    profiles={'GOG':str(game)}
    if args.steam_data:
        # Versioned view avoids deleting or replacing any existing user data.
        import time
        view=data/f'steam-base-{time.time_ns()}'
        profiles['Steam base game']=str(make_view(args.steam_data,view))
    (app/'profiles.json').write_text(json.dumps(profiles,indent=2)+'\n')
    config=dict(binary=str(app/'DungeonSiege2Linux'),exe=str(app/'DungeonSiege2.exe'),game=str(game),data=str(data),profiles=str(app/'profiles.json'))
    (app/'install.json').write_text(json.dumps(config,indent=2)+'\n')
    bindir=Path.home()/'.local/bin'; bindir.mkdir(parents=True,exist_ok=True)
    wrapper=bindir/'dungeon-siege-2-linux'
    wrapper.write_text('#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\n'
        f'app = Path({str(app)!r})\n'
        'config = json.loads((app / "install.json").read_text())\n'
        'args = [sys.executable, str(app / "launcher/launcher.py")]\n'
        'for key, value in config.items(): args += ["--" + key, value]\n'
        'os.execv(sys.executable, args)\n')
    wrapper.chmod(0o755)
    desktop=Path(os.environ.get('XDG_DATA_HOME',Path.home()/'.local/share'))/'applications/dungeon-siege-2-linux.desktop'
    desktop.parent.mkdir(parents=True,exist_ok=True)
    quoted='"'+str(wrapper).replace('\\','\\\\').replace('"','\\"').replace('%','%%')+'"'
    desktop.write_text('[Desktop Entry]\nType=Application\nName=Dungeon Siege II (Linux Preview)\n'
        'Comment=Experimental native Linux build\n'+f'Exec={quoted}\n'
        f'Icon={icon}\nTerminal=false\nCategories=Game;RolePlaying;\nStartupWMClass=dungeon-siege-2-linux\n')
    if shutil.which('update-desktop-database'):
        subprocess.run(['update-desktop-database',str(desktop.parent)],check=False)
    print(f'Installed {wrapper}\nApplication menu: Dungeon Siege II (Linux Preview)\nData and saves: {data}')

if __name__=='__main__':
    try: main()
    except (OSError,ValueError,subprocess.CalledProcessError) as error: sys.exit(str(error))
