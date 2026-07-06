# FPGA Digital Control Core — DE10-Lite

Parameterized **PWM generator** and **quadrature encoder decoder** in Verilog
for the Intel/Terasic DE10-Lite (MAX 10). These are the two peripherals every
motor control loop stands on — and this repo is the tie-back project: it
re-implements, in hardware, exactly the two jobs the Arduino did in
**Project 2** (PWM drive to the H-bridge) and **Project 4** (encoder feedback
for closed-loop control), so the loop can eventually close *inside the FPGA*
instead of in Arduino firmware.

```
├── rtl/                          synthesizable Verilog
│   ├── pwm_generator.v           parameterized PWM (frequency + resolution)
│   ├── quadrature_decoder.v      4x quadrature decode, debounce, direction, error flag
│   └── top_de10_lite.v           board wrapper: switches → duty, encoder → LEDs
├── testbench/                    self-checking testbenches (Icarus Verilog)
│   ├── tb_pwm_generator.v
│   ├── tb_quadrature_decoder.v
│   ├── Makefile                  `make` runs everything
│   └── plot_waves.py             renders the waveform PNGs below from the VCDs
├── synthesis/                    complete Quartus Prime project
│   ├── de10_lite_control_core.qpf / .qsf / .sdc
│   └── README.md                 build + program instructions, full pin map
└── docs/waves/                   waveform images from the testbench runs
```

## How this ties back to Projects 2 and 4

On the Arduino builds, the control loop looked like this:

```
Project 2:  analogWrite() ──► H-bridge ──► motor            (open/closed-loop drive)
Project 4:  encoder ──► pin-change ISRs ──► count ──► PID ──► analogWrite()
```

That architecture has two ceilings baked in:

1. **PWM quality** — `analogWrite()` on an Uno is ~490 Hz/976 Hz at 8 bits.
   Audible whine, coarse torque quantization, and the timer is shared with
   `millis()`.
2. **Encoder throughput** — every quadrature edge costs an interrupt. Spin the
   motor fast enough (or add a finer encoder) and the ISR load starves the
   loop, drops edges, and the position estimate silently corrupts.

This project moves both jobs into fabric, where they cost *zero* processor
time and run at 50 MHz:

| Arduino (Projects 2/4) | This core |
|---|---|
| `analogWrite()`, ~490 Hz, 8-bit | `pwm_generator`, 20 kHz (any freq), 10-bit (any width), glitch-free duty updates |
| Pin-change ISR counting, 1x/2x decode, edges lost under load | `quadrature_decoder`, full 4x decode, never misses an edge, hardware glitch filter, illegal-transition detector |
| Loop rate limited to a few kHz | `period_start` strobe lets a loop run once per PWM period (20 kHz) with zero jitter |

The **next step** this enables: drop a PID block between `count` and `duty`
in `top_de10_lite.v` — the decoder's output is the feedback term, the PWM's
input is the control effort, and `period_start` is the sample clock. Same
loop as Project 4, closed digitally in fabric instead of on the Arduino. The
Arduino (or the Nios II soft core, or a PC over UART) then only supplies
*setpoints* rather than running the loop.

## The modules

### `rtl/pwm_generator.v`

| Parameter | Default | Meaning |
|---|---|---|
| `CLK_FREQ_HZ` | 50_000_000 | input clock (DE10-Lite oscillator) |
| `PWM_FREQ_HZ` | 20_000 | carrier frequency |
| `RESOLUTION` | 10 | duty-input width in bits |

Frequency and resolution are independent: the period is
`CLK_FREQ_HZ / PWM_FREQ_HZ` clocks and the duty code is scaled onto it, so
you pick both freely (rule of thumb: keep `period ≥ 2^RESOLUTION` so every
code is distinct — at 50 MHz/20 kHz you get 2500 ticks, enough for 11 bits).
Details that matter for motor drive:

- **True 0% and true 100%**: duty 0 is DC-low, duty max is DC-high — no
  sliver pulses at the extremes (sliver pulses are what blow H-bridge
  drivers).
