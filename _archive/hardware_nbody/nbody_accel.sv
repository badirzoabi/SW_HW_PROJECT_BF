// ============================================================================
// nbody_accel.sv  —  Top-level memory-mapped / streaming N-body accelerator.
//
// Integration model (see HARDWARE.md):
//   * A tiny MMIO register block (host writes CTRL/dt, reads STATUS/counters)
//     — mapped through a PCIe BAR or an SoC AXI4-Lite slave.
//   * A streaming DATA path (AXI4-Stream style, DMA-fed):
//       - s_axis: host/DMA pushes pair records {dx,dy,dz,mi,mj}
//       - m_axis: accelerator returns {dvi_xyz, dvj_xyz}
//   * The PE is a fixed-latency pipeline; we only accept a new pair when the
//     output FIFO is guaranteed to have room, giving lossless back-pressure.
//
// One pair/clock throughput once the pipeline is full.
// ============================================================================

module nbody_accel #(
    parameter int LAT      = 9,
    parameter int FIFO_AW  = 5      // output FIFO depth = 2**FIFO_AW (>= LAT)
) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- MMIO (AXI4-Lite-style, simplified) --------------------------------
    input  logic        reg_we,          // register write strobe
    input  logic [3:0]  reg_addr,        // word address
    input  logic [31:0] reg_wdata,
    output logic [31:0] reg_rdata,

    // ---- Input stream: pair record ----------------------------------------
    input  logic        s_valid,
    output logic        s_ready,
    input  logic [31:0] s_dx, s_dy, s_dz, s_mi, s_mj,

    // ---- Output stream: velocity deltas ------------------------------------
    output logic        m_valid,
    input  logic        m_ready,
    output logic [31:0] m_dvi_x, m_dvi_y, m_dvi_z,
    output logic [31:0] m_dvj_x, m_dvj_y, m_dvj_z
);
    // ---------------- MMIO registers ----------------------------------------
    // 0x0 CTRL  [0]=enable
    // 0x1 DT    (float timestep, latched)
    // 0x2 STATUS[0]=busy (pipeline non-empty)
    // 0x3 COUNT (pairs completed)
    localparam ADDR_CTRL = 4'h0, ADDR_DT = 4'h1, ADDR_STATUS = 4'h2, ADDR_COUNT = 4'h3;

    logic        enable;
    logic [31:0] dt_reg;
    logic [31:0] done_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable <= 1'b0;
            dt_reg <= 32'h3C23D70A; // 0.01f default
        end else if (reg_we) begin
            case (reg_addr)
                ADDR_CTRL: enable <= reg_wdata[0];
                ADDR_DT  : dt_reg <= reg_wdata;
                default  : /* no-op */ ;
            endcase
        end
    end

    // ---------------- Output FIFO occupancy / credit ------------------------
    // Reserve credit so an in-flight pipeline can never overflow the FIFO.
    logic [FIFO_AW:0] fifo_count;         // items stored in FIFO
    logic [FIFO_AW:0] inflight;           // pairs accepted but not yet in FIFO
    logic             fifo_full, fifo_empty;
    localparam int DEPTH = (1 << FIFO_AW);

    wire has_credit = ((fifo_count + inflight) < DEPTH);
    assign s_ready  = enable & has_credit;
    wire   fire_in  = s_valid & s_ready;

    // ---------------- PE ----------------------------------------------------
    logic        pe_out_valid;
    logic [31:0] pe_dvi_x, pe_dvi_y, pe_dvi_z, pe_dvj_x, pe_dvj_y, pe_dvj_z;

    nbody_pe #(.LAT(LAT)) u_pe (
        .clk(clk), .rst_n(rst_n),
        .in_valid(fire_in),
        .dx(s_dx), .dy(s_dy), .dz(s_dz), .mi(s_mi), .mj(s_mj), .dt(dt_reg),
        .out_valid(pe_out_valid),
        .dvi_x(pe_dvi_x), .dvi_y(pe_dvi_y), .dvi_z(pe_dvi_z),
        .dvj_x(pe_dvj_x), .dvj_y(pe_dvj_y), .dvj_z(pe_dvj_z)
    );

    // inflight = pairs inside the PE pipeline (accepted, not yet emerged)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) inflight <= '0;
        else        inflight <= inflight + (fire_in ? 1 : 0) - (pe_out_valid ? 1 : 0);
    end

    // ---------------- Output FIFO (192-bit words) ---------------------------
    localparam int DW = 192;
    logic [DW-1:0] fifo_din;
    logic [DW-1:0] fifo_dout;
    assign fifo_din = {pe_dvi_x, pe_dvi_y, pe_dvi_z, pe_dvj_x, pe_dvj_y, pe_dvj_z};
    wire  fifo_wr = pe_out_valid;                 // PE never stalls (credit-gated)
    wire  fifo_rd = m_valid & m_ready;

    sync_fifo #(.W(DW), .AW(FIFO_AW)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr(fifo_wr), .din(fifo_din),
        .rd(fifo_rd), .dout(fifo_dout),
        .count(fifo_count), .full(fifo_full), .empty(fifo_empty)
    );

    assign m_valid = ~fifo_empty;
    assign {m_dvi_x, m_dvi_y, m_dvi_z, m_dvj_x, m_dvj_y, m_dvj_z} = fifo_dout;

    // ---------------- Status / counters -------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          done_count <= '0;
        else if (fifo_rd)    done_count <= done_count + 1;
    end

    always_comb begin
        unique case (reg_addr)
            ADDR_CTRL  : reg_rdata = {31'b0, enable};
            ADDR_DT    : reg_rdata = dt_reg;
            ADDR_STATUS: reg_rdata = {31'b0, (inflight != 0) | ~fifo_empty};
            ADDR_COUNT : reg_rdata = done_count;
            default    : reg_rdata = 32'h0;
        endcase
    end
endmodule


// ---- Simple synchronous FIFO ----------------------------------------------
module sync_fifo #(
    parameter int W  = 192,
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          wr,
    input  logic [W-1:0]  din,
    input  logic          rd,
    output logic [W-1:0]  dout,
    output logic [AW:0]   count,
    output logic          full,
    output logic          empty
);
    localparam int DEPTH = (1 << AW);
    logic [W-1:0] mem [0:DEPTH-1];
    logic [AW-1:0] wptr, rptr;

    assign empty = (count == 0);
    assign full  = (count == DEPTH);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= '0; rptr <= '0; count <= '0;
        end else begin
            if (wr && !full)  begin mem[wptr] <= din; wptr <= wptr + 1; end
            if (rd && !empty) begin                   rptr <= rptr + 1; end
            case ({wr && !full, rd && !empty})
                2'b10: count <= count + 1;
                2'b01: count <= count - 1;
                default: ; // 00 or 11 -> unchanged
            endcase
        end
    end
    assign dout = mem[rptr];
endmodule
