`timescale 1ns/1ps
// ============================================================================
// XRDAP-SWD-Probe frontend (8-chip discrete)
// Chips (TOTAL = 8):
//   74HC163×1 / 74HC164×1 / 74HC125×1 / 74HC138×1 / 74HC20×1 / 74HC10×1 / 74HC04×1 / 74HC00×1
// No extra FFs / No RC. SWCLK pass-through; rst_n=0 → RAW 直通。
// Timing (posedge sck sample):
//   0..1   : host PAD=0
//   2..9   : host REQ (LSB-first)
//   10     : TURN#1 (host Hi-Z)
//   11..13 : target ACK[2:0] (LSB-first)
//   14     : TURN#2（READ: 目标开始驱动；WRITE: 可保持 Z；有效写数据从 15 开始）
//   ≥15    : READ : target DATA[31:0] at 14..45, PARITY at 46
//            WRITE: host   DATA[31:0] at 15..46 (ACK=001), PARITY at 47
// Note: behavioral HC* primitives use ~1 ps inertial delay (`HC_TPD`) to break zero-delay loops
//       and to stabilize tri-state release in simulation (不影响 2 ns 位周期采样).
// ============================================================================

module swd_frontend_top (
    input  wire sck,
    input  wire mosi,
    output wire miso,

    input  wire rst_n,   // 0 = RAW 直通；1 = 正常帧
    input  wire rnw,     // 1 = READ, 0 = WRITE

    output wire swclk,
    inout  tri  swdio
);
    // 0) SWCLK 透传；MISO 直接读 SWDIO
    assign swclk = sck;
    assign miso  = swdio;
    wire   swdio_in = swdio;

    // 1) 位计数（74HC163）—— 到 pre=15 冻结
    wire [3:0] bit_cnt;
    wire       count_en;           // = y7_n  (pre=15 时拉低，停止计数)
    hc163 u_cnt (.clk(sck), .clr_n(rst_n), .en(count_en), .q(bit_cnt));

    // 2) 译码“前一拍”位置（74HC138，低有效）：g1=bit_cnt[3] → 译出 pre=8..15
    wire y0_n, y1_n, y2_n, y3_n, y4_n, y5_n, y6_n, y7_n;
    hc138 u_dec (
        .a2(bit_cnt[2]), .a1(bit_cnt[1]), .a0(bit_cnt[0]),
        .g1(bit_cnt[3]), .g2a_n(1'b0), .g2b_n(1'b0),
        .y0_n(y0_n), .y1_n(y1_n), .y2_n(y2_n), .y3_n(y3_n),
        .y4_n(y4_n), .y5_n(y5_n), .y6_n(y6_n), .y7_n(y7_n)
    );
    assign count_en = y7_n;      // pre=15 → y7_n=0 → 冻结

    // 2.1) 便捷信号（观察用，不计片）
    // ack_phase：pre10..13 为 1（方便 TB 打点）
    wire ack_phase = ~(y2_n & y3_n & y4_n & y5_n);

    // hold15 = ~count_en：进入 pre=15 及其后维持为 1
    wire hold15; hc04_inv u_inv_cnten (.a(count_en), .y(hold15)); // [HC04#1]

    // 3) ACK 捕获（74HC164）—— 仅在 ACK 三拍门控时钟（pre=13..15）
    wire ack_shift_phase;  // = 1 @ pre{13..15}
    // 用 74HC20 的第 1 路：ack_shift_phase = ~(y5_n & y6_n & y7_n & 1)
    hc20_nand4 u_ackwin_n4 (.a(y5_n), .b(y6_n), .c(y7_n), .d(1'b1), .y(ack_shift_phase));

    tri  shift_clk;
    // ack_shift_phase=1 → 传 sck；=0 → 传 0   （74HC125 两路“或线”）
    hc125 u_shclk_a (.a(sck),  .oe_n(~ack_shift_phase), .y(shift_clk));
    hc125 u_shclk_b (.a(1'b0), .oe_n( ack_shift_phase), .y(shift_clk));

    wire [7:0] ack_shreg;
    hc164 u_ack_shift (.clk(shift_clk), .clr_n(rst_n), .d_in(swdio_in), .q(ack_shreg));
    // pre=15 的最后一次移位后：ack2→Q0, ack1→Q1, ack0→Q2
    wire ack2 = ack_shreg[0];
    wire ack1 = ack_shreg[1];
    wire ack0 = ack_shreg[2];

    // 4) ACK=001 判定（用 74HC10 合并为单个 3 输入 NAND，再取反得到 ack_ok）
    // ack_ok = (~ack2 & ~ack1 & ack0)
    wire n_ack2, n_ack1;
    hc04_inv u_inv_a2   (.a(ack2),    .y(n_ack2));     // [HC04#2]
    hc04_inv u_inv_a1   (.a(ack1),    .y(n_ack1));     // [HC04#3]
    wire ack_ok_n;  // = ~(~ack2 & ~ack1 & ack0)
    hc10_nand3 u_ack001 (.a(n_ack2), .b(n_ack1), .c(ack0), .y(ack_ok_n)); // [HC10#1]
    wire ack_ok;
    hc04_inv  u_inv_ack (.a(ack_ok_n), .y(ack_ok));    // [HC04#4]

    // 4.1) 粘滞保持（SR-Latch，74HC00 占 2 门）
    // 低有效置位：ack_set_n = ~(ack_ok & hold15 & sck)（用 74HC10）
    wire ack_set_n;
    hc10_nand3 u_ackset (.a(ack_ok), .b(hold15), .c(sck), .y(ack_set_n)); // [HC10#2]
    // SR：Q=ack_ok_hold；复位仅在 rst_n=0 时
    wire ack_ok_hold, ack_ok_hold_n;          // [HC00#1,#2]
    hc00_nand u_sr_q  (.a(ack_set_n), .b(ack_ok_hold_n), .y(ack_ok_hold));
    hc00_nand u_sr_nq (.a(rst_n),     .b(ack_ok_hold),   .y(ack_ok_hold_n));

    // 5) Host header 驱动区（0..11 开驱；12..14 关闭）
    // HEADER = ~( q3 & q2 ) （74HC00 占 1 门）
    wire HEADER;   hc00_nand u_HEADER (.a(bit_cnt[3]), .b(bit_cnt[2]), .y(HEADER));   // [HC00#3]
    // nHEADER = ~HEADER （用 74HC00 的自返）
    wire nHEADER;  hc00_nand u_nHEADER (.a(HEADER), .b(HEADER), .y(nHEADER));         // [HC00#4]

    // 6) WRITE 驱动条件（ACK=001 且 rnw=0 且 bit>=15），使用粘滞后的 ack_ok_hold
    wire n_rnw; hc04_inv u_inv_rnw (.a(rnw), .y(n_rnw));     // [HC04#5]
    // wr_drive_n = ~(~rnw & ack_ok_hold & hold15) （74HC10）
    wire wr_drive_n;
    hc10_nand3 u_wrdrv (.a(n_rnw), .b(ack_ok_hold), .c(hold15), .y(wr_drive_n)); // [HC10#3]

    // 7) 最终主机是否驱动：
    // host_drv_on = (~rst_n) | HEADER | (~wr_drive_n)
    // 等价 NAND4：host_drv = ~( rst_n & nHEADER & wr_drive_n & 1 )
    // 用 74HC20 的第 2 路
    wire host_drv;
    hc20_nand4 u_hostdrv_n4 (.a(rst_n), .b(nHEADER), .c(wr_drive_n), .d(1'b1), .y(host_drv));

    // 8) MOSI -> SWDIO（三态输出，RAW=直通；READ=Z；WRITE&OK&>=15=驱动）
    // 74HC125 的 oe_n 为低有效，需要再取反一次（这是第 6 路反相器）
    wire swdio_oe_n;
    hc04_inv u_inv_oen (.a(host_drv), .y(swdio_oe_n));        // [HC04#6]
    // 兼容 TB 旧名（低有效，0=驱动）
    wire swdio_oe_n_fix; assign swdio_oe_n_fix = swdio_oe_n;

    hc125 u_drv (.a(mosi), .oe_n(swdio_oe_n), .y(swdio));
endmodule

// ============================================================================
// 74HC primitives (behavioral) —— 按器件颗粒度统计：
// HC00(4×NAND2)=4 门已满；HC04(6×INV)=6 门已满；HC10(3×NAND3)=3 门已满；HC20(2×NAND4)=2 门已满
// ============================================================================
// ====== 全局仿真延迟开关（单位是 `timescale 1ns/1ps` 下的 ns）======
`ifndef HC_TPD
`define HC_TPD 0.001   // 1 ps：打破零延迟环；释放 Z 也带 1 ps 惯性，避免总线瞬时抖 x
`endif