- **Double-buffered duty**: the duty input is latched only at period
  boundaries, so a mid-period update can never produce a runt pulse.
- **`period_start` strobe**: one pulse per carrier period — the natural
  sample clock for a digital control loop.

### `rtl/quadrature_decoder.v`

| Parameter | Default | Meaning |
|---|---|---|
| `COUNT_WIDTH` | 16 | signed position counter width |
| `DEBOUNCE_TICKS` | 50 | clocks a level must persist before it's accepted (0 = bypass) |

Each channel goes through a 2-flop synchronizer (encoder edges are
asynchronous) and then a persistence glitch filter: a new level is only
accepted after it holds for `DEBOUNCE_TICKS` consecutive clocks — 1 µs at
the default 50/50 MHz, which rejects contact bounce and cable noise while
passing any encoder slower than ~250k edges/s. Decoding is **full 4x**
(every edge of A and B counts), with:

- signed position `count`, direction flag `dir` (A-leads-B = up),
- a one-clock `step` pulse per counted edge (feeds a velocity estimator),
- an `err` pulse when both channels change in one filtered sample — a
  skipped state, which the Arduino ISR version would have silently absorbed
  as position drift. Here it's observable.

### `rtl/top_de10_lite.v` — hardware demo wrapper

`SW[9:0]` set the 10-bit duty, `KEY0` is reset, `KEY1` drives a `MOTOR_DIR`
output for an H-bridge, the encoder count's low 10 bits show live on
`LEDR[9:0]`, and the 20 kHz PWM comes out on the GPIO header.

## Verification

### Why Icarus Verilog (and not Verilator)

Both are fine tools; Icarus is the right fit *here*:

- These testbenches lean on **event-driven, asynchronous timing** — encoder
  edges, 40 ns glitches, and contact bounce are modeled with `#delay`
  statements unrelated to the clock. That's native in Icarus. Verilator is
  cycle-based: modeling sub-cycle async glitches means hand-writing a C++
  harness that toggles inputs between evaluations — more code to get *less*
  faithful stimulus.
- Self-checking is done with plain Verilog tasks — no C++ build system,
  `make` and 2 seconds of wall time is the whole flow.
- Verilator's advantage is raw speed on big designs (thousands of cycles per
  second matter when you simulate a CPU for minutes). These sims finish in
  milliseconds; the speed is irrelevant.
- Icarus dumps VCD out of the box for GTKWave (and for the plots below).

If this grows into a full in-fabric PID with long closed-loop simulations, a
Verilator + C++ plant-model co-simulation would be the right upgrade — noted
as future work.

### Running the testbenches

```bash
sudo apt install iverilog     # or: brew install icarus-verilog
cd testbench
make                          # runs both, prints PASS/FAIL per check
make waves                    # opens the VCDs in GTKWave
```

Both testbenches measure the DUT against an independent model and print a
verdict — they don't just wiggle pins. Current status: **23/23 checks pass**.

**PWM checks:** duty extremes (0% must be DC-low, 100% must be DC-high —
verified over multiple full periods), minimum 1-tick pulse, 25/50/75%
linearity by counting high clocks per period, exact period length, and
glitch-free double-buffering (a mid-period duty change must not alter the
period in flight, and must apply on the next one).

**Encoder checks:** 12 edges forward, 20 reverse crossing zero (signed
count), **direction reversal mid-cycle** (turnaround between detents nets to
zero), `dir` flag both ways, sub-filter glitches on A and B ignored, a
**bouncing edge counted exactly once**, an illegal two-bit transition
pulsing `err` with the count held, and correct counting after recovery.

### Waveforms from the actual runs

Rendered straight from the testbench VCDs by `testbench/plot_waves.py`
(`pip install matplotlib`, run after `make`):

**PWM duty sweep** — 0 → 1 → 8 → 16 → 24 → 31/31. Note the output is
solid-low at duty 0 and solid-high at duty 31 (the ~18–23 µs and ~23–27 µs
regions), not thin slivers:

