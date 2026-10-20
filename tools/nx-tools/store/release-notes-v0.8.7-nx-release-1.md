# Friday Night Funkin' V-Slice 0.8.7 for Nintendo Switch (unofficial) — release 1

An unofficial homebrew port of the official V-Slice engine by The Funkin' Crew, version 0.8.7, aiming to play exactly like the PC game.

## Install

1. Copy `Funkin.nro` to `/switch/Friday-Night-Funkin/Funkin.nro` on the SD card (or install it from the Homebrew App Store).
2. Open the homebrew menu **from a game** (hold R while launching any title) and start it.
3. On first launch it downloads the official game files (about 734 MB) from The Funkin' Crew's repository, [FunkinCrew/funkin.assets](https://github.com/FunkinCrew/funkin.assets), at the commit of version 0.8.7, checks each file against its SHA-256 and restarts into the game. Without internet on the console, the screen explains how to copy the files from a computer.

About 1.1 GB free on the SD card is needed. Saves and mods live in `/switch/Friday-Night-Funkin/`.

## What's in it

- V-Slice 0.8.7: every week, Weekend 1, Erect and Pico mixes, Freeplay, Story Mode, Character Select and Polymod mods.
- Asset installer with resume after a lost connection or a closed game.
- Cutscenes played from the official video files (minimal LGPL FFmpeg on a free CPU core).
- A Switch audio driver that recovers after HOME, sleep and long sessions; memory management for the console's heap; GPU at 460.8 MHz handheld and 768 MHz docked.
- Nintendo button layout and names, HD Rumble, Switch settings page.

## The .nro contains no game assets

It contains the game's code (Apache-2.0), the port's code and libraries, and a list of the official files with their sizes and hashes. No art, music, sounds, videos, charts or scripts from Friday Night Funkin' are distributed here; they come from The Funkin' Crew's own repository, under its licence, for your own use. Please don't share them.

## Licences

- Game and port code: Apache License 2.0.
- FFmpeg (LGPL 2.1+), built with `tools/nx-tools/build_ffmpeg_nx.sh` from the FFmpeg 7.1 release; OpenAL Soft (LGPL 2.0+) from devkitPro's `switch-openal-soft`; SDL2 (zlib); curl (curl licence); Mesa, FreeType, HarfBuzz and the other devkitPro portlibs under their licences. The full source to rebuild and relink this `.nro` is in this repository at this tag, with every library pinned in `hmm.json`.

## Credits

- The Funkin' Crew: Friday Night Funkin'. Please support the official game.
- FunkinNXTeam (ヴェン, Andres_Github and the team): the first V-Slice 0.8.1 Switch port this one started from.
- Slushi: lime-nx and hx_libnx.
- devkitPro, Citron, HaxeFlixel, OpenFL and lime.

Unofficial port, not affiliated with The Funkin' Crew Inc. or Nintendo.
