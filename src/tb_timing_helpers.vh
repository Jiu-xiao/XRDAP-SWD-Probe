// Timing/log helpers (included inside the testbench module)

reg frame_timing_fail;

function automatic string fmt_bit(input logic b);
    if (b === 1'bz)      fmt_bit = "z";
    else if (b === 1'bx) fmt_bit = "x";
    else if (b)          fmt_bit = "1";
    else                 fmt_bit = "0";
endfunction

task automatic timing_log(input string tag);
    $display("[TIMING %s] @%0t bit=%0d tb_drv=%0b swdio=%s mosi=%0b miso=%0b",
             tag, $time, tb_bit_idx, tb_swdio_en, fmt_bit(swdio), mosi, miso);
endtask

task automatic timing_error(input string tag, input string detail);
    frame_timing_fail = 1;
    $display("[TIMING ERR %s] %s @%0t bit=%0d tb_drv=%0b swdio=%s mosi=%0b miso=%0b",
             tag, detail, $time, tb_bit_idx, tb_swdio_en, fmt_bit(swdio), mosi, miso);
endtask

// Host-driven bit check (called at posedge sample)
task automatic expect_host_bit(input string tag, input bit expected_bit);
    if (tb_swdio_en) begin
        timing_error(tag, "TB is driving but host bit expected");
    end else if (swdio === 1'bz) begin
        timing_error(tag, "line is Z but host should drive");
    end else if (swdio === 1'bx) begin
        timing_error(tag, "line is X (contention) while host should drive");
    end else if (swdio !== expected_bit) begin
        timing_error(tag, $sformatf("expected=%0b got=%s", expected_bit, fmt_bit(swdio)));
    end else if (swdio !== mosi) begin
        timing_error(tag, $sformatf("swdio!=mosi (mosi=%0b swdio=%s)", mosi, fmt_bit(swdio)));
    end else begin
        timing_log(tag);
    end
endtask

// Turnaround strict Z check
task automatic expect_turnaround_z(input string tag);
    if (tb_swdio_en) begin
        timing_error(tag, "TB should release line during turnaround");
    end else if (swdio !== 1'bz) begin
        timing_error(tag, $sformatf("line should be Z during turnaround (got %s)", fmt_bit(swdio)));
    end else begin
        timing_log(tag);
    end
endtask

// TURN2: allow Z or driven; never X
task automatic expect_turn2_drv_or_z(input string tag);
    if (tb_swdio_en) begin
        timing_error(tag, "TB should not drive during TURN2");
    end else if (swdio === 1'bx) begin
        timing_error(tag, "line is X (contention) at TURN2");
    end else begin
        timing_log(tag);
    end
endtask

// Target-driven bit check (called at negedge sample)
task automatic expect_target_bit(input string tag, input bit expected_bit);
    if (!tb_swdio_en) begin
        timing_error(tag, "TB should drive (target owns bus) but TB released line");
    end else if (swdio === 1'bz) begin
        timing_error(tag, "target should drive but line is Z");
    end else if (swdio === 1'bx) begin
        timing_error(tag, "line is X (contention) while target should drive");
    end else if (swdio !== expected_bit) begin
        timing_error(tag, $sformatf("expected target=%0b got=%s", expected_bit, fmt_bit(swdio)));
    end else begin
        timing_log(tag);
    end
endtask

// Idle: strict Z
task automatic expect_line_idle_z(input string tag);
    if (tb_swdio_en) begin
        timing_error(tag, "TB should release line in idle");
    end else if (swdio !== 1'bz) begin
        timing_error(tag, $sformatf("line should remain Z in idle (got %s)", fmt_bit(swdio)));
    end else begin
        timing_log(tag);
    end
endtask

task automatic timing_reset;
    frame_timing_fail = 0;
endtask

task automatic timing_report(input string frame_name);
    if (!frame_timing_fail) $display("[TIMING RESULT] %s : PASS", frame_name);
    else                    $display("[TIMING RESULT] %s : FAIL (see errors above)", frame_name);
endtask

task automatic log_ok(input string tag);
    timing_log(tag);
endtask
