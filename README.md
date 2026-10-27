<h1 align="center">Punch-Out!! Hardware FPGA Core</h1>

<p align="center">
  Arcade hardware implementation for MiSTer FPGA
</p>

---

## Overview

FPGA implementation of the **Nintendo Punch-Out!! hardware (1984)**: the CHP1 CPU, VIDEO and BAK boards, with their two monitors driven from one timing chain.

The Z80 main CPU, the RP2A03 sound CPU and APU, and the Sanyo VLM5030 speech chip are all recreated in logic. Speech is synthesized from the original speech ROM (no samples) and runs through the board's own output filter.

This core targets MiSTer FPGA and aims for accurate gameplay behavior, video timing, and sound reproduction.

---

## Supported Games

| Hardware | Games |
|----------|-------|
| Punch-Out!! (CHP1) | Punch-Out!! (Rev B), Rev A, Rev A (harder), Japan, Italian bootleg |
| Super Punch-Out!! (CHP1 + CHS1-01-EXP) | Super Punch-Out!! (Rev B), Rev A, Japan |

Clones and regional versions are in `releases/_alternatives/`.

Arm Wrestling runs on a related board and is not supported yet.

---

## Controls

Default MiSTer gamepad mapping:

| Input | Action |
|-------|--------|
| D-Pad / Joystick | The cabinet's joystick (4-way) |
| B | Left Blow |
| A | Right Blow |
| X | KO Blow |
| Y | Duck (Super Punch-Out!!) |
| Select | Insert Coin |
| Start | 1 Player Start (also throws a Left Blow) |
| Right Shoulder | 2 Player Start |
| Left Shoulder | Pause |

---

## Screen Layout

The cabinet has two monitors: the **top** screen shows the opponent's stats, points and timer, the **bottom** screen shows the fight. **Game Options → Screen Layout** chooses how they reach your displays:

| Setting | HDMI | Analog (CRT) |
|---------|------|--------------|
| Vert. Top/Bottom (default, like the cabinet) | Top above Bottom | Top above Bottom (31 kHz) |
| Horz. Top\|Bottom | Top left, Bottom right | Top left, Bottom right (15 kHz) |
| Horz. Bottom\|Top | Bottom left, Top right | Bottom left, Top right (15 kHz) |
| Vert. Bottom/Top | Bottom above Top | Bottom above Top (31 kHz) |
| Single Top | Top | Top |
| Single Bottom | Bottom | Bottom |
| Split Top>HDMI | Top | Bottom |
| Split Top>CRT | Bottom | Top |

**15 kHz monitors: there is no vertical (stacked) mode.** Two screens stacked are 448 lines, which only fits a frame at 31 kHz, so the two Vert. layouts send a 31 kHz progressive signal to the analog output. Use a 31 kHz-capable (VGA / multisync) monitor for them; on a 15 kHz-only arcade monitor use a Horz., Single or Split layout. The 31 kHz signal is already line-doubled, so the scandoubler and its effects do not apply in the Vert. layouts.

**Split layouts** put a different screen on each output. They need the default `MiSTer.ini` video settings: `vga_scaler=1` (scaler output on VGA) or `direct_video=1` (analog signal on HDMI) put the same picture on both outputs.

Flip Screen flips each screen in place, as the cabinet does.

---

## Features

- Z80, RP2A03 (CPU + APU) and VLM5030 speech recreated in logic; speech synthesized, with the board's speech filter
- Super Punch-Out!!'s security board (RP5C01 clock chip + RP5H01 counter) recreated in logic
- Both monitors, in eight screen layouts across HDMI and analog
- Speech and music volume controls
- Battery-backed RAM (scores and settings) saved per game
- DIP switches for every set, taken from MAME
- Flip screen, pause, and scandoubler options
- MiSTer-compatible .mra provided
- Verified ROM definitions with checksums

---

## ROM Requirements

ROM files are **not included**.

To use this arcade core, you must provide legally obtained ROM files.

To simplify setup:

- `.mra` files are provided in the **Releases** section.
- The `.mra` specifies all required ROM files along with checksums.
- The ROM `.zip` filename corresponds to the naming convention used by the MAME project.

For setup instructions and environment configuration, refer to:

MiSTer Arcade ROM guide:  
https://github.com/MiSTer-devel/Main_MiSTer/wiki/Arcade-Roms

---

## Installation

1. Copy the core `.rbf` file to your MiSTer `/_Arcade/cores` folder.
2. Copy the `.mra` files (including the `_alternatives` folder) to your MiSTer `/_Arcade` folder.
3. Place the appropriate ROM `.zip` files in your `/games/mame` directory.
4. Launch the core from the MiSTer Arcade menu.

---

## Legal Notice

This project contains **no copyrighted game data**.

Users are responsible for obtaining and using ROM files in accordance with applicable laws.

Do not request ROM files in issues or discussions.

---

## Credits

FPGA core development: RodimusFVC  
Memory maps, video and sound per the MAME project (`punchout.cpp`: Nicola Salmoria and contributors)  
VLM5030 speech: port of MAME's `vlm5030.cpp` (Tatsuyuki Satoh), coefficient tables from the chip decap (ogoun, John McMaster)  
T80 CPU core: Daniel Wallner, with updates by MikeJ and Sorgelig  
T65 CPU core: Daniel Wallner, with updates by MikeJ and others  
Pause module: Jim Gregory  
Original arcade games © Nintendo and their respective owners

---
