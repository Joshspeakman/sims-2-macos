#!/usr/bin/env python3
"""scenario.py <name> [native|ref|both] : one scripted session played by the native port and by the original game
under Proton (tests/fnv_ref.py in headless gamescope), with screenshots at the same moments, then compared
(tools/imgdiff.py). Scenarios start a new game, accept the default name and use the console, so no mouse is needed.
Output: work/scen-<name>/{native,ref}/<shot>.png and a report."""
import os, sys, subprocess, json
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIK = {'Down': 208, 'Up': 200, 'Left': 203, 'Right': 205, 'Return': 28, 'Escape': 1, 'space': 57, 'grave': 41, 'Tab': 15,
       'v': 47, 'q': 16, 'e': 18, 'w': 17, 'a': 30, 's': 31, 'd': 32, 'r': 19, 'f': 33, 'm': 50, 'i': 23, 'j': 36, 'p': 25}
# the opening shared by every scenario: New game, Yes, skip the intro, the DLC messages, accept the name (ready ~118 s)
OPENING = [(62, 'key', 'Down'), (64, 'key', 'Down'), (66, 'key', 'Return'), (69, 'key', 'Left'), (70, 'key', 'Return'),
           (78, 'key', 'Escape'), (80, 'key', 'space'), (82, 'key', 'Escape')] + \
          [(t, 'key', 'Return') for t in range(96, 117, 2)] + [(120, 'key', 'Return')]
# loading tests/saves/fnvtest1.fos (made after character creation, Goodsprings at noon) with Continue: ready ~95 s
LOAD = [(62, 'key', 'Down'), (64, 'key', 'Return'), (67, 'key', 'Return')]
SAVE = os.path.join(HERE, 'tests', 'saves', 'fnvtest1.fos')
def console(t, *cmds):                 # open the console, run each command, close it
    steps, at = [(t, 'key', 'grave')], t + 2
    for c in cmds: steps += [(at, 'type', c), (at + 1 + len(c) * 0.15, 'key', 'Return')]; at += 3 + len(c) * 0.15
    return steps + [(at, 'key', 'grave')], at + 1
SCENARIOS = {}
def scenario(name, secs):
    def deco(fn): SCENARIOS[name] = (secs, fn); return fn
    return deco
@scenario('docs-house', 150)
def _():
    return OPENING + [(135, 'shot', 'name-box')] + console(137, 'tm')[0] + [(145, 'shot', 'room')]
def outdoor(hour, angle=90):
    s, t = console(125, 'set gamehour to %g' % hour, 'cow WastelandNV -19 0')
    s2, t2 = console(t + 20, 'player.setangle x 0', 'player.setangle z %d' % angle, 'tm')
    return s + s2, t2
@scenario('goodsprings-noon', 185)
def _():
    s, t = outdoor(12); return OPENING + s + [(t + 6, 'shot', 'noon'), (t + 12, 'shot', 'noon2')]
@scenario('goodsprings-night', 185)
def _():
    s, t = outdoor(23); return OPENING + s + [(t + 6, 'shot', 'night'), (t + 12, 'shot', 'night2')]
@scenario('goodsprings-dusk', 185)
def _():
    s, t = outdoor(19, 200); return OPENING + s + [(t + 6, 'shot', 'dusk'), (t + 12, 'shot', 'dusk2')]
def world(t0, *cmds):                  # after loading: console commands, menus hidden
    s, t = console(t0, *(list(cmds) + ['tm']))
    return LOAD + s, t
@scenario('load-noon', 140)
def _():
    s, t = world(100, 'player.setangle x 0', 'player.setangle z 90'); return s + [(t + 5, 'shot', 'view1'), (t + 12, 'shot', 'view1b')]
@scenario('load-night', 130)
def _():
    s, t = world(100, 'set gamehour to 23', 'player.setangle x 0', 'player.setangle z 90'); return s + [(t + 10, 'shot', 'night')]
@scenario('load-dusk', 130)
def _():
    s, t = world(100, 'set gamehour to 19', 'player.setangle x 0', 'player.setangle z 220'); return s + [(t + 10, 'shot', 'dusk')]
def travel(t0, *cmds):                 # after loading: commands ending in a coc, then (once it has loaded) menus hidden
    s, t = console(t0, *cmds); s = s[:-1]             # the console stays open through the load (its closing key is lost)
    at = t + 25; s2 = [(at, 'type', 'tm'), (at + 1.5, 'key', 'Return'), (at + 3, 'key', 'grave')]
    return LOAD + s + s2, at + 4
