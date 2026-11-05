> **Note:** this is the project's earlier, longer README, kept here for the technical detail. If anything below disagrees with the status section of the main [README](../README.md), the main README is the accurate one.

# FPGA Digital Control Core — DE10-Lite

Parameterized **PWM generator** and **quadrature encoder decoder** in Verilog
for the Intel/Terasic DE10-Lite (MAX 10). These are the two peripherals a
motor control loop needs, done in FPGA logic instead of microcontroller
firmware.

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
  skipped state, which a simple interrupt-based counter would silently absorb
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

![PWM duty sweep](waves/pwm_duty_sweep.png)

**Zoom, duty = 8/32 (25%)** — 12 high ticks out of the 50-tick period, every
period identical:

![PWM zoom](waves/pwm_zoom_25pct.png)

**Encoder, full run** — forward, reverse through zero, turnaround, the two
rejected glitches (~40 µs, visible as slivers on A then B), the bounce burst
(~42.5 µs, counted once), and the `err` pulse at the deliberate illegal
transition (~45 µs) with the count held flat:

![Quadrature full run](waves/quad_full_run.png)

**Zoom on the direction reversal** — watch A-leads-B swap to B-leads-A at
the peak; one count per edge (4x) in both directions:

![Quadrature reversal zoom](waves/quad_reversal_zoom.png)

## Synthesis

`synthesis/` holds a complete Quartus Prime Lite project (`.qpf`, `.qsf`
with every pin assignment annotated with its physical header pin, and an
`.sdc` with the 50 MHz clock constraint). See
[`synthesis/README.md`](../synthesis/README.md) for the build/program steps and
the full pin map.

## Hardware verification

Beyond simulation, bringing this up on real DE10-Lite hardware means:
programming the `.sof` over the on-board USB-Blaster (steps in
[`synthesis/README.md`](../synthesis/README.md)); probing `PWM_OUT` (GPIO
header JP1 pin 3) to confirm the 20 kHz carrier and glitch-free
double-buffered duty updates; and wiring a real quadrature encoder to
`ENC_A`/`ENC_B` (JP1 pins 1–2), noting that MAX 10 I/O is **3.3 V only** and
not 5 V-tolerant — a 5 V encoder needs a level shifter or resistor divider.
With `PWM_OUT` + `MOTOR_DIR` driving an H-bridge, the full PWM-to-motor and
encoder-to-count signal chain exists on the FPGA, which is what the
follow-on in-fabric PID closes the loop on.
