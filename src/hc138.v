// 74HC138 等效：3 线 → 8 线译码器
module hc138(
    input  wire a,    // A0
    input  wire b,    // A1
    input  wire c,    // A2
    output wire [7:0] y  // 八个译码输出
);

    assign y = 1 << {c, b, a};  // 把 CBA 当成 3 bit 地址

endmodule