@scenario('load-saloon', 150)
def _():
    s, t = travel(100, 'coc GSProspectorSaloonInterior'); return s + [(t + 4, 'shot', 'saloon')]
@scenario('load-strip', 160)
def _():
    s, t = travel(100, 'set gamehour to 21', 'coc TheStrip'); return s + [(t + 4, 'shot', 'strip')]
@scenario('saloon', 170)
def _():
    s, t = console(125, 'coc GSProspectorSaloonInterior')
    s2, t2 = console(t + 20, 'tm')
    return OPENING + s + s2 + [(t2 + 3, 'shot', 'saloon')]
@scenario('strip', 185)
def _():
    s, t = console(125, 'set gamehour to 21', 'coc TheStrip')
    s2, t2 = console(t + 30, 'tm')
    return OPENING + s + s2 + [(t2 + 3, 'shot', 'strip')]

def native_script(steps, out):
    parts = []
    for t, kind, arg in steps:
        if kind == 'key': parts.append('@%g:dik:%d' % (t, DIK[arg]))
        elif kind == 'type': parts.append('@%g:ditype:%s' % (t, arg))
        elif kind == 'shot': parts.append('@%g:shot:%s/%s.png' % (t, out, arg))
    return ';'.join(parts)
def ref_script(steps):
    parts = []
    for t, kind, arg in steps:
        if kind == 'key': parts.append('@%g:key:%s' % (t, arg))
        elif kind == 'type': parts.append('@%g:type:%s' % (t, arg))
        elif kind == 'shot': parts.append('@%g:shot:%s' % (t, arg))
    return ';'.join(parts)
if __name__ == '__main__':
    name, which = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'both'
    secs, fn = SCENARIOS[name]; steps = sorted(fn(), key=lambda s: s[0]); secs = max(secs, int(steps[-1][0]) + 8)   # room for the last step
    base = os.path.join(HERE, 'work', 'scen-' + name); nat, ref = os.path.join(base, 'native'), os.path.join(base, 'ref')
    os.makedirs(nat, exist_ok=True); os.makedirs(ref, exist_ok=True)
    procs = []
    uses_save = any(st[0] == 67 and st[2] == 'Return' for st in steps)
    if which in ('native', 'both'):
        env = dict(os.environ, SESSION_ENV='DS_SHOT_RAW=1 ' + os.environ.get('SESSION_ENV', ''), SHOT='1000')
        if uses_save: env['SAVE'] = SAVE
        procs.append(subprocess.Popen([os.path.join(HERE, 'tools', 'fnv_session.sh'), 'scen-' + name, str(secs), native_script(steps, nat)], env=env,
                                      stdout=open(os.path.join(base, 'native.out'), 'w'), stderr=subprocess.STDOUT))
    if which in ('ref', 'both'):
        saves = os.path.expanduser('~/Games/fnv-ref-prefix/pfx/drive_c/users/steamuser/Documents/My Games/FalloutNV/Saves')
        os.makedirs(saves, exist_ok=True)
        for f in os.listdir(saves): os.remove(os.path.join(saves, f))
        if uses_save: import shutil; shutil.copy(SAVE, saves)
        procs.append(subprocess.Popen(['timeout', str(secs + 80), 'gamescope', '--backend', 'headless', '-W', '1280', '-H', '720', '-w', '1280', '-h', '720', '--',
                                       os.path.join(HERE, 'tests', 'fnv_ref.py'), ref, str(secs), ref_script(steps)],
                                      stdout=open(os.path.join(base, 'ref.out'), 'w'), stderr=subprocess.STDOUT))
    for p in procs: p.wait()
    for t, kind, arg in steps:
        if kind != 'shot': continue
        a, b = os.path.join(nat, arg + '.png'), os.path.join(ref, arg + '.png')
        if os.path.exists(a) and os.path.exists(b):
            r = subprocess.run([sys.executable, os.path.join(HERE, 'tools', 'imgdiff.py'), a, b, os.path.join(base, 'diff-' + arg + '.png')], capture_output=True, text=True)
            print('%-12s %s' % (arg, r.stdout.strip()))
        else: print('%-12s missing %s' % (arg, 'native' if not os.path.exists(a) else 'ref'))
