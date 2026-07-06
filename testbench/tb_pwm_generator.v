// ============================================================================
// tb_pwm_generator.v  —  self-checking testbench (Icarus Verilog)
//
// Strategy: parameterize the DUT down to a short period (50 clocks) so each
// test runs in microseconds of sim time, then *measure* the output instead
// of trusting it — for each commanded duty, count how many of the PERIOD
// clock cycles the output is high and compare against the independently
// computed expectation.
//
// Covered:
//   * duty extremes: 0% (must be stuck low) and 100% (must be stuck high)
//   * minimum nonzero duty (single-tick pulse survives)
//   * mid-scale duties (linearity of the duty->threshold scaling)
//   * period length is exactly CLK_FREQ_HZ / PWM_FREQ_HZ clocks
//   * double-buffering: a duty change mid-period must NOT affect the
//     period in flight (no glitch), only the next one
//
// Run:  iverilog -g2012 -o tb_pwm ../rtl/pwm_generator.v tb_pwm_generator.v
//       vvp tb_pwm
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_pwm_generator;

    // Small, fast configuration: 50 MHz clock, 1 MHz PWM -> PERIOD = 50
    localparam integer CLK_FREQ_HZ = 50_000_000;
    localparam integer PWM_FREQ_HZ = 1_000_000;
    localparam integer RESOLUTION  = 5;                        // 32 duty codes
    localparam integer PERIOD      = CLK_FREQ_HZ / PWM_FREQ_HZ; // 50
    localparam integer DUTY_MAX    = (1 << RESOLUTION) - 1;     // 31

    reg                   clk = 1'b0;
    reg                   rst_n;
    reg  [RESOLUTION-1:0] duty;
    wire                  pwm_out;
    wire                  period_start;

    integer errors = 0;

    pwm_generator #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .PWM_FREQ_HZ (PWM_FREQ_HZ),
        .RESOLUTION  (RESOLUTION)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .duty         (duty),
        .pwm_out      (pwm_out),
        .period_start (period_start)
    );

    always #10 clk = ~clk;  // 50 MHz

    // Expected high-ticks for a duty code (mirrors the spec, not the RTL
    // expression order: full-scale is exact 100%, otherwise linear scaling).
    function integer expected_high(input integer d);
        begin
            if (d == DUTY_MAX) expected_high = PERIOD;
            else               expected_high = (d * PERIOD) >> RESOLUTION;
        end
    endfunction

    // Wait for a period boundary, then sample pwm_out for exactly PERIOD
    // clocks and return the number of high cycles.
    task measure_one_period(output integer high_ticks);
        integer i;
        begin
            @(posedge clk); while (!period_start) @(posedge clk);
            high_ticks = 0;
            for (i = 0; i < PERIOD; i = i + 1) begin
                @(posedge clk);
                if (pwm_out) high_ticks = high_ticks + 1;
            end
        end
    endtask

    task check_duty(input integer d);
        integer got, exp;
        begin
            duty = d[RESOLUTION-1:0];
            // let the new duty latch at a boundary, then measure a full
            // period that started after the latch
            @(posedge clk); while (!period_start) @(posedge clk);
            measure_one_period(got);
            exp = expected_high(d);
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL: duty=%0d -> %0d high ticks, expected %0d", d, got, exp);
            end else begin
                $display("PASS: duty=%0d/%0d -> %0d/%0d high ticks (%0d%%)",
                         d, DUTY_MAX, got, PERIOD, (got * 100) / PERIOD);
            end
        end
    endtask

    integer i, got, ticks;

    initial begin
        $dumpfile("tb_pwm_generator.vcd");
        $dumpvars(0, tb_pwm_generator);

        duty  = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        // --- extremes and mid-scale sweep -----------------------------
        check_duty(0);              // 0%: output must never go high
        check_duty(1);              // minimum pulse: 1*50>>5 = 1 tick
        check_duty(8);              // 25%
        check_duty(16);             // 50%
        check_duty(24);             // 75%
        check_duty(DUTY_MAX);       // 100%: output must never go low

        // --- 0% really is DC low over several periods ------------------
        duty = 0;
        @(posedge clk); while (!period_start) @(posedge clk);
        ticks = 0;
        for (i = 0; i < 3 * PERIOD; i = i + 1) begin
            @(posedge clk);
            if (pwm_out) ticks = ticks + 1;
        end
        if (ticks !== 0) begin
            errors = errors + 1;
            $display("FAIL: duty=0 produced %0d high ticks over 3 periods", ticks);
        end else $display("PASS: duty=0 held low for 3 full periods");

        // --- 100% really is DC high over several periods ---------------
        duty = DUTY_MAX;
        @(posedge clk); while (!period_start) @(posedge clk); // latch
        @(posedge clk); while (!period_start) @(posedge clk); // full period in effect
        ticks = 0;
        for (i = 0; i < 3 * PERIOD; i = i + 1) begin
            @(posedge clk);
            if (pwm_out) ticks = ticks + 1;
        end
        if (ticks !== 3 * PERIOD) begin
            errors = errors + 1;
            $display("FAIL: duty=max produced %0d/%0d high ticks over 3 periods",
                     ticks, 3 * PERIOD);
        end else $display("PASS: duty=max held high for 3 full periods");

        // --- period length: distance between period_start pulses -------
        duty = 16;
        @(posedge clk); while (!period_start) @(posedge clk);
        ticks = 0;
        @(posedge clk);
        while (!period_start) begin ticks = ticks + 1; @(posedge clk); end
        ticks = ticks + 1;
        if (ticks !== PERIOD) begin
            errors = errors + 1;
            $display("FAIL: period measured %0d clocks, expected %0d", ticks, PERIOD);
        end else $display("PASS: period is exactly %0d clocks", ticks);

        // --- double-buffering: mid-period duty change must not glitch ---
        duty = 8;                                        // 25% latched
        @(posedge clk); while (!period_start) @(posedge clk);
        @(posedge clk); while (!period_start) @(posedge clk);
        // now inside a fresh 25% period: slam duty to max mid-period
        got = 0;
        for (i = 0; i < PERIOD; i = i + 1) begin
            @(posedge clk);
            if (i == PERIOD / 2) duty = DUTY_MAX;
            if (pwm_out) got = got + 1;
        end
        if (got !== expected_high(8)) begin
            errors = errors + 1;
            $display("FAIL: mid-period duty change altered live period (%0d high ticks, expected %0d)",
                     got, expected_high(8));
        end else $display("PASS: mid-period duty change deferred to next period (glitch-free)");
        measure_one_period(got);                         // next period: new duty
        if (got !== PERIOD) begin
            errors = errors + 1;
            $display("FAIL: new duty not applied on next period (%0d high ticks)", got);
        end else $display("PASS: new duty took effect on the following period");

        // --- verdict ----------------------------------------------------
        if (errors == 0) $display("\n=== tb_pwm_generator: ALL TESTS PASSED ===");
        else             $display("\n=== tb_pwm_generator: %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    // watchdog
    initial begin
        #1_000_000;
        $display("FATAL: testbench watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
