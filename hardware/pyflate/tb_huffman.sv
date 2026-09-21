// tb_huffman.sv — self-checking TB for huffman_decoder.
// 3-symbol canonical code (0="0", 1="10", 2="11"); byte 0x70 encodes A,C,B.
// Expected decode: {0, 2, 1}.
//   iverilog -g2012 -o sim bit_buffer.sv huffman_decoder.sv tb_huffman.sv && vvp sim
`timescale 1ns/1ps

module tb_huffman;
    localparam int SYMW = 9;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // table load
    logic        tl_we, tl_is_sym;
    logic [8:0]  tl_addr;
    logic [15:0] tl_data;
    // control
    logic        start;
    logic [31:0] nsym;
    logic        busy, done;
    // byte input
    logic        byte_valid;
    logic [7:0]  byte_data;
    logic        byte_ready;
    // bit link
    logic        bit_out, bit_valid, bit_take;
    // symbol output
    logic [SYMW-1:0] osym;
    logic            osym_valid, osym_ready;

    bit_buffer u_bb (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(byte_valid), .byte_data(byte_data), .byte_ready(byte_ready),
        .bit_out(bit_out), .bit_valid(bit_valid), .bit_take(bit_take)
    );

    huffman_decoder #(.MAXLEN(15), .SYMW(SYMW), .MAXSYM(512)) u_dec (
        .clk(clk), .rst_n(rst_n),
        .tl_we(tl_we), .tl_is_sym(tl_is_sym), .tl_addr(tl_addr), .tl_data(tl_data),
        .start(start), .nsym(nsym), .busy(busy), .done(done),
        .bit_in(bit_out), .bit_valid(bit_valid), .bit_take(bit_take),
        .osym(osym), .osym_valid(osym_valid), .osym_ready(osym_ready)
    );

    task automatic wr_tbl(input logic is_sym, input [8:0] a, input [15:0] d);
        begin
            @(posedge clk);
            tl_we <= 1; tl_is_sym <= is_sym; tl_addr <= a; tl_data <= d;
            @(posedge clk);
            tl_we <= 0;
        end
    endtask

    int got_idx = 0;
    logic [SYMW-1:0] got [0:2];
    int errors = 0;

    // capture decoded symbols
    always @(posedge clk) begin
        if (osym_valid && osym_ready && rst_n) begin
            if (got_idx < 3) got[got_idx] <= osym;
            got_idx <= got_idx + 1;
        end
    end

    initial begin
        tl_we=0; tl_is_sym=0; tl_addr=0; tl_data=0;
        start=0; nsym=0; byte_valid=0; byte_data=0; osym_ready=1;
        repeat (3) @(posedge clk);
        rst_n = 1;

        // load counts (len 1..15) : cnt[1]=1, cnt[2]=2, rest 0
        wr_tbl(0, 9'd1, 16'd1);
        wr_tbl(0, 9'd2, 16'd2);
        for (int L = 3; L <= 15; L++) wr_tbl(0, L[8:0], 16'd0);
        // load symbols sorted by (len,sym): {0,1,2}
        wr_tbl(1, 9'd0, 16'd0);
        wr_tbl(1, 9'd1, 16'd1);
        wr_tbl(1, 9'd2, 16'd2);

        // present the encoded byte
        @(posedge clk);
        byte_data <= 8'h70; byte_valid <= 1;

        // kick off decode of 3 symbols
        nsym <= 3;
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // wait for completion
        wait (done);
        @(posedge clk);
        byte_valid <= 0;

        // check
        if (got[0] !== 9'd0) begin errors++; $display("  sym0 got %0d exp 0", got[0]); end
        if (got[1] !== 9'd2) begin errors++; $display("  sym1 got %0d exp 2", got[1]); end
        if (got[2] !== 9'd1) begin errors++; $display("  sym2 got %0d exp 1", got[2]); end

        if (errors == 0 && got_idx == 3)
            $display("TB PASS: decoded {%0d,%0d,%0d} == {0,2,1}", got[0], got[1], got[2]);
        else
            $display("TB FAIL: got_idx=%0d errors=%0d", got_idx, errors);
        $finish;
    end

    // safety timeout
    initial begin #10000; $display("TB TIMEOUT"); $finish; end
endmodule
