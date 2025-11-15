// hc125.v
// 简化版 74HC125：1 个通道，低有效使能的三态缓冲
module hc125 (
    input  wire a,     // 数据输入 A
    input  wire oe_n,  // 输出使能 OE̅，低有效
    output wire y      // 输出 Y
);
    // oe_n = 0 时输出 A，oe_n = 1 时输出高阻态 Z
    assign y = oe_n ? 1'bz : a;

endmodule
