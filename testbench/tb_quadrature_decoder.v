// ============================================================================
// tb_quadrature_decoder.v  —  self-checking testbench (Icarus Verilog)
//
// Drives the async encoder inputs with realistic (clock-unrelated) timing
// and keeps an independent model of the expected count. DEBOUNCE_TICKS is
// shrunk to 4 clocks so the glitch tests run fast; the quarter-cycle dwell
// (1 us = 50 clocks) is comfortably longer than the filter, as it must be
// in a correctly sized real system.
//
// Covered:
//   * 4x counting: every quadrature state change moves the count by 1
//   * direction detection, both directions, and the dir output flag
//   * direction reversal mid-cycle (turn-around between detent positions)
//   * glitch shorter than the debounce filter -> ignored, count unchanged
//   * contact bounce on a legitimate edge -> counted exactly once
//   * illegal transition (both channels change at once) -> err pulse,
//     count unchanged, decoder recovers and keeps counting afterwards
//
// Run:  iverilog -g2012 -o tb_quad ../rtl/quadrature_decoder.v tb_quadrature_decoder.v
//       vvp tb_quad
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_quadrature_decoder;

    localparam integer COUNT_WIDTH    = 16;
    localparam integer DEBOUNCE_TICKS = 4;      // 4 clks = 80 ns filter
    localparam integer QUARTER_NS     = 1000;   // dwell per quadrature state

    reg  clk = 1'b0;
    reg  rst_n;
    reg  enc_a = 1'b0, enc_b = 1'b0;
    wire signed [COUNT_WIDTH-1:0] count;
    wire dir, step, err;

    integer errors    = 0;
    integer exp_count = 0;   // independent reference model
    integer err_seen  = 0;

    quadrature_decoder #(
        .COUNT_WIDTH    (COUNT_WIDTH),
        .DEBOUNCE_TICKS (DEBOUNCE_TICKS)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .enc_a (enc_a),
        .enc_b (enc_b),
        .count (count),
        .dir   (dir),
        .step  (step),
        .err   (err)
    );

    always #10 clk = ~clk;  // 50 MHz

    always @(posedge clk) if (err) err_seen = err_seen + 1;

    // ---- encoder model: phase 0..3 -> {A,B} = 00, 10, 11, 01 (A leads B) --
    integer phase = 0;

    task apply_phase;
        begin
            enc_a = (phase == 1) || (phase == 2);
            enc_b = (phase == 2) || (phase == 3);
        end
    endtask

    task quarter_fwd;   // one quadrature edge, A-leads-B direction (count up)
        begin
            phase = (phase + 1) % 4;
            apply_phase;
            exp_count = exp_count + 1;
            #QUARTER_NS;
        end
    endtask

    task quarter_rev;   // one quadrature edge, B-leads-A direction (count down)
        begin
            phase = (phase + 3) % 4;
            apply_phase;
            exp_count = exp_count - 1;
            #QUARTER_NS;
        end
    endtask

    task check(input [8*48-1:0] label);
        begin
            #(QUARTER_NS);  // let the filter settle
            if (count !== exp_count[COUNT_WIDTH-1:0]) begin
                errors = errors + 1;
                $display("FAIL: %0s: count=%0d, expected %0d", label, count, exp_count);
            end else begin
                $display("PASS: %0s: count=%0d", label, count);
            end
        end
    endtask

    task check_dir(input expected, input [8*48-1:0] label);
        begin
            if (dir !== expected) begin
                errors = errors + 1;
                $display("FAIL: %0s: dir=%b, expected %b", label, dir, expected);
            end else begin
                $display("PASS: %0s: dir=%b", label, dir);
            end
        end
    endtask

    integer i;

    initial begin
        $dumpfile("tb_quadrature_decoder.vcd");
        $dumpvars(0, tb_quadrature_decoder);

        rst_n = 1'b0;
        apply_phase;
        #200;
        rst_n = 1'b1;
        #200;

        // --- 1. forward rotation: 12 quadrature edges = 3 full cycles ---
        for (i = 0; i < 12; i = i + 1) quarter_fwd;
        check("forward 12 edges");
        check_dir(1'b1, "dir up after forward motion");

        // --- 2. reverse rotation: past zero into negative counts --------
        for (i = 0; i < 20; i = i + 1) quarter_rev;
        check("reverse 20 edges (net -8)");
        check_dir(1'b0, "dir down after reverse motion");

        // --- 3. direction reversal mid-cycle -----------------------------
        // Advance 2 quarter-steps (half a cycle, between detents), then
        // back out: a shaft turnaround. Net displacement must be zero and
        // every edge must have been counted symmetrically.
        for (i = 0; i < 2; i = i + 1) quarter_fwd;
        check("turnaround: 2 edges in");
        for (i = 0; i < 2; i = i + 1) quarter_rev;
        check("turnaround: back to start (net 0)");

        // --- 4. glitch rejection -----------------------------------------
        // 40 ns spike on A (2 clks < 4-clk filter): must not count.
        enc_a = ~enc_a; #40; enc_a = ~enc_a;
        check("40 ns glitch on A ignored");
        // Same on B.
        enc_b = ~enc_b; #40; enc_b = ~enc_b;
        check("40 ns glitch on B ignored");

        // --- 5. contact bounce on a real edge counts exactly once --------
        // A legitimate forward edge on A, but the contact bounces for a
        // while (sub-filter pulses) before settling. Exactly one count.
        phase = (phase + 1) % 4;            // intended next state (A changes)
        exp_count = exp_count + 1;
        for (i = 0; i < 4; i = i + 1) begin
            apply_phase; #50;               // 50 ns at new level (< filter)
            enc_a = ~enc_a; #30;            // 30 ns bounce-back
        end
        apply_phase;                        // settle at the new state
        #QUARTER_NS;
        check("bouncing edge counted exactly once");

        // --- 6. illegal transition flags err, count unchanged ------------
        // Force both channels to change simultaneously (state skip). The
        // filters accept both after DEBOUNCE_TICKS on the same clock, so
        // the decoder sees a two-bit jump: err must pulse, count must hold.
        phase = (phase + 2) % 4;            // diagonal jump, e.g. 00 -> 11
        apply_phase;
        #QUARTER_NS;
        check("illegal transition leaves count unchanged");
        if (err_seen == 0) begin
            errors = errors + 1;
            $display("FAIL: illegal transition did not pulse err");
        end else begin
            $display("PASS: err pulsed on illegal transition (%0d)", err_seen);
        end

        // --- 7. decoder recovers after the error -------------------------
        for (i = 0; i < 4; i = i + 1) quarter_fwd;
        check("counting resumes correctly after err");

        // --- verdict ------------------------------------------------------
        if (errors == 0) $display("\n=== tb_quadrature_decoder: ALL TESTS PASSED ===");
        else             $display("\n=== tb_quadrature_decoder: %0d TEST(S) FAILED ===", errors);
        $finish;
    end

    // watchdog
    initial begin
        #2_000_000;
        $display("FATAL: testbench watchdog timeout");
        $finish;
    end

endmodule

`default_nettype wire
