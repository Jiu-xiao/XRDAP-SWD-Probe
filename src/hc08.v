module hc08_and (
    input  wire a,   // 输入 A
    input  wire b,   // 输入 B
    output wire y    // 输出 Y = A AND B
);

    assign y = a & b;
endmodule