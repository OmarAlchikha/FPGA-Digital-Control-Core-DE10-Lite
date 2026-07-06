// ============================================================================
// quadrature_decoder.v
//
// Quadrature (incremental) encoder decoder with 4x resolution.
//
// Signal path per channel:
//   pad -> 2-flop synchronizer -> glitch filter -> edge decode
//
//   * Synchronizer: encoder edges are asynchronous to clk; two flops keep
//     metastability out of the state machine.
//   * Glitch filter: the filtered value only updates after the synchronized
//     input has held a new level for DEBOUNCE_TICKS consecutive clocks.
//     This rejects contact bounce on mechanical encoders and coupled noise
//     on long motor cables. At 50 MHz, DEBOUNCE_TICKS = 50 gives a 1 us
//     filter — far above noise, far below real edge spacing for any
//     encoder below ~250k quadrature edges/s. Set to 0 to bypass the
//     filter entirely (e.g. for clean optical encoders at very high speed).
//
// Decoding is full 4x: every edge of A and every edge of B moves the count,
// so a 600 PPR encoder yields 2400 counts/rev. Direction convention:
//   A leads B  ->  count increments, dir = 1
//   B leads A  ->  count decrements, dir = 0
//
// Illegal transitions (both channels appearing to change in the same
// filtered sample — a skipped state, meaning the encoder outran the filter
// or a wire bounced) pulse `err` for one clock and leave the count
// untouched, so corruption is observable instead of silent.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module quadrature_decoder #(
    parameter integer COUNT_WIDTH    = 16,  // width of the position counter
    parameter integer DEBOUNCE_TICKS = 50   // clks a level must persist; 0 = bypass
) (
    input  wire                          clk,
    input  wire                          rst_n,   // async active-low reset
    input  wire                          enc_a,   // encoder channel A (async)
    input  wire                          enc_b,   // encoder channel B (async)
    output reg  signed [COUNT_WIDTH-1:0] count,   // signed position, 4x resolution
    output reg                           dir,     // last movement: 1 = up (A leads B)
    output reg                           step,    // 1-clk pulse per counted edge
    output reg                           err      // 1-clk pulse on illegal transition
);

    // ---------------- 2-flop synchronizers ----------------
    reg [1:0] a_sync, b_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_sync <= 2'b00;
            b_sync <= 2'b00;
        end else begin
            a_sync <= {a_sync[0], enc_a};
            b_sync <= {b_sync[0], enc_b};
        end
    end

    // ---------------- glitch / debounce filters ----------------
    wire a_filt, b_filt;

    generate
        if (DEBOUNCE_TICKS > 0) begin : g_filter
            localparam integer DB_W = $clog2(DEBOUNCE_TICKS + 1);

            reg            a_q, b_q;
            reg [DB_W-1:0] a_cnt, b_cnt;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    a_q   <= 1'b0;
                    a_cnt <= {DB_W{1'b0}};
                end else if (a_sync[1] == a_q) begin
                    a_cnt <= {DB_W{1'b0}};            // stable: rearm
                end else if (a_cnt == DEBOUNCE_TICKS - 1) begin
                    a_q   <= a_sync[1];               // persisted: accept
                    a_cnt <= {DB_W{1'b0}};
                end else begin
                    a_cnt <= a_cnt + 1'b1;
                end
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    b_q   <= 1'b0;
                    b_cnt <= {DB_W{1'b0}};
                end else if (b_sync[1] == b_q) begin
                    b_cnt <= {DB_W{1'b0}};
                end else if (b_cnt == DEBOUNCE_TICKS - 1) begin
                    b_q   <= b_sync[1];
                    b_cnt <= {DB_W{1'b0}};
                end else begin
                    b_cnt <= b_cnt + 1'b1;
                end
            end

            assign a_filt = a_q;
            assign b_filt = b_q;
        end else begin : g_nofilter
            assign a_filt = a_sync[1];
            assign b_filt = b_sync[1];
        end
    endgenerate

    // ---------------- 4x quadrature decode ----------------
    wire [1:0] curr = {a_filt, b_filt};
    reg  [1:0] prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev  <= 2'b00;
            count <= {COUNT_WIDTH{1'b0}};
            dir   <= 1'b0;
            step  <= 1'b0;
            err   <= 1'b0;
        end else begin
            prev <= curr;
            step <= 1'b0;
            err  <= 1'b0;

            case ({prev, curr})
                // A leads B: 00 -> 10 -> 11 -> 01 -> 00  (count up)
                4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: begin
                    count <= count + 1'b1;
                    dir   <= 1'b1;
                    step  <= 1'b1;
                end
                // B leads A: 00 -> 01 -> 11 -> 10 -> 00  (count down)
                4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: begin
                    count <= count - 1'b1;
                    dir   <= 1'b0;
                    step  <= 1'b1;
                end
                // Both channels changed at once: a state was skipped.
                4'b00_11, 4'b11_00, 4'b01_10, 4'b10_01: begin
                    err <= 1'b1;
                end
                default: ;  // no movement
            endcase
        end
    end

endmodule

`default_nettype wire
