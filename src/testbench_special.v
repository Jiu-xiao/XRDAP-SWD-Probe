`timescale 1ns/1ps

// ============================================================================
// Testbench: SPECIAL cases
// - RAW sequences while rst_n=0 (MOSI→SWDIO, SWCLK pass-through)
// - Generate SWD line reset (≥50 ones) and idle-zero (≥50 zeros)
// - DUT is held in reset so it never drives the bus; TB side provides waveform shape
// ============================================================================

module testbench_special;

    // ==== DUT I/Os ====
    reg  sck   = 0;
    reg  mosi  = 0;
    wire miso;
    reg  rst_n = 0;
    reg  rnw   = 0;

    wire swclk;
    wire swdio;

    // TB side actively drives SWDIO when needed; otherwise releases the line.
    // Keep Z when not driving so RAW waveforms are clearly visible.
    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 0;
    assign swdio = tb_swdio_en ? tb_swdio_val : 1'bz;

    // ==== Instantiate DUT (name kept as 'dut' for waveform browsing) ====
    swd_frontend_top dut(
        .sck(sck), .mosi(mosi), .miso(miso),
        .rst_n(rst_n), .rnw(rnw),
        .swclk(swclk), .swdio(swdio)
    );

    // 2 ns clock
    always #1 sck = ~sck;

    // Run n rising edges
    task idle_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge sck);
        end
    endtask

    // Drive SWDIO with a constant value for n clocks
    task drive_swdio(input bit val, input integer n);
        begin
            tb_swdio_en  = 1'b1;
            tb_swdio_val = val;
            mosi         = val;   // for waveform intuition; RAW focuses on SWDIO
            idle_cycles(n);
        end
    endtask

    initial begin
        $dumpfile("swd_special.vcd");
        $dumpvars(0, testbench_special);

        // Keep DUT quiet: hold reset so it never drives the bus
        rst_n = 0;
        rnw   = 0;

        // ================= RAW · LINE RESET (≥50 ones; use 64 here) =================
        $display("== RAW LINE_RESET start @%0t | SWDIO=1 for 64 clocks ==", $time);
        drive_swdio(1'b1, 64);
        $display("== RAW LINE_RESET end   @%0t ==", $time);

        // Continue in the same RAW capture with idle-zero
        // ================= RAW · IDLE ZERO (≥50 zeros; use 50 here) =================
        $display("== RAW IDLE_ZERO start @%0t | SWDIO=0 for 50 clocks ==", $time);
        drive_swdio(1'b0, 50);
        $display("== RAW IDLE_ZERO end   @%0t ==", $time);

        // Hold a few extra cycles to let the sampling side finish (optional)
        idle_cycles(4);

        $display("== TB finish ==");
        $finish;
    end

endmodule
