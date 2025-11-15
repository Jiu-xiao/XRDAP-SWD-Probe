`timescale 1ns/1ps

module testbench_read;

    // ===== SPI / MCU 侧 =====
    reg  sck  = 0;
    reg  mosi = 0;
    wire miso;

    reg  rst_n = 0;
    reg  rnw   = 1;   // READ 事务

    // ===== SWD 侧 =====
    wire swclk;
    wire swdio_bus;

    // 目标端三态驱动
    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 1;
    assign swdio_bus = tb_swdio_en ? tb_swdio_val : 1'bz;

    // DUT
    swd_frontend_top dut (
        .sck   (sck),
        .mosi  (mosi),
        .miso  (miso),
        .rst_n (rst_n),
        .rnw   (rnw),
        .swclk (swclk),
        .swdio (swdio_bus)
    );

    // 100MHz SCK
    always #5 sck = ~sck;

    // 位索引：0..47
    reg [5:0] tb_bit_idx;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n)
            tb_bit_idx <= 6'd0;
        else
            tb_bit_idx <= tb_bit_idx + 6'd1;
    end

    localparam [7:0]  REQ_BYTE  = 8'hA5;
    localparam [31:0] RD_DATA32 = 32'h1234_5678;
    localparam        RD_PARITY = ~(^RD_DATA32); // odd parity

    reg [2:0] ack_bits_reg = 3'b001; // 默认 ACK = OK
    reg       ack_logged   = 1'b0;
    reg       swdio_obs;
    reg       mosi_obs;
    reg       miso_obs;

    // MOSI：padding + Request，其他随便
    always @(negedge sck or negedge rst_n) begin
        if (!rst_n) begin
            mosi <= 1'b0;
        end else begin
            case (tb_bit_idx)
                6'd0,
                6'd1,
                6'd2: mosi <= 1'b0;          // 前三位 padding 0
                6'd3: mosi <= REQ_BYTE[0];   // REQ[0]
                6'd4: mosi <= REQ_BYTE[1];
                6'd5: mosi <= REQ_BYTE[2];
                6'd6: mosi <= REQ_BYTE[3];
                6'd7: mosi <= REQ_BYTE[4];
                6'd8: mosi <= REQ_BYTE[5];
                6'd9: mosi <= REQ_BYTE[6];
                6'd10: mosi <= REQ_BYTE[7];  // REQ[7]
                default: mosi <= 1'b1;       // 其他阶段 MOSI 可随意
            endcase
        end
    end

    // SWDIO（目标端）驱动：ACK + 读数据 + parity
    always @(negedge sck or negedge rst_n) begin
        if (!rst_n) begin
            tb_swdio_en  <= 1'b0;
            tb_swdio_val <= 1'b1;
        end else begin
            // ACK：12..14
            if (tb_bit_idx == 6'd12) begin
                tb_swdio_en  <= 1'b1;
                tb_swdio_val <= ack_bits_reg[0]; // ACK0
            end else if (tb_bit_idx == 6'd13) begin
                tb_swdio_en  <= 1'b1;
                tb_swdio_val <= ack_bits_reg[1]; // ACK1
            end else if (tb_bit_idx == 6'd14) begin
                tb_swdio_en  <= 1'b1;
                tb_swdio_val <= ack_bits_reg[2]; // ACK2
            end
            // Data：15..46（只有 ACK=001 时输出）
            else if ((ack_bits_reg == 3'b001) &&
                     (tb_bit_idx >= 6'd15) && (tb_bit_idx < 6'd47)) begin
                tb_swdio_en  <= 1'b1;
                tb_swdio_val <= RD_DATA32[tb_bit_idx - 6'd15];
            end
            // Parity：47
            else if ((ack_bits_reg == 3'b001) && (tb_bit_idx == 6'd47)) begin
                tb_swdio_en  <= 1'b1;
                tb_swdio_val <= RD_PARITY;
            end
            // 其他：释放总线
            else begin
                tb_swdio_en  <= 1'b0;
                tb_swdio_val <= 1'b1;
            end
        end
    end

    // 波形
    initial begin
        $dumpfile("swd_read_48bit.vcd");
        $dumpvars(0, testbench_read);
    end

    // 捕获读回数据（14..45）
    reg [31:0] miso_capture;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n) begin
            miso_capture <= 32'd0;
        end else if (dut.after_ack && dut.ack_ok &&
                     tb_bit_idx >= 6'd15 && tb_bit_idx < 6'd47) begin
            miso_capture[tb_bit_idx - 6'd15] <= miso;
        end
    end

    always @(negedge sck or negedge rst_n) begin
        if (!rst_n) begin
            swdio_obs <= 1'bz;
            mosi_obs  <= 1'b0;
            miso_obs  <= 1'b0;
        end else begin
            swdio_obs <= swdio_bus;
            mosi_obs  <= mosi;
            miso_obs  <= miso;
        end
    end

    task automatic log_state(input string tag);
    begin
        $display("[LOG %s] @%0t bit=%0d data_phase=%0b ack_ok=%0b swdio=%b mosi=%b miso=%b",
                 tag, $time, tb_bit_idx, dut.data_phase, dut.ack_ok, swdio_obs, mosi_obs, miso_obs);
    end
    endtask

    always @(posedge sck or negedge rst_n) begin
        string evt;
        if (!rst_n) begin
            ack_logged <= 1'b0;
        end else begin
            case (tb_bit_idx)
                6'd0:  log_state("FRAME_PAD");
                6'd3:  log_state("REQ_START");
                6'd11: log_state("TURNAROUND");
                6'd12: log_state("ACK_WINDOW");
                6'd15: log_state("DATA_START");
                6'd47: log_state("PARITY_BIT");
                default: ;
            endcase

            if (!ack_logged && dut.after_ack) begin
                ack_logged <= 1'b1;
                evt = $sformatf("ACK_DONE TB=%03b DUT=%03b",
                                ack_bits_reg,
                                {dut.ack_shreg[0], dut.ack_shreg[1], dut.ack_shreg[2]});
                log_state(evt);
            end
        end
    end

    task automatic run_frame(
        input [2:0] ack_bits,
        input string label
    );
        reg [31:0] captured;
    begin
        // 帧前复位
        rst_n       = 1'b0;
        ack_bits_reg = ack_bits;
        repeat (4) @(posedge sck);  // 保证清干净

        // 开始一帧
        $display("== Frame %s start @%0t | ack=%b ==", label, $time, ack_bits);
        rst_n = 1'b1;

        // 48bit SPI 传输
        repeat (48) @(posedge sck);

        captured = miso_capture;

        // 帧结束，拉低复位
        rst_n = 1'b0;
        repeat (4) @(posedge sck);

        if (ack_bits == 3'b001) begin
            if (captured !== RD_DATA32) begin
                $error("READ data mismatch expected 0x%08h got 0x%08h",
                       RD_DATA32, captured);
                $fatal;
            end else begin
                $display("READ data OK: 0x%08h", captured);
            end
        end else begin
            $display("READ frame with ACK=%b, captured=0x%08h", ack_bits, captured);
        end

        $display("== Frame %s end   @%0t ==", label, $time);
    end
    endtask

    initial begin
        run_frame(3'b001, "READ_OK");
        run_frame(3'b010, "READ_WAIT");
        $display("== TB finish ==");
        $finish;
    end

endmodule
