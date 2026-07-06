// ============================================================================
// pwm_generator.v
//
// Parameterized PWM generator.
//
// Frequency and resolution are independent compile-time parameters:
//   * PWM frequency  = CLK_FREQ_HZ / PWM_FREQ_HZ clock ticks per period
//     (exact integer division; choose PWM_FREQ_HZ that divides CLK_FREQ_HZ
//     for a cycle-accurate period).
//   * Duty resolution = RESOLUTION bits. duty = 0 gives a constant-low
//     output, duty = 2^RESOLUTION - 1 gives a constant-high (true 100%)
//     output — both extremes are exact, not "almost".
//
// The duty input is double-buffered: it is sampled only at the start of a
// PWM period, so changing it mid-period can never produce a runt/glitch
// pulse. `period_start` pulses high for one clock at each period boundary;
// a control loop can use it to update `duty` synchronously with the carrier
// (the classic place to run a current/velocity loop).
//
// Sizing rule: for every duty code to map to a distinct threshold you want
//   CLK_FREQ_HZ / PWM_FREQ_HZ >= 2^RESOLUTION.
// e.g. 50 MHz clock, 20 kHz PWM -> 2500 ticks/period -> up to 11 bits.
//
// Reset behavior: after rst_n deasserts, the output stays low for one full
// period while the first threshold is latched (fail-safe for motor drives).
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module pwm_generator #(
    parameter integer CLK_FREQ_HZ = 50_000_000,  // input clock (DE10-Lite: 50 MHz)
    parameter integer PWM_FREQ_HZ = 20_000,      // PWM carrier frequency
    parameter integer RESOLUTION  = 10           // duty-cycle resolution in bits
) (
    input  wire                  clk,
    input  wire                  rst_n,         // async active-low reset
    input  wire [RESOLUTION-1:0] duty,          // 0 = 0%, 2^RESOLUTION-1 = 100%
    output reg                   pwm_out,
    output reg                   period_start   // 1-clk pulse at each period boundary
);

    localparam integer PERIOD = CLK_FREQ_HZ / PWM_FREQ_HZ; // clk ticks per PWM period
    localparam integer CNT_W  = $clog2(PERIOD);

    reg [CNT_W-1:0] counter;    // 0 .. PERIOD-1
    reg [CNT_W:0]   threshold;  // ticks the output stays high (0 .. PERIOD)

    // Map duty (0 .. 2^RES-1) onto (0 .. PERIOD). The all-ones code is
    // special-cased to the full period so 100% duty is exactly achievable;
    // every other code scales linearly: threshold = duty * PERIOD / 2^RES.
    wire [CNT_W:0] threshold_next =
        (&duty) ? PERIOD[CNT_W:0]
                : ((duty * PERIOD) >> RESOLUTION);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter      <= {CNT_W{1'b0}};
            threshold    <= {(CNT_W+1){1'b0}};   // output low until first latch
            pwm_out      <= 1'b0;
            period_start <= 1'b0;
        end else begin
            period_start <= 1'b0;

            if (counter == PERIOD - 1) begin
                counter      <= {CNT_W{1'b0}};
                threshold    <= threshold_next;  // duty latched once per period
                period_start <= 1'b1;
            end else begin
                counter <= counter + 1'b1;
            end

            // Registered compare: high while counter < threshold.
            // threshold == 0      -> never high  (true 0%)
            // threshold == PERIOD -> always high (true 100%)
            pwm_out <= ({1'b0, counter} < threshold);
        end
    end

    // Elaboration-time sanity check (simulation only; ignored by synthesis).
    initial begin
        if (PERIOD < (1 << RESOLUTION))
            $display("WARNING: pwm_generator PERIOD (%0d) < 2^RESOLUTION (%0d); duty codes will alias.",
                     PERIOD, 1 << RESOLUTION);
    end

endmodule

`default_nettype wire
