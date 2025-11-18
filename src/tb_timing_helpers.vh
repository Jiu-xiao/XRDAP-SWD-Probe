// ===== Timing/log helpers (included inside the testbench module) =====

reg frame_timing_fail;

// DUT: OE net is swdio_oe_n (active-low, 0 = driving SWDIO)
function automatic bit host_is_driving;
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
    end else if (swdio !== 1'bz) begin
        timing_error(tag, "line should be high-Z during turnaround");
    end else begin
        timing_log(tag);
    end
endtask

// 在 WRITE/ACK=OK 的第二个 turnaround（bit 14），允许主机已开始驱动或保持 Z
task automatic expect_turn2_drv_or_z(input string tag);
    #0;
    if (host_is_driving()) begin
        timing_log(tag);
    end else if (swdio === 1'bz) begin
        timing_log(tag);
    end else begin
        timing_error(tag, "line should be driven by host or released (Z)");
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
    end else if (swdio !== 1'bz) begin
        timing_error(tag, "line should remain released");
    end else begin
        timing_log(tag);
    end
endtask

task automatic check_ack_capture(input [2:0] expected_ack);
    reg [2:0] dut_ack;
    #0; #0; #0; // 让移位与标志在 posedge 后稳定
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

task automatic timing_reset;
    frame_timing_fail = 0;
endtask

task automatic timing_report(input string frame_name);
    if (!frame_timing_fail) begin
        $display("[TIMING RESULT] %s : PASS", frame_name);
    end else begin
        $display("[TIMING RESULT] %s : FAIL (see errors above)", frame_name);
    end
endtask

task automatic log_ok(input string tag); timing_log(tag); endtask
