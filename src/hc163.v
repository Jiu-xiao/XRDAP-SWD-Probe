// 74HC163 简化版：4 位二进制计数器
module hc163 (
    input  wire       clk,    // 时钟，上升沿计数
    input  wire       clr_n,  // 异步清零，低有效
    input  wire       en,     // 计数使能，高电平时加 1
    output reg  [3:0] q       // 4 位计数输出
);

    always @(posedge clk or negedge clr_n) begin
        if (!clr_n) begin
            q <= 4'd0;        // 复位时清零
        end else if (en) begin
            q <= q + 1'b1;    // 使能为 1 时加 1
        end
        // en 为 0 时保持不变
    end

endmodule
