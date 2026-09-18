// ============================================================================
// fp_ops.sv  —  Behavioral (simulation-only) models of pipelined IEEE-754
// single-precision floating-point operators.
//
// In a real design these are standard library IP (e.g. DesignWare
// DW_fp_mult / DW_fp_add / DW_fp_recip_sqrt, FloPoCo, or Xilinx Floating-Point
// LogiCORE). Here each is modeled as a 1-cycle-latency registered operator so
// the pipeline timing in nbody_pe.sv is exact and the testbench runs in any
// SystemVerilog simulator. Swap these for the vendor IP for synthesis.
// ============================================================================

module fp_mul (
    input  logic        clk,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
    always_ff @(posedge clk)
        y <= $shortrealtobits($bitstoshortreal(a) * $bitstoshortreal(b));
endmodule


module fp_add (
    input  logic        clk,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
    always_ff @(posedge clk)
        y <= $shortrealtobits($bitstoshortreal(a) + $bitstoshortreal(b));
endmodule


// Reciprocal square root: y = 1 / sqrt(x).  Modeled at 1-cycle latency.
// A real unit uses a LUT seed + 1-2 Newton-Raphson iterations
//   (y_{k+1} = y_k * (1.5 - 0.5*x*y_k^2)); see fxp note in HARDWARE.md.
module fp_rsqrt (
    input  logic        clk,
    input  logic [31:0] x,
    output logic [31:0] y
);
    real xr;
    always_ff @(posedge clk) begin
        xr = $bitstoshortreal(x);
        if (xr <= 0.0)
            y <= 32'h7F800000; // +inf guard (should not happen: d2 > 0)
        else
            y <= $shortrealtobits(shortreal'(1.0 / $sqrt(xr)));
    end
endmodule
