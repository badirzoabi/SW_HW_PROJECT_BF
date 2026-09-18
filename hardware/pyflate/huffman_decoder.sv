// ============================================================================
// huffman_decoder.sv  —  Canonical (length-limited) Huffman decoder.
//
// Implements the standard zlib/inflate canonical decode, one bit per cycle:
//
//   code=0; first=0; index=0;
//   for (len=1..MAXLEN) {
//       code |= getbit();                       // add next bit (LSB)
//       count = cnt[len];
//       if (code - first < count)               // symbol found at this length
//           return symbol[index + (code-first)];
//       index += count;
//       first  = (first + count) << 1;
//       code <<= 1;
//   }
//
// Tables (loaded once per Huffman table via the tl_* port):
//   cnt[len]      : number of codes of each length          (canonical lengths)
//   symbol[k]     : symbols sorted by (length, symbol value) (the code alphabet)
//
// Throughput: ~1 bit/cycle => ~1/(avg code length) symbols/cycle. Still orders
// of magnitude faster than the pure-Python bit-by-bit decode. A lookup-table
// front-end (peek MAXLEN bits, index a 2^MAXLEN table) reaches 1 symbol/cycle
// at the cost of table memory — see HARDWARE.md trade-offs.
// ============================================================================
module huffman_decoder #(
    parameter int MAXLEN = 15,        // max code length
    parameter int SYMW   = 9,         // symbol width (bits)
    parameter int MAXSYM = 512        // symbol table depth
) (
    input  logic              clk,
    input  logic              rst_n,

    // ---- table load ----
    input  logic              tl_we,
    input  logic              tl_is_sym,     // 1 = write symbol[], 0 = write cnt[]
    input  logic [8:0]        tl_addr,       // cnt: 1..MAXLEN ; sym: 0..MAXSYM-1
    input  logic [15:0]       tl_data,

    // ---- control ----
    input  logic              start,         // 1-cycle pulse to begin
    input  logic [31:0]       nsym,          // number of symbols to decode
    output logic              busy,
    output logic              done,

    // ---- bit source (bit_buffer) ----
    input  logic              bit_in,
    input  logic              bit_valid,
    output logic              bit_take,

    // ---- symbol output stream ----
    output logic [SYMW-1:0]   osym,
    output logic              osym_valid,
    input  logic              osym_ready
);
    // ---- tables ----
    logic [15:0]     cnt_mem [0:MAXLEN];   // index 1..MAXLEN used (0 unused)
    logic [SYMW-1:0] sym_mem [0:MAXSYM-1];

    always_ff @(posedge clk) begin
        if (tl_we) begin
            if (tl_is_sym) sym_mem[tl_addr]        <= tl_data[SYMW-1:0];
            else           cnt_mem[tl_addr[3:0]]   <= tl_data;   // len 1..MAXLEN
        end
    end

    // ---- FSM ----
    typedef enum logic [1:0] {S_IDLE, S_DEC, S_EMIT, S_DONE} state_t;
    state_t state;

    logic [19:0] code, first;
    logic [15:0] index;         // running symbol base
    logic [4:0]  len;           // 1..MAXLEN
    logic [31:0] dcount;        // symbols decoded so far
    logic [SYMW-1:0] sym_reg;

    // combinational decode test for the current bit
    logic [19:0] code_v;
    logic [15:0] cnt_v;
    logic [19:0] diff_v;
    logic        found_v;
    logic [15:0] symaddr_v;

    always_comb begin
        code_v    = code | {19'b0, bit_in};        // add next bit as LSB
        cnt_v     = cnt_mem[len];
        diff_v    = code_v - first;
        found_v   = (diff_v < {4'b0, cnt_v});
        symaddr_v = index + diff_v[15:0];
    end

    assign busy       = (state == S_DEC) || (state == S_EMIT);
    assign done       = (state == S_DONE);
    assign bit_take   = (state == S_DEC) && bit_valid;   // consume one bit/iter
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
                    end else begin
                        index <= index + cnt_v;
                        first <= (first + {4'b0, cnt_v}) << 1;
                        code  <= code_v << 1;
                        len   <= len + 5'd1;
                        // (len is guaranteed <= MAXLEN for valid streams)
                    end
                end

                S_EMIT: if (osym_ready) begin
                    if (dcount + 1 == nsym) begin
                        dcount <= dcount + 1;
                        state  <= S_DONE;
                    end else begin
                        dcount <= dcount + 1;
                        // restart canonical walk for the next symbol
                        code <= '0; first <= '0; index <= '0; len <= 5'd1;
                        state <= S_DEC;
                    end
                end

                S_DONE: state <= S_IDLE;   // ready for next block
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
