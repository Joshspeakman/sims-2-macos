/* Address-specific hooks and user-data names must follow the compiled executable. */
#ifndef DS2_EDITION_H
#define DS2_EDITION_H
#ifdef FNV_EDITION
/* Fallout: New Vegas (GOG 1.4.0.525): no Dungeon Siege hooks; the names below are what the host and registry use */
#define DS2_IMAGE_END 0x01409000u
#define DS2_TITLE "Fallout: New Vegas"
#define DS2_DOCUMENTS "FalloutNV"
#define DS2_INI "Fallout.ini"
#define GAME_EXE "FalloutNV.exe"
#define DS2_LIGHT_LOOP 0xffffff00u
#define DS2_LIGHT_AFTER 0xffffff01u
#define DS2_LIGHT_ZERO 0u
#define DS2_LIGHT_ONE 0u
#define DS2_LIGHT_SCALE 0u
#define DS2_MAT3 0xffffff02u
#define DS2_MAT3_FN fnv_no_mat3
#define DS2_MOOD_READ 0xffffff03u
#define DS2_SKRIT_MANAGER 0u
#elif defined(SIMS2_EDITION)
/* The Sims 2 Legacy Collection (Steam 3314070): one executable for every pack, in EP9\TSBin below the collection
 * folder (the virtual game folder); image at 0xa0000000. No Dungeon Siege hooks. */
#define DS2_IMAGE_END 0xa120f000u
#define DS2_TITLE "The Sims 2"
#define DS2_DOCUMENTS "The Sims 2 Legacy"
#define DS2_INI "Config.ini"
#define GAME_EXE "EP9\\TSBin\\Sims2EP9.exe"
#define GAME_DIR "EP9\\TSBin"
#define DS2_LIGHT_LOOP 0xffffff00u
#define DS2_LIGHT_AFTER 0xffffff01u
#define DS2_LIGHT_ZERO 0u
#define DS2_LIGHT_ONE 0u
#define DS2_LIGHT_SCALE 0u
#define DS2_MAT3 0xffffff02u
#define DS2_MAT3_FN fnv_no_mat3
#define DS2_MOOD_READ 0xffffff03u
#define DS2_SKRIT_MANAGER 0u
#elif defined(DS2_BROKEN_WORLD)
#define DS2_IMAGE_END 0x01e8a000u
#define DS2_TITLE "Dungeon Siege II: Broken World"
#define DS2_DOCUMENTS "Dungeon Siege 2 Broken World"
#define DS2_INI "DungeonSiege2BrokenWorld.ini"
#define DS2_LIGHT_LOOP 0x00553450u
#define DS2_LIGHT_AFTER 0x00553545u
#define DS2_LIGHT_ZERO 0x00b8f468u
#define DS2_LIGHT_ONE 0x00b8ed44u
#define DS2_LIGHT_SCALE 0x00b8e84cu
#define DS2_MAT3 0x0068e24cu
#define DS2_MAT3_FN f_0068e24c
#define DS2_MOOD_READ 0x00921f86u
#define DS2_SKRIT_MANAGER 0x00d01604u
#else
#define DS2_IMAGE_END 0x01000000u
#define DS2_TITLE "Dungeon Siege II"
#define DS2_DOCUMENTS "Dungeon Siege 2"
#define DS2_INI "DungeonSiege2.ini"
#define DS2_LIGHT_LOOP 0x00544df0u
#define DS2_LIGHT_AFTER 0x00544ee5u
#define DS2_LIGHT_ZERO 0x00a8f338u
#define DS2_LIGHT_ONE 0x00a8ec14u
#define DS2_LIGHT_SCALE 0x00a8e71cu
#define DS2_MAT3 0x0067aeb6u
#define DS2_MAT3_FN f_0067aeb6
#define DS2_MOOD_READ 0x0090a076u
#define DS2_SKRIT_MANAGER 0x00bcb248u
#endif
/* a later game (SSE2 code, shader-model-3 card, none of DS2's native loops) */
#if defined(FNV_EDITION) || defined(SIMS2_EDITION)
#define MODERN_EDITION 1
#endif
#ifndef GAME_EXE
#define GAME_EXE "DungeonSiege.exe"
#endif
#ifdef FNV_EDITION
#define HOST_NAME "FalloutNVNative"                 /* the app's executable: log lines and reports */
#elif defined(SIMS2_EDITION)
#define HOST_NAME "Sims2Native"
#else
#define HOST_NAME "DungeonSiegeNative"
#endif
#endif
