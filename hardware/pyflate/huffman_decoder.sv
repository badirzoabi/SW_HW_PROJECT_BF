// huffman_decoder.sv — canonical (zlib-style) Huffman decoder, 1 bit/clock.
// Per bit: code|=bit; if (code-first) < cnt[len] -> emit symbol[index+(code-first)]
//          else advance: index+=cnt; first=(first+cnt)<<1; code<<=1; len++.
// Tables cnt[len] and symbol[] are loaded once per block via the tl_* port.
module huffman_decoder #(
    parameter int MAXLEN = 15,        // max code length
    parameter int SYMW   = 9,         // symbol width
    parameter int MAXSYM = 512        // symbol table depth
) (
    input  logic              clk,
    input  logic              rst_n,
    // table load
    input  logic              tl_we,
    input  logic              tl_is_sym,     // 1=symbol[], 0=cnt[]
    input  logic [8:0]        tl_addr,
    input  logic [15:0]       tl_data,
    // control
    input  logic              start,         // 1-cycle pulse
    input  logic [31:0]       nsym,
    output logic              busy,
    output logic              done,
    // bit source (bit_buffer)
    input  logic              bit_in,
    input  logic              bit_valid,
    output logic              bit_take,
    // symbol output stream
    output logic [SYMW-1:0]   osym,
    output logic              osym_valid,
    input  logic              osym_ready
);
    logic [15:0]     cnt_mem [0:MAXLEN];   // cnt[1..MAXLEN]
    logic [SYMW-1:0] sym_mem [0:MAXSYM-1];

    always_ff @(posedge clk) begin
        if (tl_we) begin
            if (tl_is_sym) sym_mem[tl_addr]      <= tl_data[SYMW-1:0];
            else           cnt_mem[tl_addr[3:0]] <= tl_data;
        end
    end

    typedef enum logic [1:0] {S_IDLE, S_DEC, S_EMIT, S_DONE} state_t;
    state_t state;

    logic [19:0] code, first;
    logic [15:0] index;
    logic [4:0]  len;
    logic [31:0] dcount;
    logic [SYMW-1:0] sym_reg;

    // per-bit decode test (combinational)
    logic [19:0] code_v, diff_v;
    logic [15:0] cnt_v, symaddr_v;
    logic        found_v;
    always_comb begin
        code_v    = code | {19'b0, bit_in};
        cnt_v     = cnt_mem[len];
        diff_v    = code_v - first;
        found_v   = (diff_v < {4'b0, cnt_v});
        symaddr_v = index + diff_v[15:0];
    end

    assign busy       = (state == S_DEC) || (state == S_EMIT);
    assign done       = (state == S_DONE);
    assign bit_take   = (state == S_DEC) && bit_valid;
    assign osym       = sym_reg;
    assign osym_valid = (state == S_EMIT);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            code   <= '0; first <= '0; index <= '0; len <= 5'd1;
            dcount <= '0; sym_reg <= '0;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    code <= '0; first <= '0; index <= '0; len <= 5'd1;
                    dcount <= '0;
                    if (nsym == 0) state <= S_DONE;
                    else           state <= S_DEC;
                end

                S_DEC: if (bit_valid) begin
                    if (found_v) begin
                        sym_reg <= sym_mem[symaddr_v];
                        state   <= S_EMIT;
                    end else begin                 // advance to next length
                        index <= index + cnt_v;
                        first <= (first + {4'b0, cnt_v}) << 1;
                        code  <= code_v << 1;
                        len   <= len + 5'd1;
                    end
                end

                S_EMIT: if (osym_ready) begin
                    dcount <= dcount + 1;
                    if (dcount + 1 == nsym) state <= S_DONE;
                    else begin                     // restart for next symbol
                        code <= '0; first <= '0; index <= '0; len <= 5'd1;
                        state <= S_DEC;
                    end
                end

                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
