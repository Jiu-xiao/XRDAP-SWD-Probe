`timescale 1ns/1ps

module swd_frontend_top (
    // MCU / SPI 侧
    input  wire sck,      // SPI SCK, LSB first, 48-bit per transfer
    input  wire mosi,     // SPI MOSI
    output wire miso,     // SPI MISO, 回读 SWDIO

    input  wire rst_n,    // 帧级复位，低有效：每次 48bit 传输前拉低一下
    input  wire rnw,      // 1 = READ, 0 = WRITE，传输前拉好

    // SWD 侧
    output wire swclk,    // SWCLK = SCK 透传
    inout  wire swdio     // SWDIO 双向
);

    // ===========================
    // 1) SWCLK 透传
    // ===========================
    assign swclk = sck;

    // ===========================
    // 2) 4bit 计数器：0..15 循环
    //    rst_n 在每帧前清零
    // ===========================
    reg [3:0] bit_cnt;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n)
            bit_cnt <= 4'd0;
        else
            bit_cnt <= bit_cnt + 4'd1;  // 0..15 循环
    end

    // ===========================
    // 3) SWDIO 双向：推挽输出 + 总线采样
    // ===========================
    reg  swdio_out;
    reg  swdio_oe;   // 1 = 主机驱动 SWDIO, 0 = 高阻
    wire swdio_in;

    assign swdio    = swdio_oe ? swdio_out : 1'bz;
    assign swdio_in = swdio;

    // MISO 直接回读总线
    assign miso = swdio_in;

    // ===========================
    // 4) ACK 捕获移位寄存器（等效 74HC164）
    //    只在 ACK 结束前移位：bit_cnt 0..14（共 15bit）
    // ===========================
    reg [7:0] ack_shreg;
    reg       after_ack_raw;  // ACK 结束之后变 1，保持到 rst_n

    // shift 时钟 gating：after_ack_raw==0 才移位
    wire shift_en = ~after_ack_raw;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n) begin
            ack_shreg     <= 8'h00;
            after_ack_raw <= 1'b0;
        end else begin
            // 在 ACK 结束前移位：捕获 padding + REQ + TURN + ACK 共 15bit
            if (shift_en) begin
                ack_shreg <= {ack_shreg[6:0], swdio_in};
            end

            // bit_cnt == 14：ACK 的第 3 位（ACK2）刚刚移入 Q0
            if (bit_cnt == 4'd14) begin
                after_ack_raw <= 1'b1;
            end
        end
    end

    // 同步一拍的 after_ack，作为 data_phase 标志
    reg after_ack;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n)
            after_ack <= 1'b0;
        else
            after_ack <= after_ack_raw;
    end

    wire data_phase = after_ack;  // ACK 结束后一拍起都是 data_phase

    // ===========================
    // 5) 从 ack_shreg 抽 ACK 三位并判断 OK (001)
    //    时序：bit14 结束时：
    //      Q0 = bit14 = ACK2
    //      Q1 = bit13 = ACK1
    //      Q2 = bit12 = ACK0
    // ===========================
    wire ack0 = ack_shreg[2];  // LSB
    wire ack1 = ack_shreg[1];
    wire ack2 = ack_shreg[0];  // MSB

    wire ack_ok = (ack2 == 1'b0) &&
                  (ack1 == 1'b0) &&
                  (ack0 == 1'b1);  // 3'b001

    // ===========================
    // 6) 阶段划分：req_phase / data_phase
    //
    // 48bit 帧内部（tb_bit_idx）：
    //   0..2  : padding 0
    //   3..10 : REQ[7:0]
    //   11    : turnaround
    //   12..14: ACK
    //   15..  : data + parity
    //
    // 我们只用 4bit 计数器的前 14 拍：
    //   bit_cnt == tb_bit_idx[3:0]
    //   且 rst_n 在帧前清零，所以第一次 16 拍就是 0..15。
    //
    // req_phase：bit_cnt 在 [0..10] 且还没 after_ack_raw
    // ===========================
    wire in_req_window = (bit_cnt <= 4'd10);
    wire req_phase     = ~after_ack_raw && in_req_window;

    // ===========================
    // 7) SWDIO 方向控制
    //
    // 写事务 (rnw = 0)：
    //   - req_phase：一定要驱动 REQ
    //   - data_phase & ack_ok：驱动写数据 + 校验 + padding
    //
    // 读事务 (rnw = 1)：
    //   - 只在 req_phase 驱动 REQ
    //   - ACK + data 全程高阻，目标驱动
    // ===========================
    wire write_phase = data_phase && ack_ok && (rnw == 1'b0);
    wire drive_swdio = req_phase || write_phase;

    always @* begin
        swdio_out = mosi;        // 驱动时，永远把 MOSI 推到 SWDIO 上
        swdio_oe  = drive_swdio; // 由阶段和 rnw/ack_ok 决定是否开车
    end

endmodule
