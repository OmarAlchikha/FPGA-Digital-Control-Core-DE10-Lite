// ============================================================================
// top_de10_lite.v
//
// Board-level wrapper for the DE10-Lite (MAX 10 10M50DAF484C7G).
// Instantiates the PWM generator and the quadrature decoder so both can be
// exercised on real hardware with nothing but the board, an encoder, and a
// scope:
//
//   SW[9:0]   -> 10-bit PWM duty command (all up = 100%, all down = 0%)
//   KEY[0]    -> active-low reset
//   KEY[1]    -> motor direction output (pressed = reverse), routed to
//                MOTOR_DIR for an H-bridge DIR pin
//   ENC_A/B   -> quadrature encoder inputs (GPIO header pins 1 and 2,
//                weak pull-ups enabled in the .qsf for open-collector
//                encoders)
//   PWM_OUT   -> 20 kHz PWM (GPIO header pin 3) — probe with a scope
//   LEDR[9:0] -> live view of the low 10 bits of the encoder count
//
// The PWM carrier is 20 kHz with 10-bit resolution (2500 clocks/period at
// 50 MHz, so all 1024 duty codes are distinct). The decoder's 1 us glitch
// filter suits mechanical and motor-mounted encoders alike.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module top_de10_lite (
    input  wire       MAX10_CLK1_50,  // 50 MHz board oscillator
    input  wire [1:0] KEY,            // push buttons, active low
    input  wire [9:0] SW,             // slide switches
    output wire [9:0] LEDR,           // red LEDs

    input  wire       ENC_A,          // encoder channel A, GPIO header pin 1
    input  wire       ENC_B,          // encoder channel B, GPIO header pin 2
    output wire       PWM_OUT,        // PWM output,        GPIO header pin 3
    output wire       MOTOR_DIR       // direction output,  GPIO header pin 4
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[0];

    // ------------------------------------------------------------------
    // PWM: 50 MHz / 20 kHz = 2500 ticks/period, 10-bit duty from switches
    // ------------------------------------------------------------------
    pwm_generator #(
        .CLK_FREQ_HZ (50_000_000),
        .PWM_FREQ_HZ (20_000),
        .RESOLUTION  (10)
    ) u_pwm (
        .clk          (clk),
        .rst_n        (rst_n),
        .duty         (SW),
        .pwm_out      (PWM_OUT),
        .period_start ()             // unused here; hook a control loop later
    );

    assign MOTOR_DIR = ~KEY[1];      // hold KEY1 to reverse

    // ------------------------------------------------------------------
    // Encoder: 16-bit signed count, 1 us glitch filter at 50 MHz
    // ------------------------------------------------------------------
    wire signed [15:0] enc_count;

    quadrature_decoder #(
        .COUNT_WIDTH    (16),
        .DEBOUNCE_TICKS (50)
    ) u_quad (
        .clk   (clk),
        .rst_n (rst_n),
        .enc_a (ENC_A),
        .enc_b (ENC_B),
        .count (enc_count),
        .dir   (),
        .step  (),
        .err   ()
    );

    assign LEDR = enc_count[9:0];

endmodule

`default_nettype wire
