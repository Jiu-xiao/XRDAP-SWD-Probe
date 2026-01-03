`timescale 1ns/1ps

module testbench_special;
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

    swd_frontend_top dut(
        .sck(sck), .mosi(mosi), .miso(miso),
        .rst_n(rst_n), .rnw(rnw), .output_enable_n(output_enable_n),
        .swclk(swclk), .swdio(swdio)
    );

    always #1 sck = ~sck;

    task drive_swdio_with_log(input bit val, input integer n, input string tag);
        integer i;
        begin
            tb_swdio_en  = 1'b1;
            tb_swdio_val = val;
            mosi         = val;

            for (i=0; i<n; i=i+1) begin
                @(posedge sck);
                #0;
                $display("[RAW %s] @%0t cyc=%0d swclk=%0b swdio=%0b mosi=%0b miso=%0b",
                         tag, $time, i, swclk, swdio, mosi, miso);
            end
        end
    endtask

    task idle_cycles(input integer n);
        integer i;
        begin
            tb_swdio_en = 1'b0;
            for (i = 0; i < n; i = i + 1) begin
                @(posedge sck);
                #0;
                $display("[RAW IDLE] @%0t cyc=%0d swdio=%0b", $time, i, swdio);
            end
        end
    endtask

    initial begin
        $dumpfile("swd_special.vcd");
        $dumpvars(0, testbench_special);

        rst_n = 0;
        rnw   = 0;

        $display("== RAW LINE_RESET start @%0t ==", $time);
        drive_swdio_with_log(1'b1, 64, "LINE_RESET");
        $display("== RAW LINE_RESET end   @%0t ==", $time);

        $display("== RAW IDLE_ZERO start @%0t ==", $time);
        drive_swdio_with_log(1'b0, 50, "IDLE_ZERO");
        $display("== RAW IDLE_ZERO end   @%0t ==", $time);

        idle_cycles(4);
        $finish;
    end
endmodule
