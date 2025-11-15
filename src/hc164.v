// 74HC164 简化版：8 位串行输入、并行输出移位寄存器
module hc164 (
    input  wire       clk,    // 时钟：上升沿移位
    input  wire       clr_n,  // 异步清零，低有效
    input  wire       d_in,   // 串行输入
    output reg [7:0]  q       // 并行输出
);

    always @(posedge clk or negedge clr_n) begin
        if (!clr_n) begin
            q <= 8'b0;                   // 低有效异步清零
        end else begin
            q <= {q[6:0], d_in};         // 左移（Q0 新进，Q7 丢掉）
        end
    end

endmodule
