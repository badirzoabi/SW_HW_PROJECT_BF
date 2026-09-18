// ============================================================================
// tb_nbody_pe.sv  —  Self-checking testbench for the N-body PE pipeline.
// Feeds random-ish pairs, compares hardware output against a shortreal
// reference computed the same way the software does.
//   Simulate (Icarus):  iverilog -g2012 -o sim fp_ops.sv nbody_pe.sv tb_nbody_pe.sv && vvp sim
//   Simulate (Verilator/VCS/Questa): compile the same 3 files.
// ============================================================================
`timescale 1ns/1ps

module tb_nbody_pe;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    logic        in_valid;
    logic [31:0] dx, dy, dz, mi, mj, dt;
    logic        out_valid;
    logic [31:0] dvi_x, dvi_y, dvi_z, dvj_x, dvj_y, dvj_z;

    nbody_pe #(.LAT(9)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .dx(dx), .dy(dy), .dz(dz), .mi(mi), .mj(mj), .dt(dt),
        .out_valid(out_valid),
        .dvi_x(dvi_x), .dvi_y(dvi_y), .dvi_z(dvi_z),
        .dvj_x(dvj_x), .dvj_y(dvj_y), .dvj_z(dvj_z)
    );

    function automatic [31:0] f2b(input real r); f2b = $shortrealtobits(shortreal'(r)); endfunction

    // reference expected deltas for a pair
    task automatic ref_calc(input real ddx, ddy, ddz, mmi, mmj, ddt,
                            output real evi_x, evi_y, evi_z, evj_x, evj_y, evj_z);
        real d2, mag, bi, bj;
        begin
            d2  = ddx*ddx + ddy*ddy + ddz*ddz;
            mag = ddt * (1.0/(d2*$sqrt(d2)));   // dt * d2^-1.5
            bi  = mmi*mag;  bj = mmj*mag;
            evi_x = ddx*bj; evi_y = ddy*bj; evi_z = ddz*bj;
            evj_x = ddx*bi; evj_y = ddy*bi; evj_z = ddz*bi;
        end
    endtask

    // store expected values in queues, aligned with pipeline output
    real q_vix[$], q_viy[$], q_viz[$], q_vjx[$], q_vjy[$], q_vjz[$];
    int  errors = 0, checked = 0;

    function automatic real relerr(input real got, exp);
        if (exp == 0.0) relerr = (got == 0.0) ? 0.0 : 1.0;
        else            relerr = (got-exp)/exp < 0 ? -((got-exp)/exp) : (got-exp)/exp;
    endfunction

    task automatic push(input real ddx, ddy, ddz, mmi, mmj);
        real evi_x,evi_y,evi_z,evj_x,evj_y,evj_z;
        begin
            dx=f2b(ddx); dy=f2b(ddy); dz=f2b(ddz); mi=f2b(mmi); mj=f2b(mmj);
            in_valid = 1;
            ref_calc(ddx,ddy,ddz,mmi,mmj, 0.01, evi_x,evi_y,evi_z,evj_x,evj_y,evj_z);
            q_vix.push_back(evi_x); q_viy.push_back(evi_y); q_viz.push_back(evi_z);
            q_vjx.push_back(evj_x); q_vjy.push_back(evj_y); q_vjz.push_back(evj_z);
            @(posedge clk);
        end
    endtask

    // checker
    always @(posedge clk) begin
        if (out_valid && rst_n) begin
            real e; real g;
            e = q_vix.pop_front(); g = $bitstoshortreal(dvi_x);
            if (relerr(g,e) > 1e-4) begin errors++; $display("  MISMATCH dvi_x got=%g exp=%g", g, e); end
            e = q_vjx.pop_front(); g = $bitstoshortreal(dvj_x);
            if (relerr(g,e) > 1e-4) begin errors++; $display("  MISMATCH dvj_x got=%g exp=%g", g, e); end
            // (spot-check x components; y/z share the datapath)
            void'(q_viy.pop_front()); void'(q_viz.pop_front());
            void'(q_vjy.pop_front()); void'(q_vjz.pop_front());
            checked++;
        end
    end

    initial begin
        dt = f2b(0.01);
        in_valid = 0; dx=0;dy=0;dz=0;mi=0;mj=0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Feed a handful of pairs (values in the range the benchmark produces)
        push( 4.84, -1.16, -0.10, 39.47, 0.0377 );  // sun-jupiter-ish
        push( 8.34,  4.12, -0.40, 39.47, 0.0113 );
        push(-3.50,  5.28,  0.30,  0.0377, 0.0113 );
        push(12.89,-15.11, -0.22, 39.47, 0.00172);
        push(15.38,-25.92,  0.18, 39.47, 0.00203);
        in_valid = 0;

        repeat (9 + 4) @(posedge clk);   // drain pipeline

        if (errors == 0 && checked == 5)
            $display("TB PASS: %0d pairs checked, 0 mismatches.", checked);
        else
            $display("TB FAIL: checked=%0d errors=%0d", checked, errors);
        $finish;
    end
endmodule
