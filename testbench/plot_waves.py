#!/usr/bin/env python3
"""Render waveform images from the testbench VCD dumps.

Run the testbenches first (``make``), then::

    python3 plot_waves.py

Outputs PNGs into ../docs/waves/. Requires matplotlib.
"""

import os
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "docs", "waves")


def parse_vcd(path, wanted):
    """Minimal VCD parser. `wanted` maps signal reference name -> key.
    Returns {key: [(time, value), ...]} with integer values (x/z -> None)."""
    id_to_key = {}
    data = {k: [] for k in wanted.values()}
    t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if line.startswith("$var"):
                    parts = line.split()
                    code, ref = parts[3], parts[4]
                    if ref in wanted:
                        id_to_key[code] = wanted[ref]
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if line[0] == "#":
                t = int(line[1:])
            elif line[0] in "01xz":
                code = line[1:]
                if code in id_to_key:
                    v = int(line[0]) if line[0] in "01" else None
                    data[id_to_key[code]].append((t, v))
            elif line[0] in "bB":
                val, code = line[1:].split()
                if code in id_to_key:
                    v = None if ("x" in val or "z" in val) else int(val, 2)
                    data[id_to_key[code]].append((t, v))
    return data


def to_steps(changes, t_end):
    """Value-change list -> step-plot arrays."""
    xs, ys = [], []
    for i, (t, v) in enumerate(changes):
        nxt = changes[i + 1][0] if i + 1 < len(changes) else t_end
        xs += [t, nxt]
        ys += [v, v]
    return xs, ys


def signed(v, bits):
    if v is None:
        return None
    return v - (1 << bits) if v >= (1 << (bits - 1)) else v


def digital_trace(ax, changes, t_end, offset, label, color):
    xs, ys = to_steps(changes, t_end)
    ys = [offset + (0.8 * y if y is not None else 0.4) for y in ys]
    ax.plot([x / 1e6 for x in xs], ys, color=color, lw=1.2)
    # axes-fraction x so the label stays visible whatever the xlim is
    ax.annotate(label, xy=(0, offset + 0.4), xycoords=("axes fraction", "data"),
                xytext=(-6, 0), textcoords="offset points",
                ha="right", va="center", fontsize=10)


def plot_pwm():
    d = parse_vcd(
        "tb_pwm_generator.vcd",
        {"pwm_out": "pwm", "duty": "duty", "period_start": "ps"},
    )
    t_end = max(t for sig in d.values() for t, _ in sig)

    fig, (ax0, ax1) = plt.subplots(
        2, 1, figsize=(11, 4.2), sharex=True,
        gridspec_kw={"height_ratios": [1, 1.4]}, constrained_layout=True,
    )

    xs, ys = to_steps(d["duty"], t_end)
    ax0.plot([x / 1e6 for x in xs], ys, color="#c85000", lw=1.4)
    ax0.set_ylabel("duty code\n(0–31)")
    ax0.set_ylim(-2, 34)
    ax0.grid(alpha=0.3)
    ax0.set_title("pwm_generator: duty sweep 0 → 1 → 8 → 16 → 24 → 31 (PERIOD = 50 clks, RES = 5 bits)")

    xs, ys = to_steps(d["pwm"], t_end)
    ax1.fill_between([x / 1e6 for x in xs], 0, ys, step="pre", color="#1668a8", alpha=0.85)
    ax1.set_ylabel("pwm_out")
    ax1.set_ylim(-0.1, 1.3)
    ax1.set_yticks([0, 1])
    ax1.set_xlabel("time (µs)")
    ax1.grid(alpha=0.3)

    fig.savefig(os.path.join(OUT_DIR, "pwm_duty_sweep.png"), dpi=130)
    plt.close(fig)

    # Zoom: three periods at 25% duty
    fig, ax = plt.subplots(figsize=(11, 2.4), constrained_layout=True)
    xs, ys = to_steps(d["pwm"], t_end)
    ax.fill_between([x / 1e6 for x in xs], 0, ys, step="pre", color="#1668a8", alpha=0.85)
    ax.set_xlim(6.4, 9.2)
    ax.set_ylim(-0.1, 1.3)
    ax.set_yticks([0, 1])
    ax.set_xlabel("time (µs)")
    ax.set_ylabel("pwm_out")
    ax.grid(alpha=0.3)
    ax.set_title("Zoom: duty = 8/32 → 12 high ticks per 50-tick period (1 µs carrier)")
    fig.savefig(os.path.join(OUT_DIR, "pwm_zoom_25pct.png"), dpi=130)
    plt.close(fig)


def plot_quad():
    d = parse_vcd(
        "tb_quadrature_decoder.vcd",
        {"enc_a": "a", "enc_b": "b", "count": "count", "err": "err", "dir": "dir"},
    )
    t_end = max(t for sig in d.values() for t, _ in sig)

    fig, (ax0, ax1) = plt.subplots(
        2, 1, figsize=(11, 5), sharex=True,
        gridspec_kw={"height_ratios": [1, 1.2]}, constrained_layout=True,
    )

    digital_trace(ax0, d["a"], t_end, 2.4, "ENC_A", "#1668a8")
    digital_trace(ax0, d["b"], t_end, 1.2, "ENC_B", "#2e8540")
    digital_trace(ax0, d["err"], t_end, 0.0, "err", "#c02020")
    ax0.set_ylim(-0.3, 3.5)
    ax0.set_yticks([])
    ax0.grid(alpha=0.3, axis="x")
    ax0.set_title(
        "quadrature_decoder: fwd ×12, rev ×20, turnaround, glitches, bounce, illegal transition, recovery"
    )

    cnt = [(t, signed(v, 16)) for t, v in d["count"]]
    xs, ys = to_steps(cnt, t_end)
    ax1.plot([x / 1e6 for x in xs], ys, color="#c85000", lw=1.5)
    ax1.axhline(0, color="gray", lw=0.6)
    ax1.set_ylabel("count (signed)")
    ax1.set_xlabel("time (µs)")
    ax1.grid(alpha=0.3)

    fig.savefig(os.path.join(OUT_DIR, "quad_full_run.png"), dpi=130)
    plt.close(fig)

    # Zoom on the direction reversal around the forward->reverse transition
    fig, (ax0, ax1) = plt.subplots(
        2, 1, figsize=(11, 4), sharex=True, constrained_layout=True
    )
    digital_trace(ax0, d["a"], t_end, 1.2, "ENC_A", "#1668a8")
    digital_trace(ax0, d["b"], t_end, 0.0, "ENC_B", "#2e8540")
    ax0.set_ylim(-0.3, 2.3)
    ax0.set_yticks([])
    ax0.grid(alpha=0.3, axis="x")
    ax0.set_title("Zoom: direction reversal — count peaks at +12, then descends (4x: one count per edge)")
    ax1.plot([x / 1e6 for x in xs], ys, color="#c85000", lw=1.5)
    ax1.axhline(0, color="gray", lw=0.6)
    ax1.set_ylabel("count (signed)")
    ax1.set_xlabel("time (µs)")
    ax1.grid(alpha=0.3)
    ax0.set_xlim(8, 22)
    fig.savefig(os.path.join(OUT_DIR, "quad_reversal_zoom.png"), dpi=130)
    plt.close(fig)


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    plot_pwm()
    plot_quad()
    print(f"wrote PNGs to {os.path.abspath(OUT_DIR)}")
