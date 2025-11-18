`timescale 1ns/1ps

// ============================================================================
// Testbench: READ path
// - Verifies RAW passthrough when rst_n=0 (MOSI→SWDIO, SWCLK pass-through)
// - Verifies READ transaction timing and ownership (REQ / TURN / ACK / DATA / PARITY)
// - Checks that on ACK=001: target drives DATA[31:0] (bit14..45) and PARITY (bit46)
// ============================================================================

module testbench_read;
    // ==== DUT I/Os ====
    reg  sck   = 0;
    reg  mosi  = 0;
    wire miso;
    reg  rst_n = 0;
    reg  rnw   = 1;   // 1 = READ

    wire swclk;
    wire swdio;

    // TB drives SWDIO only in ACK/DATA windows; otherwise releases the line
    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 0;
    assign swdio = tb_swdio_en ? tb_swdio_val : 1'bz;

    // Bit index within a 48-bit frame (logged at posedge sample)
    reg [5:0] tb_bit_idx = 0;

    // ==== Instantiate DUT ====
    swd_frontend_top dut(
        .sck(sck), .mosi(mosi), .miso(miso),
        .rst_n(rst_n), .rnw(rnw),
        .swclk(swclk), .swdio(swdio)
    );

    // Helpers: printing / expects / internal probes of DUT
    `include "tb_timing_helpers.vh"

    // 2 ns period clock
    always #1 sck = ~sck;

    // ==== Local helpers ====
    task idle_cycles(input integer n);
      integer i; begin for (i=0;i<n;i=i+1) @(posedge sck); end
    endtask

    task pulse_reset_1clk;
      begin
        rst_n = 0; @(posedge sck);
        rst_n = 1; @(posedge sck);
      end
    endtask

    // ==== RAW passthrough: while rst_n=0, MOSI must appear on SWDIO (posedge-aligned) ====
    task run_raw_passthrough_test(input [15:0] pattern);
      integer i;
      begin
        $display("== RAW passthrough test start @%0t ==", $time);
        tb_swdio_en   = 0;   // target does not drive
        rst_n         = 0;   // RAW
        rnw           = 1;   // don't care

        for (i = 0; i < 16; i = i + 1) begin
          @(negedge sck) begin
            mosi <= pattern[i];
          end
          @(posedge sck) begin
            // SWCLK must pass through
            if (swclk !== sck) $fatal(1, "[RAW] SWCLK pass-through broken at i=%0d", i);
            // MOSI must pass to SWDIO (DUT drives the line; should not be Z)
            if (swdio !== mosi) $fatal(1, "[RAW] MOSI->SWDIO mismatch at i=%0d: mosi=%b swdio=%b", i, mosi, swdio);
            // MISO readback should match
            if (miso !== mosi)  $fatal(1, "[RAW] MISO mismatch at i=%0d: mosi=%b miso=%b", i, mosi, miso);
          end
        end

        // Exit RAW
        @(negedge sck) mosi <= 1'b0;
        @(posedge sck) rst_n <= 1'b1;
        $display("== RAW passthrough test end   @%0t ==", $time);
      end
    endtask

    // ==== Send one 48-bit READ frame ====
    task send_read_frame(
        input [7:0]  req_lsb_first,  // SWD REQ, LSB-first
        input [31:0] rd_data,        // expected DATA for ACK=001
        input [2:0]  ack_bits        // {ACK2,ACK1,ACK0}, LSB-first on the wire
    );
      integer i;
      reg parity;
      begin
        parity = ^rd_data;  // keep consistent with README/TB (odd parity via XOR)
        tb_bit_idx  = 0;
        tb_swdio_en = 0;
        tb_swdio_val= 0;
        timing_reset();

        for (i=0;i<48;i=i+1) begin
          // --- Prepare on negedge: TB drives only in ACK window and READ data phase ---
          @(negedge sck) begin
            tb_swdio_en  <= 0;
            tb_swdio_val <= 0;

            // ACK window: bit 11..13 (ACK0..2, LSB-first)
            if (tb_bit_idx==11) begin
              tb_swdio_en  <= 1; tb_swdio_val <= ack_bits[0];
            end else if (tb_bit_idx==12) begin
              tb_swdio_en  <= 1; tb_swdio_val <= ack_bits[1];
            end else if (tb_bit_idx==13) begin
              tb_swdio_en  <= 1; tb_swdio_val <= ack_bits[2];
            end
            // READ data 14..45, parity 46 (only if ACK=001)
            else if (ack_bits==3'b001 && tb_bit_idx>=14 && tb_bit_idx<=46) begin
              tb_swdio_en  <= 1;
              if (tb_bit_idx<46) tb_swdio_val <= rd_data[tb_bit_idx-14];
              else               tb_swdio_val <= parity;
            end

            // Host preloads next MOSI so it's stable before posedge
            if (!rst_n) begin
              mosi <= 1'b0;
            end else if (tb_bit_idx<=1) begin
              mosi <= 1'b0;                            // 0..1 padding
            end else if (tb_bit_idx>=2 && tb_bit_idx<=9) begin
              mosi <= req_lsb_first[tb_bit_idx-2];     // 2..9 REQ (LSB-first)
            end else begin
              mosi <= 1'b0;                            // otherwise keep 0
            end
          end

          // --- Sample & checks on posedge ---
          @(posedge sck) begin
            tb_bit_idx <= (!rst_n) ? 0 : tb_bit_idx + 1;

            // 0..1 padding
            if (tb_bit_idx<=1) begin
              expect_host_bit($sformatf("PAD[%0d]", tb_bit_idx), 1'b0);
            end
            // 2..9 REQ (LSB-first)
            else if (tb_bit_idx>=2 && tb_bit_idx<=9) begin
              expect_host_bit($sformatf("REQ[%0d]", tb_bit_idx-2), req_lsb_first[tb_bit_idx-2]);
            end
            // 10 turnaround#1
            else if (tb_bit_idx==10) begin
              expect_turnaround_z("TURN1");
            end
            // 11..13 ACK window
            else if (tb_bit_idx>=11 && tb_bit_idx<=13) begin
              expect_target_bit($sformatf("ACK[%0d]", tb_bit_idx-11), ack_bits[tb_bit_idx-11]);
            end
            // 14: READ data start (ACK=001) / otherwise keep idle
            else if (tb_bit_idx==14) begin
              // Verify ACK captured to ack_shreg and ack_ok computed
              check_ack_capture(ack_bits);
              check_ack_ok_flag(ack_bits);
              if (ack_bits==3'b001) begin
                expect_target_bit("READ_DATA[0]", rd_data[0]);
              end else begin
                expect_line_idle("TURN2_IDLE");
              end
            end
            // 15..45 data bits when ACK=001
            else if (ack_bits==3'b001 && tb_bit_idx>=15 && tb_bit_idx<=45) begin
              expect_target_bit($sformatf("READ_DATA[%0d]", tb_bit_idx-14), rd_data[tb_bit_idx-14]);
            end
            // 46 parity (READ+OK)
            else if (ack_bits==3'b001 && tb_bit_idx==46) begin
              expect_target_bit("READ_PARITY", parity);
            end
            // Tail idle (bit 47 and all WAIT/FAULT bits)
            else begin
              expect_line_idle("READ_IDLE");
            end
          end
        end

        timing_report($sformatf("READ REQ=0x%02x ACK=%03b", req_lsb_first, ack_bits));
      end
    endtask

    // ==== Main ====
    initial begin
      $dumpfile("swd_read.vcd");
      $dumpvars(0, testbench_read);

      // Settle clock
      idle_cycles(4);

      // RAW passthrough (rst_n=0)
      run_raw_passthrough_test(16'hA5C3);

      // READ OK
      pulse_reset_1clk();  // reset one cycle before frame, ensure bit_cnt starts at 0
      $display("== Frame READ_OK start @%0t | REQ=0xa5 ACK=001 DATA=0x12345678 ==", $time);
      send_read_frame(8'hA5, 32'h1234_5678, 3'b001);
      $display("== Frame READ_OK end   @%0t ==", $time);

      // READ WAIT
      pulse_reset_1clk();
      $display("== Frame READ_WAIT start @%0t | REQ=0xa5 ACK=010 ==", $time);
      send_read_frame(8'hA5, 32'hDEAD_BEEF, 3'b010);
      $display("== Frame READ_WAIT end   @%0t ==", $time);

      $display("== TB finish ==");
      $finish;
    end
endmodule
