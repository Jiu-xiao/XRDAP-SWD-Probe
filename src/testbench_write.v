`timescale 1ns/1ps

module testbench_write;

    // ===== SPI / MCU 侧 =====
    reg  sck  = 0;
    reg  mosi = 0;
    wire miso;

    reg  rst_n = 0;
    reg  rnw   = 0;   // 写事务

    // ===== SWD 侧 =====
    wire swclk;
    wire swdio_bus; // 连接 DUT 的 inout

    // TB 端只在 ACK 阶段驱 ACK，其他时间高阻
    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 0;
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

    // TB 内部位计数：0..47
    reg [5:0] tb_bit_idx;

    always @(posedge sck or negedge rst_n) begin
        if (!rst_n)
            tb_bit_idx <= 6'd0;
        else
            tb_bit_idx <= tb_bit_idx + 6'd1;
    end

    localparam [7:0]  REQ_BYTE  = 8'hA5;
    localparam [31:0] WR_DATA32 = 32'hA55A_3C5C;
    localparam        WR_PARITY = ~(^WR_DATA32); // odd parity

    reg [2:0] ack_bits_reg = 3'b001; // 默认 OK
    reg       ack_logged   = 1'b0;
    reg       swdio_obs;
    reg       mosi_obs;
    reg       miso_obs;

    // MOSI：padding + Request + Data + Parity
    always @(negedge sck or negedge rst_n) begin
        if (!rst_n) begin
            mosi <= 1'b0;
        end else begin
            case (tb_bit_idx)
                6'd0,
                6'd1,
                6'd2: mosi <= 1'b0; // padding 0

                // 3..10: REQ[7:0]
                6'd3: mosi <= REQ_BYTE[0];
                6'd4: mosi <= REQ_BYTE[1];
                6'd5: mosi <= REQ_BYTE[2];
                6'd6: mosi <= REQ_BYTE[3];
                6'd7: mosi <= REQ_BYTE[4];
                6'd8: mosi <= REQ_BYTE[5];
                6'd9: mosi <= REQ_BYTE[6];
                6'd10: mosi <= REQ_BYTE[7];

                // 11: Turnaround（主机松手，MOSI 无所谓）
                6'd11: mosi <= 1'b0;

                // 12..14: ACK 窗口，主机不驱 SWDIO，MOSI 无所谓
                6'd12,
                6'd13,
                6'd14: mosi <= 1'b0;

                default: begin
                    if (tb_bit_idx >= 6'd15 && tb_bit_idx < 6'd47) begin
                        // Data[31:0]，LSB first
                        mosi <= WR_DATA32[tb_bit_idx - 6'd15];
                    end else if (tb_bit_idx == 6'd47) begin
                        // Parity
                        mosi <= WR_PARITY;
                    end else begin
                        mosi <= 1'b0;
                    end
                end
            endcase
        end
    end

    // TB 端：仅在 12..14 拍驱 ACK
    always @(negedge sck or negedge rst_n) begin
        if (!rst_n) begin
            tb_swdio_en  <= 1'b0;
            tb_swdio_val <= 1'b0;
        end else begin
            case (tb_bit_idx)
                6'd12: begin
                    tb_swdio_en  <= 1'b1;
                    tb_swdio_val <= ack_bits_reg[0]; // ACK0
                end
                6'd13: begin
                    tb_swdio_en  <= 1'b1;
                    tb_swdio_val <= ack_bits_reg[1]; // ACK1
                end
                6'd14: begin
                    tb_swdio_en  <= 1'b1;
                    tb_swdio_val <= ack_bits_reg[2]; // ACK2
                end
                default: begin
                    tb_swdio_en  <= 1'b0;
                    tb_swdio_val <= 1'b0;
                end
            endcase
        end
    end

    // 波形
    initial begin
        $dumpfile("swd_write_48bit.vcd");
        $dumpvars(0, testbench_write);
    end

    // 检查：在 ACK=001 时，数据阶段前端必须开车，并且 SWDIO == MOSI
    // （这里只做简单的打印 / 观察，你可以按需要加 assert）
    always @(posedge sck) begin
        if (dut.data_phase && dut.ack_ok && (rnw == 1'b0) &&
            tb_bit_idx >= 6'd15 && tb_bit_idx <= 6'd47) begin
            if (swdio_obs !== mosi_obs) begin
                $display("WRITE MISMATCH @%0t bit_idx=%0d swdio=%b mosi=%b",
                         $time, tb_bit_idx, swdio_obs, mosi_obs);
            end
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
    begin
        rst_n        = 1'b0;
        ack_bits_reg = ack_bits;
        repeat (4) @(posedge sck);

        $display("== Frame %s start @%0t | ack=%b ==", label, $time, ack_bits);
        rst_n = 1'b1;

        repeat (48) @(posedge sck);

        rst_n = 1'b0;
        repeat (4) @(posedge sck);

        $display("== Frame %s end   @%0t ==", label, $time);
    end
    endtask

    initial begin
        // OK 写帧
        run_frame(3'b001, "WRITE_OK");

        // WAIT 场景：确认 data_phase 时前端不再写
        run_frame(3'b010, "WRITE_WAIT");

        $display("== TB finish ==");
        $finish;
    end

endmodule
