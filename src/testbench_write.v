// ============================================================================
// Testbench: WRITE path (logic unchanged; comments tidied)
// - Verifies WRITE transaction timing and ownership (REQ / TURN / ACK / DATA / PARITY)
// - TURNAROUND: WRITE has two turnarounds (bit10, bit14). At bit14 host may already drive or keep Z.
// - ACK handling: only when ACK=001 does host transmit DATA[31:0] (bit15..46) and PARITY (bit47).
// - RAW behavior is covered in other testbenches.
// ============================================================================

module testbench_write;
    // ==== DUT I/Os ====
    reg  sck   = 0;
    reg  mosi  = 0;
    wire miso;
    reg  rst_n = 0;
    reg  rnw   = 0;   // 0 = WRITE

    wire swclk;
    wire swdio;

    // TB: target drives only during the 3-bit ACK window; never drives in write data phase
    reg tb_swdio_en  = 0;
    reg tb_swdio_val = 0;
    assign swdio = tb_swdio_en ? tb_swdio_val : 1'bz;

    // Bit index (increments at posedge; logs the sampled bit position)
    reg [5:0] tb_bit_idx = 0;

    // ==== Instantiate DUT ====
    swd_frontend_top dut(
        .sck(sck), .mosi(mosi), .miso(miso),
        .rst_n(rst_n), .rnw(rnw),
        .swclk(swclk), .swdio(swdio)
    );

    // ==== Clock ====
    always #1 sck = ~sck;

    // ==== Utilities ====
    task idle_cycles(input integer n); integer i; begin for (i=0;i<n;i=i+1) @(posedge sck); end endtask
    task pulse_reset_1clk; begin rst_n=0; @(posedge sck); rst_n=1; @(posedge sck); end endtask

    // SWD write parity helper (kept consistent with existing TB; strict odd would be ~^w)
    function automatic bit write_parity(input [31:0] w); write_parity = ^w; endfunction

    // ==== Logging & checks (tolerant: Z/X treated as released in simulation) ====
    reg frame_timing_fail;

    function automatic bit host_is_driving;
        // DUT: OE net name is swdio_oe_n (active-low, 0 = driving)
        host_is_driving = (dut.swdio_oe_n === 1'b0);
    endfunction

    function automatic string fmt_bit(input logic b);
        if (b === 1'bz)      fmt_bit = "z";
        else if (b === 1'bx) fmt_bit = "x";
        else if (b)          fmt_bit = "1";
        else                 fmt_bit = "0";
    endfunction

    task automatic timing_log(input string tag);
        $display("[TIMING %s] @%0t bit=%0d host_drv=%0b swdio=%s mosi=%0b miso=%0b ack_phase=%0b ack_ok=%0b bit_cnt=%0d",
                 tag, $time, tb_bit_idx, host_is_driving(), fmt_bit(swdio), mosi, miso,
                 ~(dut.y2_n & dut.y3_n & dut.y4_n & dut.y5_n), ~dut.ack_ok_n, dut.bit_cnt);
    endtask

    task automatic timing_error(input string tag, input string detail);
        frame_timing_fail = 1;
        $display("[TIMING ERR %s] %s @%0t bit=%0d host_drv=%0b swdio=%s",
                 tag, detail, $time, tb_bit_idx, host_is_driving(), fmt_bit(swdio));
    endtask

    task automatic log_ok(input string tag); timing_log(tag); endtask

    task automatic expect_host_bit(input string tag, input bit expected_bit);
        #0;
        if (!host_is_driving()) begin
            timing_error(tag, "host not driving MOSI->SWDIO");
        end else if (swdio !== expected_bit) begin
            timing_error(tag, $sformatf("expected=%0b got=%s", expected_bit, fmt_bit(swdio)));
        end else begin
            timing_log(tag);
        end
    endtask

    task automatic expect_turnaround_z(input string tag);
        #0;
        if (host_is_driving()) begin
            timing_error(tag, "host should release line");
        end else if (swdio !== 1'bz && swdio !== 1'bx) begin
            timing_error(tag, "line should be high-Z (x tolerated in sim)");
        end else begin
            timing_log(tag);
        end
    endtask

    // TURN#2 (bit14): host may already start driving (placeholder) or keep Z
    task automatic expect_turnaround_drv_or_z(input string tag);
        #0;
        if (host_is_driving()) begin
            // placeholder bit — data value not required
            timing_log(tag);
        end else if (swdio !== 1'bz && swdio !== 1'bx) begin
            timing_error(tag, "line should be released (x/z accepted)");
        end else begin
            timing_log(tag);
        end
    endtask

    task automatic expect_target_bit(input string tag, input bit expected_bit);
        #0;
        if (host_is_driving()) begin
            timing_error(tag, "host must not drive while target owns the bus");
        end else if (swdio === 1'bz) begin
            timing_error(tag, "target should drive but line is high-Z");
        end else if (swdio !== expected_bit) begin
            timing_error(tag, $sformatf("expected target=%0b got=%s", expected_bit, fmt_bit(swdio)));
        end else begin
            timing_log(tag);
        end
    endtask

    task automatic expect_line_idle(input string tag);
        #0;
        if (host_is_driving()) begin
            timing_error(tag, "host should stay high-Z");
        end else if (swdio !== 1'bz && swdio !== 1'bx) begin
            timing_error(tag, "line should remain released");
        end else begin
            timing_log(tag);
        end
    endtask

    task automatic check_ack_capture(input [2:0] expected_ack);
        reg [2:0] dut_ack;
        #0; #0; #0; // allow shift/flags to settle after posedge
        dut_ack = {dut.ack2, dut.ack1, dut.ack0};
        if (dut_ack !== {expected_ack[2], expected_ack[1], expected_ack[0]}) begin
            timing_error("ACK_CAPTURE", $sformatf("expected %03b got %03b", expected_ack, dut_ack));
        end else begin
            $display("[TIMING ACK_CAPTURE] matched %03b @%0t", expected_ack, $time);
        end
    endtask

    task automatic check_ack_ok_flag(input [2:0] expected_ack);
        bit ack_ok_should_be = (expected_ack == 3'b001);
        bit ack_ok_is;
        #0; #0;
        ack_ok_is = (~dut.ack_ok_n);
        if (ack_ok_is !== ack_ok_should_be) begin
            timing_error("ACK_OK_FLAG", $sformatf("expected %0b got %0b", ack_ok_should_be, ack_ok_is));
        end else begin
            $display("[TIMING ACK_OK] flag=%0b (expected %0b) @%0t", ack_ok_is, ack_ok_should_be, $time);
        end
    endtask

    task automatic timing_reset; frame_timing_fail = 0; endtask
    task automatic timing_report(input string frame_name);
        if (!frame_timing_fail) $display("[TIMING RESULT] %s : PASS", frame_name);
        else                    $display("[TIMING RESULT] %s : FAIL (see errors above)", frame_name);
    endtask

    // ==== Send one WRITE frame ====
    // Bit14 placeholder can be configured (default 0)
    localparam bit BIT14_PAD = 1'b0;

    function automatic bit parity_bit(input [31:0] w);
        parity_bit = write_parity(w);
    endfunction

    task send_write_frame(
        input [7:0]  req_lsb_first,   // SWD REQ, LSB-first
        input [31:0] wr_data,         // data to send on ACK=001
        input [2:0]  ack_bits         // {ACK2,ACK1,ACK0}
    );
      integer i;
      reg parity;
      begin
        parity = parity_bit(wr_data);

        tb_bit_idx   = 0;
        tb_swdio_en  = 0;
        tb_swdio_val = 0;
        timing_reset();

        for (i=0;i<48;i=i+1) begin
          // --- prepare (negedge) ---
          @(negedge sck) begin
            // target drives only in the ACK window
            tb_swdio_en  <= 0;
            tb_swdio_val <= 0;
            if (tb_bit_idx==11) begin tb_swdio_en<=1; tb_swdio_val<=ack_bits[0]; end
            else if (tb_bit_idx==12) begin tb_swdio_en<=1; tb_swdio_val<=ack_bits[1]; end
            else if (tb_bit_idx==13) begin tb_swdio_en<=1; tb_swdio_val<=ack_bits[2]; end

            // Host preloads MOSI (stable before posedge)
            if (!rst_n) begin
              mosi <= 1'b0;
            end else if (tb_bit_idx<=1) begin
              mosi <= 1'b0;                                  // 0..1 padding
            end else if (tb_bit_idx>=2 && tb_bit_idx<=9) begin
              mosi <= req_lsb_first[tb_bit_idx-2];           // 2..9 REQ (LSB-first)
            end else if (ack_bits==3'b001) begin
              // ACK=001 → WRITE data phase
              if (tb_bit_idx==14)       mosi <= BIT14_PAD;                     // 14 placeholder (valid data starts at 15)
              else if (tb_bit_idx>=15 && tb_bit_idx<=46) mosi <= wr_data[tb_bit_idx-15]; // 15..46 DATA[0..31]
              else if (tb_bit_idx==47)  mosi <= parity;                        // 47 PARITY
              else                      mosi <= 1'b0;
            end else begin
              // WAIT/FAULT: keep 0 afterwards (DUT should remain Hi-Z)
              mosi <= 1'b0;
            end
          end

          // --- check (posedge) ---
          @(posedge sck) begin
            tb_bit_idx <= (!rst_n) ? 0 : tb_bit_idx + 1;

            if (tb_bit_idx<=1) begin
              expect_host_bit($sformatf("PAD[%0d]", tb_bit_idx), 1'b0);
            end else if (tb_bit_idx>=2 && tb_bit_idx<=9) begin
              expect_host_bit($sformatf("REQ[%0d]", tb_bit_idx-2), req_lsb_first[tb_bit_idx-2]);
            end else if (tb_bit_idx==10) begin
              expect_turnaround_z("TURN1");
            end else if (tb_bit_idx>=11 && tb_bit_idx<=13) begin
              expect_target_bit($sformatf("ACK[%0d]", tb_bit_idx-11), ack_bits[tb_bit_idx-11]);
            end else if (tb_bit_idx==14) begin
              check_ack_capture(ack_bits);
              check_ack_ok_flag(ack_bits);
              expect_turnaround_drv_or_z("TURN2_DRV_OR_Z");
            end else if ((ack_bits==3'b001) && tb_bit_idx>=15 && tb_bit_idx<=47) begin
              if (tb_bit_idx<47) begin
                expect_host_bit($sformatf("WRITE_DATA[%0d]", tb_bit_idx-15), wr_data[tb_bit_idx-15]);
              end else begin
                expect_host_bit("WRITE_PARITY", parity);
              end
            end else begin
              expect_line_idle("WRITE_IDLE");
            end
          end
        end

        timing_report($sformatf("WRITE REQ=0x%02x ACK=%03b", req_lsb_first, ack_bits));
      end
    endtask

    // ==== Main ====
    initial begin
      $dumpfile("swd_write.vcd");
      $dumpvars(0, testbench_write);

      idle_cycles(4);

      // ACK=001
      pulse_reset_1clk();
      $display("== Frame WRITE_OK start  @%0t | REQ=0xa1 ACK=001 DATA=0xCAFEBABE ==", $time);
      send_write_frame(8'hA1, 32'hCAFE_BABE, 3'b001);
      $display("== Frame WRITE_OK end    @%0t ==", $time);

      // ACK=010 (WAIT)
      pulse_reset_1clk();
      $display("== Frame WRITE_WAIT start @%0t | REQ=0xa1 ACK=010 ==", $time);
      send_write_frame(8'hA1, 32'hDEAD_BEEF, 3'b010);
      $display("== Frame WRITE_WAIT end   @%0t ==", $time);

      // ACK=100 (FAULT)
      pulse_reset_1clk();
      $display("== Frame WRITE_FAULT start @%0t | REQ=0xa1 ACK=100 ==", $time);
      send_write_frame(8'hA1, 32'h1234_5678, 3'b100);
      $display("== Frame WRITE_FAULT end   @%0t ==", $time);

      $display("== TB finish ==");
      $finish;
    end
endmodule
