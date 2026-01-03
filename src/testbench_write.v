`timescale 1ns/1ps

module testbench_write;
    reg  sck   = 0;
    reg  mosi  = 0;
    wire miso;
    reg  rst_n = 0;
    reg  rnw   = 0;
    reg  output_enable_n = 0;

    wire swclk;
    wire swdio;

    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 0;
    assign swdio = tb_swdio_en ? tb_swdio_val : 1'bz;

    reg [5:0] tb_bit_idx = 0;

    swd_frontend_top dut(
        .sck(sck), .mosi(mosi), .miso(miso),
        .rst_n(rst_n), .rnw(rnw), .output_enable_n(output_enable_n),
        .swclk(swclk), .swdio(swdio)
    );

    `include "tb_timing_helpers.vh"

    always #1 sck = ~sck;

    task idle_cycles(input integer n);
        integer i;
        begin
            for (i=0; i<n; i=i+1) @(posedge sck);
        end
    endtask

    task arm_frame;
        begin
            tb_swdio_en  = 0;
            tb_swdio_val = 0;
            mosi         = 0;
            rst_n        = 0;
            rnw          = 0;

            @(posedge sck);
            @(negedge sck);
            rst_n = 1;
        end
    endtask

    function automatic bit write_parity(input [31:0] w);
        write_parity = ^w;
    endfunction

    localparam bit BIT14_PAD = 1'b0;

    task automatic host_drive_next_bit_write(
        input integer next_bit,
        input [7:0]   req_lsb_first,
        input [31:0]  wr_data,
        input bit     parity
    );
        begin
            if (next_bit <= 1) begin
                mosi = 1'b0;
            end else if (next_bit >= 2 && next_bit <= 9) begin
                mosi = req_lsb_first[next_bit-2];
            end else if (next_bit == 14) begin
                mosi = BIT14_PAD;
            end else if (next_bit >= 15 && next_bit <= 46) begin
                mosi = wr_data[next_bit-15];
            end else if (next_bit == 47) begin
                mosi = parity;
            end else begin
                mosi = 1'b0;
            end
        end
    endtask

    task automatic target_drive_cur_bit_ack_ok(input integer cur_bit);
        begin
            tb_swdio_en  = 0;
            tb_swdio_val = 0;

            if (cur_bit == 11) begin tb_swdio_en = 1; tb_swdio_val = 1'b1; end
            else if (cur_bit == 12) begin tb_swdio_en = 1; tb_swdio_val = 1'b0; end
            else if (cur_bit == 13) begin tb_swdio_en = 1; tb_swdio_val = 1'b0; end
        end
    endtask

    task send_write_ok_frame(
        input [7:0]  req_lsb_first,
        input [31:0] wr_data
    );
        integer bit_i;
        bit parity;
        begin
            parity = write_parity(wr_data);

            timing_reset();
            arm_frame();

            tb_bit_idx = 0;
            host_drive_next_bit_write(0, req_lsb_first, wr_data, parity);

            for (bit_i=0; bit_i<48; bit_i=bit_i+1) begin
                // posedge: host samples/checks; target updates drive
                @(posedge sck);
                tb_bit_idx = bit_i;

                target_drive_cur_bit_ack_ok(bit_i);

                if (bit_i <= 1) begin
                    expect_host_bit($sformatf("PAD[%0d]", bit_i), 1'b0);
                end else if (bit_i >= 2 && bit_i <= 9) begin
                    expect_host_bit($sformatf("REQ[%0d]", bit_i-2), req_lsb_first[bit_i-2]);
                end else if (bit_i == 10) begin
                    expect_turnaround_z("TURN1");
                end else if (bit_i == 14) begin
                    expect_turn2_drv_or_z("TURN2");
                end else if (bit_i >= 15 && bit_i <= 46) begin
                    expect_host_bit($sformatf("WRITE_DATA[%0d]", bit_i-15), wr_data[bit_i-15]);
                end else if (bit_i == 47) begin
                    expect_host_bit("WRITE_PARITY", parity);
                end else begin
                    log_ok("HOST_SKIP_ACK_PHASE");
                end

                // negedge: target samples/checks; host prepares next bit
                @(negedge sck);
                tb_bit_idx = bit_i;

                if (bit_i == 11) begin
                    expect_target_bit("ACK[0]", 1'b1);
                end else if (bit_i == 12) begin
                    expect_target_bit("ACK[1]", 1'b0);
                end else if (bit_i == 13) begin
                    expect_target_bit("ACK[2]", 1'b0);
                end else begin
                    log_ok("TGT_SKIP_NON_ACK_PHASE");
                end

                if (bit_i < 47) begin
                    host_drive_next_bit_write(bit_i+1, req_lsb_first, wr_data, parity);
                end else begin
                    mosi = 1'b0;
                end
            end

            timing_report($sformatf("WRITE_OK REQ=0x%02x", req_lsb_first));
        end
    endtask

    initial begin
        $dumpfile("swd_write.vcd");
        $dumpvars(0, testbench_write);

        idle_cycles(4);

        $display("== WRITE_OK start @%0t | REQ=0xA1 DATA=0xCAFEBABE ==", $time);
        send_write_ok_frame(8'hA1, 32'hCAFE_BABE);
        $display("== WRITE_OK end   @%0t ==", $time);

        $finish;
    end
endmodule
