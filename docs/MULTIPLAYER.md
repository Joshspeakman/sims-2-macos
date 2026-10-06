# Multiplayer

Beta: in progress. Dungeon Siege II's multiplayer screens are switched
off in the GOG 2.3 release; this port switches them back on and connects them to a replacement for GameSpy, the
online service the game was built on (shut down in 2014).

## What works so far

- **Main menu → Multiplayer** opens the game's own screens (Local Network, Internet, GameSpy).
- **The lobby:** the game signs in to [OpenSpy](https://openspy.net), the community-run GameSpy replacement, and shows
  its party selection, game list and chat rooms. Dungeon Siege II goes through this lobby for every kind of game,
  LAN games included.
- **Parties and portals:** creating a multiplayer party in the lobby works, and the portal list (OpenSpy's rooms,
  with their player and game counts) comes up.
- **Not tested yet:** hosting and joining a game (needs two machines), and play between a Mac and a PC. Importing a
  single-player hero as a party has only been tried by scripted input, which can't double-click the list.

## Your CD key

The online lobby needs a CD key: the 25-character product key of an **original retail copy** of Dungeon Siege II (the
sticker under disc 1 in the box). The game doesn't read the key itself but a hash of it that the retail installer used
to write; the port computes the same hash from your key. Only that hash is stored, never the key.

**The Steam and GOG releases come without a CD key.** Both sell Dungeon Siege II as a single-player game (GameSpy had
shut down) and give out no in-game key; the keys sold for them are store activation codes, which the game doesn't
accept. Single-player is unaffected. For now, online play needs an original retail key; this port doesn't work around
the key check. A key for every buyer would have to come from the rights holder.

**Each copy needs its own key.** The same key can't be in the lobby from two computers at once, as with GameSpy.

- **On a Mac (this app):** in the launch window, click **Online** and enter the key. Or, from the repository:
  `./install.sh --cd-key`. A first install also offers it at the end.
- **On native Linux:** click **Enter your CD key** in the launcher. The host imports the saved hash into the
  game's registry at startup, just as the Mac host does. Restart the game after changing the key.
- **For a Windows PC** (or Wine/Proton on Linux) **without the retail installer:** on any Mac with this repository,
  `./install.sh --cd-key --reg-file DS2-cdkey.reg` with that PC's own key, then on the PC double-click the `.reg`
  file to import it. (A PC also needs the OpenSpy client to reach the lobby.)

The hash is kept in the data folder as `cdkey-hash.txt` (readable only by you); remove it there, or with **Remove
Key** in the launch window.

## Settings

- `DS2_LOBBY=off`: don't redirect the game's GameSpy addresses to OpenSpy.
- `DS2_NO_MULTIPLAYER=1`: keep the Multiplayer button disabled, as the GOG release ships.
- `DS_NO_PORTMAP=1`: don't ask the router to forward ports when hosting.

## Privacy

Going online sends your nickname, your IP address and your game listings to OpenSpy's servers, as the game once did
to GameSpy. Your CD key hash is sent to the lobby, as the original game did. A built-in lobby for playing on a LAN
without any online service is planned.