// 2 输入 NAND（74HC00）
module hc00_nand (input a, input b, output y);
    assign #`HC_TPD y = ~(a & b);
endmodule

// 反相器（74HC04）
module hc04_inv  (input a, output y);
    assign #`HC_TPD y = ~a;
endmodule

// 3 输入 NAND（74HC10）
module hc10_nand3(input a, input b, input c, output y);
    assign #`HC_TPD y = ~(a & b & c);
endmodule

// 4 输入 NAND（74HC20）
module hc20_nand4(input a, input b, input c, input d, output y);
    assign #`HC_TPD y = ~(a & b & c & d);
endmodule

// 三态缓冲（74HC125）
module hc125 (input a, input oe_n, inout y);
    // 对 Z 的释放同样施加 1 ps 惯性延迟，避免总线瞬时 X
    assign #`HC_TPD y = (oe_n===1'b0) ? a : 1'bz;
endmodule

// 3-to-8 译码（74HC138）——各输出各自加轻微延迟
module hc138 (
    input  wire a2, a1, a0, input wire g1, input wire g2a_n, g2b_n,
    output wire y0_n, y1_n, y2_n, y3_n, y4_n, y5_n, y6_n, y7_n
);
    wire en = g1 & ~g2a_n & ~g2b_n;
    assign #`HC_TPD y0_n = ~(en & ~a2 & ~a1 & ~a0);
    assign #`HC_TPD y1_n = ~(en & ~a2 & ~a1 &  a0);
    assign #`HC_TPD y2_n = ~(en & ~a2 &  a1 & ~a0);
    assign #`HC_TPD y3_n = ~(en & ~a2 &  a1 &  a0);
    assign #`HC_TPD y4_n = ~(en &  a2 & ~a1 & ~a0);
    assign #`HC_TPD y5_n = ~(en &  a2 & ~a1 &  a0);
    assign #`HC_TPD y6_n = ~(en &  a2 &  a1 & ~a0);
    assign #`HC_TPD y7_n = ~(en &  a2 &  a1 &  a0);
endmodule

// 同步计数器（74HC163）——时钟到 Q 加 1 ps（仅为仿真稳定，不影响位边界）
module hc163 (input wire clk, input wire clr_n, input wire en, output wire [3:0] q);
    reg [3:0] cnt;
    always @(posedge clk or negedge clr_n) begin
        if (!clr_n)       cnt <= #`HC_TPD 4'd0;
        else if (en)      cnt <= #`HC_TPD (cnt + 4'd1);
        // 未使能保持原值
    end
    assign q = cnt;
endmodule

// 串入并出移位寄存器（74HC164）——clk→Q 加 1 ps
module hc164 (input wire clk, input wire clr_n, input wire d_in, output wire [7:0] q);
    reg [7:0] sh;
    always @(posedge clk or negedge clr_n) begin
        if (!clr_n) sh <= #`HC_TPD 8'h00;
        else        sh <= #`HC_TPD {sh[6:0], d_in};
    end
    assign q = sh;
endmodule
