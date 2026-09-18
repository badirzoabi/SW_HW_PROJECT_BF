// ============================================================================
// nbody_pe.sv  —  N-body pairwise-interaction Processing Element
//
// Fully-pipelined, fixed-latency datapath (IEEE-754 single precision).
// One body-pair enters per clock; a result set leaves LAT cycles later.
//
// Per pair it computes:
//     d2   = dx^2 + dy^2 + dz^2
//     r    = 1/sqrt(d2)                       (reciprocal square root unit)
//     mag  = dt * r^3        (= dt * d2^-1.5)
//     b_i  = m_i * mag ,  b_j = m_j * mag
//     dvi_{x,y,z} = d_{x,y,z} * b_j           (to be SUBTRACTED from v_i)
//     dvj_{x,y,z} = d_{x,y,z} * b_i           (to be ADDED     to   v_j)
//
// This is the exact arithmetic the software inner loop does; the accelerator
// removes the per-pair interpreter/memory overhead and pipelines the FP math.
//
// Latency (each fp op = 1 cycle in this model):
//   sq(1) -> add(2) -> add(3) -> rsqrt(4) -> r2(5) -> r3(6) -> mag(7)
//   -> b(8) -> dv(9)   =>  LAT = 9
// ============================================================================

module nbody_pe #(
    parameter int LAT = 9
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    input  logic [31:0] dx, dy, dz,   // position differences  (x_i - x_j) ...
    input  logic [31:0] mi, mj,       // masses of body i and j
    input  logic [31:0] dt,           // timestep

    output logic        out_valid,
    output logic [31:0] dvi_x, dvi_y, dvi_z,
    output logic [31:0] dvj_x, dvj_y, dvj_z
);

    // ---- Stage 1: squares ---------------------------------------------------
    logic [31:0] sq_x, sq_y, sq_z;
    fp_mul u_sqx (.clk(clk), .a(dx), .b(dx), .y(sq_x));
    fp_mul u_sqy (.clk(clk), .a(dy), .b(dy), .y(sq_y));
    fp_mul u_sqz (.clk(clk), .a(dz), .b(dz), .y(sq_z));

    // ---- Stages 2-3: d2 = (sq_x+sq_y) + sq_z --------------------------------
    logic [31:0] sum1, sq_z_d1, d2;
    fp_add u_add1 (.clk(clk), .a(sq_x), .b(sq_y), .y(sum1));          // @t+2
    delayline #(.W(32), .D(1)) u_dz1 (.clk(clk), .d(sq_z), .q(sq_z_d1)); // @t+2
    fp_add u_add2 (.clk(clk), .a(sum1), .b(sq_z_d1), .y(d2));         // @t+3

    // ---- Stage 4: r = rsqrt(d2) ---------------------------------------------
    logic [31:0] r;
    fp_rsqrt u_rsqrt (.clk(clk), .x(d2), .y(r));                      // @t+4

    // ---- Stages 5-6: r3 = r*r*r --------------------------------------------
    logic [31:0] r2, r_d1, r3;
    fp_mul u_r2 (.clk(clk), .a(r), .b(r), .y(r2));                    // @t+5
    delayline #(.W(32), .D(1)) u_rd1 (.clk(clk), .d(r), .q(r_d1));    // @t+5
    fp_mul u_r3 (.clk(clk), .a(r2), .b(r_d1), .y(r3));               // @t+6

    // ---- Stage 7: mag = dt * r3 --------------------------------------------
    logic [31:0] dt_d6, mag;
    delayline #(.W(32), .D(6)) u_dt (.clk(clk), .d(dt), .q(dt_d6));   // @t+6
    fp_mul u_mag (.clk(clk), .a(dt_d6), .b(r3), .y(mag));            // @t+7

    // ---- Stage 8: b_i = m_i*mag , b_j = m_j*mag -----------------------------
    logic [31:0] mi_d7, mj_d7, b_i, b_j;
    delayline #(.W(32), .D(7)) u_mi (.clk(clk), .d(mi), .q(mi_d7));   // @t+7
    delayline #(.W(32), .D(7)) u_mj (.clk(clk), .d(mj), .q(mj_d7));   // @t+7
    fp_mul u_bi (.clk(clk), .a(mi_d7), .b(mag), .y(b_i));            // @t+8
    fp_mul u_bj (.clk(clk), .a(mj_d7), .b(mag), .y(b_j));            // @t+8

    // ---- Stage 9: velocity deltas ------------------------------------------
    logic [31:0] dx_d8, dy_d8, dz_d8;
    delayline #(.W(32), .D(8)) u_dxd (.clk(clk), .d(dx), .q(dx_d8)); // @t+8
    delayline #(.W(32), .D(8)) u_dyd (.clk(clk), .d(dy), .q(dy_d8));
    delayline #(.W(32), .D(8)) u_dzd (.clk(clk), .d(dz), .q(dz_d8));

    fp_mul u_dvix (.clk(clk), .a(dx_d8), .b(b_j), .y(dvi_x));        // @t+9
    fp_mul u_dviy (.clk(clk), .a(dy_d8), .b(b_j), .y(dvi_y));
    fp_mul u_dviz (.clk(clk), .a(dz_d8), .b(b_j), .y(dvi_z));
    fp_mul u_dvjx (.clk(clk), .a(dx_d8), .b(b_i), .y(dvj_x));
    fp_mul u_dvjy (.clk(clk), .a(dy_d8), .b(b_i), .y(dvj_y));
    fp_mul u_dvjz (.clk(clk), .a(dz_d8), .b(b_i), .y(dvj_z));

    // ---- valid pipeline -----------------------------------------------------
    logic [LAT:1] vpipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) vpipe <= '0;
        else        vpipe <= {vpipe[LAT-1:1], in_valid};
    end
    assign out_valid = vpipe[LAT];

endmodule


// ---- Simple parametric delay line (D registers deep) -----------------------
module delayline #(
    parameter int W = 32,
    parameter int D = 1
) (
    input  logic         clk,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
    generate
        if (D == 0) begin : g_passthru
            assign q = d;
        end else begin : g_regs
            logic [W-1:0] r [1:D];
            integer k;
            always_ff @(posedge clk) begin
                r[1] <= d;
                for (k = 2; k <= D; k = k + 1) r[k] <= r[k-1];
            end
            assign q = r[D];
        end
    endgenerate
endmodule
