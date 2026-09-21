// huffman_accel.sv — MMIO + streaming wrapper around bit_buffer + huffman_decoder.
// Host loads cnt[]/symbol[] tables and NSYM via MMIO, pulses start, then DMAs
// compressed bytes in and decoded symbols out. See HARDWARE.md.
module huffman_accel #(
    parameter int MAXLEN = 15,
    parameter int SYMW   = 9,
    parameter int MAXSYM = 512
) (
    input  logic        clk,
    input  logic        rst_n,
    // MMIO
    input  logic        reg_we,
    input  logic [3:0]  reg_addr,
    input  logic [31:0] reg_wdata,
    output logic [31:0] reg_rdata,
    // byte input stream
    input  logic        byte_valid,
    input  logic [7:0]  byte_data,
    output logic        byte_ready,
    // symbol output stream
    output logic [SYMW-1:0] osym,
    output logic            osym_valid,
    input  logic            osym_ready
);
    // register map: CTRL / NSYM / STATUS / COUNT / TBL_CNT / TBL_SYM
    localparam ADDR_CTRL=4'h0, ADDR_NSYM=4'h1, ADDR_STATUS=4'h2, ADDR_COUNT=4'h3,
               ADDR_TBLCNT=4'h4, ADDR_TBLSYM=4'h5;

    logic [31:0] nsym_reg;
    logic        start_pulse;
    logic        tl_we, tl_is_sym;
    logic [8:0]  tl_addr;
    logic [15:0] tl_data;
    logic        busy, done;
    logic [31:0] count_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nsym_reg <= 32'd0; start_pulse <= 1'b0;
            tl_we <= 1'b0; tl_is_sym <= 1'b0; tl_addr <= 9'd0; tl_data <= 16'd0;
        end else begin
            start_pulse <= 1'b0;          // 1-cycle pulses
            tl_we       <= 1'b0;
            if (reg_we) begin
                case (reg_addr)
                    ADDR_NSYM  : nsym_reg <= reg_wdata;
                    ADDR_CTRL  : start_pulse <= reg_wdata[0];
                    ADDR_TBLCNT: begin           // wdata[3:0]=len, [31:16]=count
                        tl_we <= 1'b1; tl_is_sym <= 1'b0;
                        tl_addr <= {5'b0, reg_wdata[3:0]};
                        tl_data <= reg_wdata[31:16];
                    end
                    ADDR_TBLSYM: begin           // wdata[24:16]=index, [8:0]=symbol
                        tl_we <= 1'b1; tl_is_sym <= 1'b1;
                        tl_addr <= reg_wdata[24:16];
                        tl_data <= {7'b0, reg_wdata[8:0]};
                    end
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          count_reg <= 32'd0;
        else if (start_pulse)                count_reg <= 32'd0;
        else if (osym_valid && osym_ready)   count_reg <= count_reg + 1;
    end

    always_comb begin
        unique case (reg_addr)
            ADDR_NSYM  : reg_rdata = nsym_reg;
            ADDR_STATUS: reg_rdata = {30'b0, done, busy};
            ADDR_COUNT : reg_rdata = count_reg;
            default    : reg_rdata = 32'h0;
        endcase
    end

    logic bit_out, bit_valid, bit_take;

    bit_buffer u_bb (
        .clk(clk), .rst_n(rst_n),
        .byte_valid(byte_valid), .byte_data(byte_data), .byte_ready(byte_ready),
        .bit_out(bit_out), .bit_valid(bit_valid), .bit_take(bit_take)
    );

    huffman_decoder #(.MAXLEN(MAXLEN), .SYMW(SYMW), .MAXSYM(MAXSYM)) u_dec (
        .clk(clk), .rst_n(rst_n),
        .tl_we(tl_we), .tl_is_sym(tl_is_sym), .tl_addr(tl_addr), .tl_data(tl_data),
        .start(start_pulse), .nsym(nsym_reg), .busy(busy), .done(done),
        .bit_in(bit_out), .bit_valid(bit_valid), .bit_take(bit_take),
        .osym(osym), .osym_valid(osym_valid), .osym_ready(osym_ready)
    );
endmodule
