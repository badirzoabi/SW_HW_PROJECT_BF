// mtf_unit.sv — Move-To-Front accelerator (pyflate 2nd stage).
// Holds the alphabet in a register file; per clock: output tbl[idx], then move
// that entry to the front. Hardware version of software move_to_front(l, idx),
// 1 symbol/clock, no allocation.
module mtf_unit #(
    parameter int N  = 256,             // alphabet size
    parameter int W  = 8,               // symbol width
    parameter int AW = (N <= 2) ? 1 : $clog2(N)
) (
    input  logic          clk,
    input  logic          rst_n,
    // load the alphabet (once per block)
    input  logic          ld_we,
    input  logic [AW-1:0] ld_addr,
    input  logic [W-1:0]  ld_data,
    // decode stream
    input  logic          in_valid,
    input  logic [AW-1:0] idx,
    output logic          out_valid,    // valid 1 cycle after in_valid
    output logic [W-1:0]  sym
);
    logic [W-1:0] tbl [0:N-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            if (ld_we) begin
                tbl[ld_addr] <= ld_data;
            end else if (in_valid) begin
                sym <= tbl[idx];
                // move-to-front: tbl[0]=old tbl[idx]; tbl[1..idx]=old tbl[0..idx-1]
                for (int i = 0; i < N; i++) begin
                    if (i == 0)        tbl[0] <= tbl[idx];
                    else if (i <= idx) tbl[i] <= tbl[i-1];
                end
                out_valid <= 1'b1;
            end
        end
    end
endmodule
