`timescale 1ns/1ps

module testbench_read;
    reg  sck   = 0;
    reg  mosi  = 0;
    wire miso;
    reg  rst_n = 0;
    reg  rnw   = 1;
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
            rnw          = 1;

            @(posedge sck);
            @(negedge sck);
            rst_n = 1;
        end
    endtask

    task run_raw_passthrough_test(input [15:0] pattern);
        integer i;
        begin
            $display("== RAW passthrough start @%0t ==", $time);
            tb_swdio_en = 0;
            rst_n       = 0;
            rnw         = 1;

            for (i=0; i<16; i=i+1) begin
    @(negedge sck) mosi = pattern[i];
    @(posedge sck) begin
        #0;
        $display("[RAW] @%0t i=%0d mosi=%0b swdio=%0b miso=%0b", $time, i, mosi, swdio, miso);
        if (swclk !== sck)
            $fatal(1, "[RAW] SWCLK pass-through broken i=%0d", i);
        if (swdio !== mosi)
            $fatal(1, "[RAW] MOSI->SWDIO mismatch i=%0d mosi=%b swdio=%b", i, mosi, swdio);
        if (miso !== 1'bz)
            $fatal(1, "[RAW] MISO should be Z in RAW mode i=%0d miso=%b", i, miso);
    end
end

            @(negedge sck) mosi = 1'b0;
            @(posedge sck) rst_n = 1'b1;
            $display("== RAW passthrough end   @%0t ==", $time);
        end
    endtask

    task automatic host_drive_next_bit(input integer next_bit, input [7:0] req_lsb_first);
        begin
            if (next_bit <= 1) begin
                mosi = 1'b0;
            end else if (next_bit >= 2 && next_bit <= 9) begin
                mosi = req_lsb_first[next_bit-2];
            end else begin
                mosi = 1'b0;
            end
        end
    endtask

    task automatic target_drive_cur_bit_read_ok(
        input integer cur_bit,
        input [31:0]  rd_data,
        input bit     parity
    );
        begin
            tb_swdio_en  = 0;
            tb_swdio_val = 0;

            if (cur_bit == 11) begin tb_swdio_en = 1; tb_swdio_val = 1'b1; end
            else if (cur_bit == 12) begin tb_swdio_en = 1; tb_swdio_val = 1'b0; end
            else if (cur_bit == 13) begin tb_swdio_en = 1; tb_swdio_val = 1'b0; end
            else if (cur_bit >= 14 && cur_bit <= 45) begin
                tb_swdio_en  = 1;
                tb_swdio_val = rd_data[cur_bit-14];
            end else if (cur_bit == 46) begin
                tb_swdio_en  = 1;
                tb_swdio_val = parity;
            end
        end
    endtask

    task send_read_ok_frame(
        input [7:0]  req_lsb_first,
        input [31:0] rd_data
    );
        integer bit_i;
        bit parity;
        begin
            parity = ^rd_data;

            timing_reset();
            arm_frame();

            tb_bit_idx = 0;
            host_drive_next_bit(0, req_lsb_first);

            for (bit_i=0; bit_i<48; bit_i=bit_i+1) begin
                // posedge: host samples/checks; target updates drive
                @(posedge sck);
                tb_bit_idx = bit_i;

                target_drive_cur_bit_read_ok(bit_i, rd_data, parity);

                if (bit_i <= 1) begin
                    expect_host_bit($sformatf("PAD[%0d]", bit_i), 1'b0);
                end else if (bit_i >= 2 && bit_i <= 9) begin
                    expect_host_bit($sformatf("REQ[%0d]", bit_i-2), req_lsb_first[bit_i-2]);
                end else if (bit_i == 10) begin
                    expect_turnaround_z("TURN1");
                end else if (bit_i == 47) begin
                    log_ok("HOST_SKIP_TAIL_IDLE_AT_POSEDGE");
                end else begin
                    log_ok("HOST_SKIP_TARGET_PHASE");
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
                end else if (bit_i >= 14 && bit_i <= 45) begin
                    expect_target_bit($sformatf("READ_DATA[%0d]", bit_i-14), rd_data[bit_i-14]);
                end else if (bit_i == 46) begin
                    expect_target_bit("READ_PARITY", parity);
                end else if (bit_i == 47) begin
                    expect_line_idle_z("READ_TAIL_IDLE");
                end else begin
                    log_ok("TGT_SKIP_HOST_OR_TURN_PHASE");
                end

                if (bit_i < 47) begin
                    host_drive_next_bit(bit_i+1, req_lsb_first);
                end else begin
                    mosi = 1'b0;
                end
            end

            timing_report($sformatf("READ_OK REQ=0x%02x", req_lsb_first));
        end
    endtask

    initial begin
        $dumpfile("swd_read.vcd");
        $dumpvars(0, testbench_read);

        idle_cycles(4);
        run_raw_passthrough_test(16'hA5C3);

        $display("== READ_OK start @%0t | REQ=0xA5 DATA=0x12345678 ==", $time);
        send_read_ok_frame(8'hA5, 32'h1234_5678);
        $display("== READ_OK end   @%0t ==", $time);

        $finish;
    end
endmodule
