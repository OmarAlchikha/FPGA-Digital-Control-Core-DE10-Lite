# Synthesis — Quartus Prime project for the DE10-Lite

The three files in this directory are a complete, ready-to-open Quartus
project:

| File | Purpose |
|---|---|
| `de10_lite_control_core.qpf` | Project file — open this in Quartus |
| `de10_lite_control_core.qsf` | Device selection, source file list, **all pin assignments** |
| `de10_lite_control_core.sdc` | Timing constraints (50 MHz clock, async-input false paths) |

## Build it

1. Install **Quartus Prime Lite** (free; any version ≥ 18.1) **with MAX 10
   device support** selected in the installer.
2. `File → Open Project…` → select `de10_lite_control_core.qpf`.
3. `Processing → Start Compilation` (or double-click *Compile Design*).
   The design is tiny (~150 logic elements) and compiles in about a minute.
4. Output bitstream: `output_files/de10_lite_control_core.sof`.

## Program the board

1. Connect the DE10-Lite over USB (the USB-Blaster is on-board).
2. `Tools → Programmer` → Hardware Setup → *USB-Blaster [USB-0]*.
3. If the `.sof` isn't already listed, *Add File…* →
   `output_files/de10_lite_control_core.sof`.
4. Check *Program/Configure*, press **Start**.

`.sof` programming is volatile (lost at power-off). To make it permanent,
use `File → Convert Programming Files` to generate a `.pof` and program the
MAX 10's internal configuration flash instead.

## Recreating the project from scratch (if you prefer)

New Project Wizard → device **10M50DAF484C7G** → add the three files from
`../rtl/` → set `top_de10_lite` as top-level entity → import
`de10_lite_control_core.qsf` via `Assignments → Import Assignments…` →
add the `.sdc` under `Assignments → Settings → Timing Analyzer`.

## Pin map (matches the .qsf)

| Design port | FPGA pin | Board location | Physical wiring |
|---|---|---|---|
| `MAX10_CLK1_50` | P11 | 50 MHz oscillator | on-board |
| `KEY[0]` (reset) | B8 | push button 0 | on-board |
| `KEY[1]` (direction) | A7 | push button 1 | on-board |
| `SW[9:0]` (duty) | C10…F15 | slide switches | on-board |
| `LEDR[9:0]` (count) | A8…B11 | red LEDs | on-board |
| `ENC_A` | V10 | GPIO[0] | **JP1 header pin 1** |
| `ENC_B` | W10 | GPIO[1] | **JP1 header pin 2** |
| `PWM_OUT` | V9 | GPIO[2] | **JP1 header pin 3** |
| `MOTOR_DIR` | W9 | GPIO[3] | **JP1 header pin 4** |
| encoder GND | — | — | JP1 header pin 12 (GND) |
| encoder supply | — | — | JP1 header pin 29 (+3.3 V) |

JP1 is the 40-pin (2×20) expansion header. Pin 1 is marked on the board
silkscreen; odd pins are one row, even pins the other. Pins 11 (+5 V),
12 (GND), 29 (+3.3 V) and 30 (GND) are power — everything else is GPIO.

**⚠ 3.3 V I/O only.** MAX 10 pins are not 5 V tolerant. A 5 V encoder
needs a level shifter or at minimum a resistor divider on A/B — see the
top-level README.
