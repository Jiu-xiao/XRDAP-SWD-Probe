`timescale 1ns/1ps

module testbench_special;

    // ===== SPI / MCU side =====
    reg  sck  = 0;
    reg  mosi = 0;
    wire miso;

    reg  rst_n = 0;
    reg  rnw   = 0;   // 写事务为主，必要时切换

    // ===== SWD bus =====
    wire swclk;
    wire swdio_bus;

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

    // tb_bit_idx：仅在 rst_n=1 时计数
    reg [5:0] tb_bit_idx;
    always @(posedge sck or negedge rst_n) begin
        if (!rst_n)
            tb_bit_idx <= 6'd0;
        else
            tb_bit_idx <= tb_bit_idx + 6'd1;
    end

    // ===== 帧内容配置 =====
    localparam [7:0]  REQ_ABORT   = 8'hA1;        // LSB first: Start|DP|WRITE|A[3:2]=00|parity|Stop|Park
    localparam [31:0] ABORT_DATA  = 32'h0000_001E; // 清 sticky error 的典型写入
    localparam [31:0] DUMMY_DATA  = 32'hDEAD_BEEF;

    reg [7:0]  cur_req       = REQ_ABORT;
    reg [31:0] cur_wr_data   = ABORT_DATA;
    reg        cur_wr_parity = ~(^ABORT_DATA); // odd parity，LSB first
    reg [2:0]  ack_bits_reg  = 3'b001;

    // ===== Raw / dummy 帧控制 =====
    reg        raw_mode   = 1'b0;
    reg [63:0] raw_pattern;
    integer    raw_len    = 0;
    integer    raw_idx    = 0;

    // ===== 观测 =====
    reg swdio_obs;
    reg mosi_obs;
    reg miso_obs;

    reg check_drive;
    reg check_release;

    // MOSI 行为：raw 模式优先，其次正常 SWD 帧
    always @(negedge sck) begin
        if (raw_mode) begin
            if (raw_idx < raw_len)
                mosi <= raw_pattern[raw_idx];
            else
                mosi <= 1'b0;
        end else if (!rst_n) begin
            mosi <= 1'b0;
        end else begin
            case (tb_bit_idx)
                6'd0,
                6'd1,
                6'd2: mosi <= 1'b0; // padding 0

                // 3..10: REQ[7:0]，LSB first
                6'd3:  mosi <= cur_req[0];
                6'd4:  mosi <= cur_req[1];
                6'd5:  mosi <= cur_req[2];
                6'd6:  mosi <= cur_req[3];
                6'd7:  mosi <= cur_req[4];
                6'd8:  mosi <= cur_req[5];
                6'd9:  mosi <= cur_req[6];
                6'd10: mosi <= cur_req[7];

                // 11: turnaround，占位 0
                6'd11: mosi <= 1'b0;

                // 12..14: ACK 窗口，主机保持 0（DUT 会松手）
                6'd12,
                6'd13,
                6'd14: mosi <= 1'b0;

                default: begin
                    if (tb_bit_idx >= 6'd15 && tb_bit_idx < 6'd47) begin
                        mosi <= cur_wr_data[tb_bit_idx - 6'd15]; // Data[31:0]，LSB first
                    end else if (tb_bit_idx == 6'd47) begin
                        mosi <= cur_wr_parity; // Parity
                    end else begin
                        mosi <= 1'b0;
                    end
                end
            endcase
        end
    end

    // raw_idx：仅在 raw_mode 下计数
    always @(posedge sck) begin
        if (raw_mode) begin
            if (raw_idx < raw_len)
                raw_idx <= raw_idx + 1;
        end else begin
            raw_idx <= 0;
        end
    end

    // 目标侧 ACK：raw 模式或复位期保持高阻
    always @(negedge sck or negedge rst_n) begin
        if (!rst_n || raw_mode) begin
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

    // 观测探针
    always @(negedge sck) begin
        swdio_obs <= swdio_bus;
        mosi_obs  <= mosi;
        miso_obs  <= miso;
    end

    // raw 模式：逐拍确认 SWDIO == MOSI
    always @(posedge sck) begin
        if (raw_mode && raw_idx > 0 && raw_idx <= raw_len) begin
            if (swdio_obs !== mosi_obs) begin
                $error("RAW frame mismatch @%0t idx=%0d swdio=%b mosi=%b",
                       $time, raw_idx-1, swdio_obs, mosi_obs);
            end
        end
    end

    // 写数据驱动 / WAIT/FAULT 释放检测
    always @(posedge sck or negedge rst_n) begin
        if (!rst_n) begin
            check_drive   <= 1'b0;
            check_release <= 1'b0;
        end else begin
            if (check_drive && dut.data_phase && dut.ack_ok &&
                (rnw == 1'b0) && tb_bit_idx >= 6'd15 && tb_bit_idx <= 6'd47) begin
                if (swdio_obs !== mosi_obs) begin
                    $error("WRITE drive mismatch @%0t bit=%0d swdio=%b mosi=%b",
                           $time, tb_bit_idx, swdio_obs, mosi_obs);
                end
            end

            if (check_release && dut.after_ack &&
                tb_bit_idx >= 6'd15 && tb_bit_idx <= 6'd47) begin
                if (swdio_obs !== 1'bz) begin
                    $error("Expected high-Z after WAIT/FAULT @%0t bit=%0d swdio=%b",
                           $time, tb_bit_idx, swdio_obs);
                end
            end
        end
    end

    // Logging
    reg ack_logged;
    task automatic log_state(input string tag);
    begin
        $display("[LOG %s] @%0t bit=%0d raw=%0b data_phase=%0b ack_ok=%0b swdio=%b mosi=%b miso=%b",
                 tag, $time, tb_bit_idx, raw_mode, dut.data_phase, dut.ack_ok,
                 swdio_obs, mosi_obs, miso_obs);
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

    // ====== helper tasks ======
    task automatic run_write_frame(
        input [7:0]  req_byte,
        input [31:0] wr_data,
        input [2:0]  ack_bits,
        input string label,
        input bit    expect_drive_after_ack,
        input bit    expect_release_after_ack
    );
        integer i;
    begin
        cur_req       = req_byte;
        cur_wr_data   = wr_data;
        cur_wr_parity = ~(^wr_data);
        ack_bits_reg  = ack_bits;
        rnw           = 1'b0;

        rst_n = 1'b0;
        repeat (4) @(posedge sck);

        $display("== Frame %s start @%0t | REQ=0x%02h ACK=%03b DATA=0x%08h ==",
                 label, $time, req_byte, ack_bits, wr_data);
        rst_n = 1'b1;

        @(posedge sck); // bit 0
        check_drive   = expect_drive_after_ack;
        check_release = expect_release_after_ack;

        for (i = 0; i < 47; i = i + 1)
            @(posedge sck);

        rst_n = 1'b0;
        check_drive   = 1'b0;
        check_release = 1'b0;
        repeat (4) @(posedge sck);

        $display("== Frame %s end   @%0t ==", label, $time);
    end
    endtask

    task automatic run_raw_frame(
        input [63:0] pattern,
        input integer bits,
        input string label
    );
        integer i;
    begin
        raw_pattern = pattern;
        raw_len     = bits;
        raw_idx     = 0;
        raw_mode    = 1'b1;
        rnw         = 1'b0;

        rst_n = 1'b0;
        $display("== RAW %s start @%0t | bits=%0d ==", label, $time, bits);

        for (i = 0; i < bits; i = i + 1) begin
            @(negedge sck); // 先在 negedge 更新 MOSI
            @(posedge sck); // 采样
            // raw_mode 检查在 always@(posedge sck) 中完成
        end

        // raw 模式下计数器/ACK 寄存器应保持清零
        if (dut.ack_shreg !== 8'h00 || dut.after_ack_raw !== 1'b0 || dut.after_ack !== 1'b0) begin
            $error("RAW frame left stale state: ack_shreg=%02h after_ack=%0b after_ack_raw=%0b",
                   dut.ack_shreg, dut.after_ack, dut.after_ack_raw);
        end

        raw_mode = 1'b0;
        repeat (4) @(posedge sck);

        $display("== RAW %s end   @%0t ==", label, $time);
    end
    endtask

    task automatic run_abort_frame;
    begin
        run_write_frame(REQ_ABORT, ABORT_DATA, 3'b001, "DP_ABORT_OK", 1'b1, 1'b0);
    end
    endtask

    task automatic run_wait_short;
    begin
        run_write_frame(REQ_ABORT, DUMMY_DATA, 3'b010, "WAIT_SHORT", 1'b0, 1'b1);
    end
    endtask

    task automatic run_fault_short;
    begin
        run_write_frame(REQ_ABORT, 32'hCAFEBABE, 3'b100, "FAULT_SHORT", 1'b0, 1'b1);
    end
    endtask

    task automatic run_idle_dummy_frames;
    begin
        run_raw_frame(64'hFFFF_FFFF_FFFF_FFFF, 64, "LINE_RESET");
        run_raw_frame(64'h0000_0000_0000_0000, 48, "IDLE_ZERO");
    end
    endtask

    // VCD
    initial begin
        $dumpfile("swd_special.vcd");
        $dumpvars(0, testbench_special);
    end

    initial begin
        run_idle_dummy_frames();
        run_abort_frame();
        run_wait_short();
        run_fault_short();

        $display("== TB finish ==");
        $finish;
    end

endmodule
