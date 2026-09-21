// tb_mtf.sv — self-checking TB for mtf_unit.
// Load [10..80], decode indices 2,0,5 → expect {30,30,60}.
//   iverilog -g2012 -o sim mtf_unit.sv tb_mtf.sv && vvp sim
`timescale 1ns/1ps
module tb_mtf;
    localparam int N=8, W=8, AW=3;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic          ld_we; logic [AW-1:0] ld_addr; logic [W-1:0] ld_data;
    logic          in_valid; logic [AW-1:0] idx;
    logic          out_valid; logic [W-1:0] sym;

    mtf_unit #(.N(N), .W(W)) dut (
        .clk(clk), .rst_n(rst_n),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
        .in_valid(in_valid), .idx(idx),
        .out_valid(out_valid), .sym(sym)
    );

    logic [W-1:0] init [0:N-1] = '{10,20,30,40,50,60,70,80};
    logic [W-1:0] got [0:2];
    int gi=0, errors=0;

    always @(posedge clk)
        if (out_valid && rst_n) begin
            if (gi<3) got[gi]=sym;
            gi++;
        end

    initial begin
        ld_we=0; in_valid=0; idx=0; ld_addr=0; ld_data=0;
        repeat(2) @(posedge clk); rst_n=1; @(posedge clk);

        // load the alphabet
        for (int k=0;k<N;k++) begin
            ld_we<=1; ld_addr<=k[AW-1:0]; ld_data<=init[k]; @(posedge clk);
        end
        ld_we<=0; @(posedge clk);

        // decode indices 2, 0, 5  (expect symbols 30, 30, 60)
        idx<=3'd2; in_valid<=1; @(posedge clk);
        idx<=3'd0;               @(posedge clk);
        idx<=3'd5;               @(posedge clk);
        in_valid<=0;
        repeat(3) @(posedge clk);

        if (got[0]!==8'd30) begin errors++; $display("  sym0 got %0d exp 30",got[0]); end
        if (got[1]!==8'd30) begin errors++; $display("  sym1 got %0d exp 30",got[1]); end
        if (got[2]!==8'd60) begin errors++; $display("  sym2 got %0d exp 60",got[2]); end

        if (errors==0 && gi==3)
            $display("TB PASS: MTF decoded {%0d,%0d,%0d} == {30,30,60}", got[0],got[1],got[2]);
        else
            $display("TB FAIL: gi=%0d errors=%0d", gi, errors);
        $finish;
    end
    initial begin #10000; $display("TB TIMEOUT"); $finish; end
endmodule
