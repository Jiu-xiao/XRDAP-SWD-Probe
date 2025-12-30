`timescale 1ns/1ps

// ============================================================
// 74xx161 (16-pin) : Synchronous 4-bit binary counter
// Pin semantics (common 74LS161/HC161-style):
//   1  CLR_n   (asynchronous clear, active low)
//   2  CLK
//   3  A (P0)  parallel data in, LSB
//   4  B (P1)
//   5  C (P2)
//   6  D (P3)  parallel data in, MSB
//   7  ENP
//   8  GND
//   9  LOAD_n  (synchronous parallel load, active low)
//   10 ENT
//   11 QD (Q3) MSB
//   12 QC (Q2)
//   13 QB (Q1)
//   14 QA (Q0) LSB
//   15 RCO
//   16 VCC
// ============================================================
module ic_74xx161 (
    input  wire pin1_CLR_n,
    input  wire pin2_CLK,
    input  wire pin3_A,
    input  wire pin4_B,
    input  wire pin5_C,
    input  wire pin6_D,
    input  wire pin7_ENP,
    input  wire pin9_LOAD_n,
    input  wire pin10_ENT,
    output wire pin11_QD,
    output wire pin12_QC,
    output wire pin13_QB,
    output wire pin14_QA,
    output wire pin15_RCO,
    input  wire pin16_VCC,
    input  wire pin8_GND
);
    reg [3:0] Q;

    always @(posedge pin2_CLK or negedge pin1_CLR_n) begin
        if (!pin1_CLR_n) begin
            Q <= 4'd0;
        end else begin
            if (!pin9_LOAD_n) begin
                Q <= {pin6_D, pin5_C, pin4_B, pin3_A};
            end else if (pin7_ENP && pin10_ENT) begin
                Q <= Q + 4'd1;
            end else begin
                Q <= Q;
            end
        end
    end

    assign pin14_QA  = Q[0];
    assign pin13_QB  = Q[1];
    assign pin12_QC  = Q[2];
    assign pin11_QD  = Q[3];
    assign pin15_RCO = pin10_ENT && (Q == 4'hF);
endmodule


// ============================================================
// 74xx00 (14-pin) : Quad 2-input NAND
// Standard 74xx00 pinout:
//   Gate1: 1A=1, 1B=2, 1Y=3
//   Gate2: 2A=4, 2B=5, 2Y=6
//   GND=7
//   Gate3: 3Y=8, 3A=9, 3B=10
//   Gate4: 4Y=11,4A=12,4B=13
//   VCC=14
// ============================================================
module ic_74xx00 (
    input  wire pin1_1A,  input  wire pin2_1B,  output wire pin3_1Y,
    input  wire pin4_2A,  input  wire pin5_2B,  output wire pin6_2Y,
    input  wire pin7_GND,
    output wire pin8_3Y,  input  wire pin9_3A,  input  wire pin10_3B,
    output wire pin11_4Y, input  wire pin12_4A, input  wire pin13_4B,
    input  wire pin14_VCC
);
    assign pin3_1Y  = ~(pin1_1A  & pin2_1B);
    assign pin6_2Y  = ~(pin4_2A  & pin5_2B);
    assign pin8_3Y  = ~(pin9_3A  & pin10_3B);
    assign pin11_4Y = ~(pin12_4A & pin13_4B);
endmodule


// ============================================================
// 74xx32 (14-pin) : Quad 2-input OR
// Standard 74xx32 pinout matches 74xx00 topology:
//   Gate1: 1A=1, 1B=2, 1Y=3
//   Gate2: 2A=4, 2B=5, 2Y=6
//   GND=7
//   Gate3: 3Y=8, 3A=9, 3B=10
//   Gate4: 4Y=11,4A=12,4B=13
//   VCC=14
// ============================================================
module ic_74xx32 (
    input  wire pin1_1A,  input  wire pin2_1B,  output wire pin3_1Y,
    input  wire pin4_2A,  input  wire pin5_2B,  output wire pin6_2Y,
    input  wire pin7_GND,
    output wire pin8_3Y,  input  wire pin9_3A,  input  wire pin10_3B,
    output wire pin11_4Y, input  wire pin12_4A, input  wire pin13_4B,
    input  wire pin14_VCC
);
    assign pin3_1Y  = (pin1_1A  | pin2_1B);
    assign pin6_2Y  = (pin4_2A  | pin5_2B);
    assign pin8_3Y  = (pin9_3A  | pin10_3B);
    assign pin11_4Y = (pin12_4A | pin13_4B);
endmodule


// ============================================================
// 74xx126 (14-pin) : Quad tri-state buffer, OE (G) active HIGH
// Common 74xx126 pinout (TI-style naming: 1G/2G/3G/4G):
//   1=1G, 2=1A, 3=1Y
//   4=2G, 5=2A, 6=2Y
//   7=GND
//   8=3Y, 9=3A, 10=3G
//   11=4Y,12=4A,13=4G
//   14=VCC
// ============================================================
module ic_74xx126 (
    input  wire pin1_1G,  input  wire pin2_1A,  output wire pin3_1Y,
    input  wire pin4_2G,  input  wire pin5_2A,  output wire pin6_2Y,
    input  wire pin7_GND,
    output wire pin8_3Y,  input  wire pin9_3A,  input  wire pin10_3G,
    output wire pin11_4Y, input  wire pin12_4A, input  wire pin13_4G,
    input  wire pin14_VCC
);
    assign pin3_1Y  = pin1_1G  ? pin2_1A  : 1'bz;
    assign pin6_2Y  = pin4_2G  ? pin5_2A  : 1'bz;
    assign pin8_3Y  = pin10_3G ? pin9_3A  : 1'bz;
    assign pin11_4Y = pin13_4G ? pin12_4A : 1'bz;
endmodule


// ============================================================
// swd_frontend_top (same external behavior as your RTL)
// Chips used:
//   U1: 74xx161  (saturate@15 via LOAD_n=~RCO, D=1111)
//   U2: 74xx00   (NAND plane: inverters + req_drive + write_drive inverter)
//   U3: 74xx32   (OR plane: q2|q1, rnw|~rco, (raw|req), final OR)
//   U4: 74xx126  (tri-state drive SWDIO)
// ============================================================
module swd_frontend_top (
    input  wire sck,
    input  wire mosi,
    output wire miso,

    input  wire rst_n,   // 0 = RAW 直通；1 = 正常帧
    input  wire rnw,     // 1 = READ, 0 = WRITE

    output wire swclk,
    inout  tri  swdio
);
    // 直连观测/时钟：现实中就是走线
    assign swclk = sck;

    // 供电脚（仿真用常量；现实中接 3.3V / GND）
    wire VCC, GND;
    assign VCC = 1'b1;
    assign GND = 1'b0;

    // ------------------------------------------------------------
    // U1: 74xx161 as saturating @15
    //   D=1111
    //   LOAD_n = ~RCO  (Q==15 时，下一拍 load 回 15，从而饱和)
    // ------------------------------------------------------------
    wire bit_idx0, bit_idx1, bit_idx2, bit_idx3; // QA..QD
    wire rco;
    wire inv_rco;

    ic_74xx161 U1_161 (
        .pin1_CLR_n (rst_n),
        .pin2_CLK   (sck),

        .pin3_A     (1'b1),
        .pin4_B     (1'b1),
        .pin5_C     (1'b1),
        .pin6_D     (1'b1),

        .pin7_ENP   (1'b1),
        .pin8_GND   (GND),
        .pin9_LOAD_n(inv_rco),
        .pin10_ENT  (1'b1),

        .pin11_QD   (bit_idx3),
        .pin12_QC   (bit_idx2),
        .pin13_QB   (bit_idx1),
        .pin14_QA   (bit_idx0),
        .pin15_RCO  (rco),
        .pin16_VCC  (VCC)
    );

    // ------------------------------------------------------------
    // 组合逻辑（全部用 U2/U3 做出来）
    // req_drive   = (bit_idx <= 9) == ~(Q3 & (Q2|Q1))
    // write_drive = (~rnw) & (bit_idx==15) == ~(rnw | ~rco)
    // swdio_drive = raw_mode | req_drive | write_drive
    // ------------------------------------------------------------
    wire or_q2_q1;
    wire or_rnw_invrco;
    wire raw_mode;
    wire req_drive;
    wire write_drive;
    wire or_raw_req;
    wire swdio_drive;

    // U3: OR plane
    ic_74xx32 U3_32 (
        .pin1_1A(bit_idx2),       .pin2_1B(bit_idx1),        .pin3_1Y(or_q2_q1),
        .pin4_2A(rnw),            .pin5_2B(inv_rco),          .pin6_2Y(or_rnw_invrco),
        .pin7_GND(GND),
        .pin8_3Y(or_raw_req),     .pin9_3A(raw_mode),         .pin10_3B(req_drive),
        .pin11_4Y(swdio_drive),   .pin12_4A(or_raw_req),      .pin13_4B(write_drive),
        .pin14_VCC(VCC)
    );

    // U2: NAND plane (含反相)
    ic_74xx00 U2_00 (
        // Gate1: inv_rco = ~rco
        .pin1_1A(rco),             .pin2_1B(rco),              .pin3_1Y(inv_rco),

        // Gate2: raw_mode = ~rst_n
        .pin4_2A(rst_n),           .pin5_2B(rst_n),            .pin6_2Y(raw_mode),

        .pin7_GND(GND),

        // Gate3: req_drive = ~(Q3 & (Q2|Q1))
        .pin8_3Y(req_drive),       .pin9_3A(bit_idx3),         .pin10_3B(or_q2_q1),

        // Gate4: write_drive = ~(rnw | inv_rco)  (把 OR2 再反相一次)
        .pin11_4Y(write_drive),    .pin12_4A(or_rnw_invrco),    .pin13_4B(or_rnw_invrco),

        .pin14_VCC(VCC)
    );

    // U4: Tri-state driver for SWDIO (只用第1路，其余关断)
    ic_74xx126 U4_126 (
        .pin1_1G(swdio_drive),     .pin2_1A(mosi),             .pin3_1Y(swdio),
        .pin4_2G(rst_n),           .pin5_2A(swdio),            .pin6_2Y(miso),
        .pin7_GND(GND),
        .pin8_3Y(),                .pin9_3A(1'b0),             .pin10_3G(1'b0),
        .pin11_4Y(),               .pin12_4A(1'b0),            .pin13_4G(1'b0),
        .pin14_VCC(VCC)
    );

endmodule