![PWM duty sweep](docs/waves/pwm_duty_sweep.png)

**Zoom, duty = 8/32 (25%)** — 12 high ticks out of the 50-tick period, every
period identical:

![PWM zoom](docs/waves/pwm_zoom_25pct.png)

**Encoder, full run** — forward, reverse through zero, turnaround, the two
rejected glitches (~40 µs, visible as slivers on A then B), the bounce burst
(~42.5 µs, counted once), and the `err` pulse at the deliberate illegal
transition (~45 µs) with the count held flat:

![Quadrature full run](docs/waves/quad_full_run.png)

**Zoom on the direction reversal** — watch A-leads-B swap to B-leads-A at
the peak; one count per edge (4x) in both directions:

![Quadrature reversal zoom](docs/waves/quad_reversal_zoom.png)

## Synthesis

`synthesis/` holds a complete Quartus Prime Lite project (`.qpf`, `.qsf`
with every pin assignment annotated with its physical header pin, and an
`.sdc` with the 50 MHz clock constraint). See
[`synthesis/README.md`](synthesis/README.md) for the build/program steps and
the full pin map.

## What you need to do on your end

### 1. Build and load onto the DE10-Lite

Open `synthesis/de10_lite_control_core.qpf` in Quartus Prime Lite (with
MAX 10 support installed), compile, and program the `.sof` over the on-board
USB-Blaster (`Tools → Programmer`). Step-by-step in
[`synthesis/README.md`](synthesis/README.md).

### 2. Verify the PWM with a scope / logic analyzer

Probe **GPIO header JP1 pin 3** (`PWM_OUT`) against **pin 12** (GND):

- You should see a **20 kHz** carrier (50 µs period).
- Duty follows `SW[9:0]` as a 10-bit binary number: all down = flat 0 V,
  all up = flat 3.3 V, `SW9` alone up = 50%.
- Flip switches while watching: the edge should move **without any runt
  pulses** — that's the double-buffering.
- On a logic analyzer, measure high-time: it should be
  `duty/1024 × 50 µs` to within one 20 ns clock tick.

`MOTOR_DIR` is on **pin 4**; it follows `KEY1`.

### 3. Wire up an actual encoder

| Encoder wire | Connect to | Note |
|---|---|---|
| Channel A | JP1 **pin 1** (`ENC_A`) | weak pull-up enabled on-chip |
| Channel B | JP1 **pin 2** (`ENC_B`) | weak pull-up enabled on-chip |
| GND | JP1 **pin 12** | common ground is mandatory |
| VCC | JP1 **pin 29** (+3.3 V) | see warning below |

> **⚠ 3.3 V only.** MAX 10 I/O is **not 5 V tolerant**. A bare mechanical
> encoder (e.g. KY-040 module *without* its pull-ups to 5 V) is fine on
> 3.3 V. A 5 V-supplied optical/magnetic encoder needs a level shifter or a
> resistor divider (e.g. 2.2 kΩ series / 3.3 kΩ to GND) on A and B. If you
> use the motor+encoder from Projects 2/4 and its encoder board is 5 V,
> divide it down.

Then: turn the shaft and watch `LEDR[9:0]` count up in binary one direction
and down (two's complement, LEDs mostly on) the other. One full turn of a
600 PPR encoder moves the count by 2400 — that's the 4x decoding. If the
direction is backwards from what you want, swap the A and B wires.

### 4. (Optional) drive the actual motor

`PWM_OUT` + `MOTOR_DIR` map directly onto an H-bridge module's PWM/DIR
inputs (the same driver from Project 2 works — its inputs are logic-level
and 3.3 V-compatible on common boards; check yours). Power the motor from
its own supply, **never** from the header's 5 V pin, and keep grounds
common. At that point the full Project 2 + Project 4 signal chain exists on
the FPGA, and the switches are your open-loop duty command — the PID that
closes `count → duty` is the follow-on project.
