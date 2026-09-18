// ============================================================================
// bit_buffer.sv  —  MSB-first serial bit source for the Huffman decoder.
// Accepts bytes (DMA/stream) and hands out one bit at a time. Refills from the
// next byte when empty (1-cycle bubble every 8 bits). Stalls (bit_valid=0) when
// no input byte is available, which naturally back-pressures the decoder.
// ============================================================================
module bit_buffer (
    input  logic       clk,
    input  logic       rst_n,
    // byte input (stream / DMA)
    input  logic       byte_valid,
    input  logic [7:0] byte_data,
    output logic       byte_ready,
    // serial bit output
    output logic       bit_out,
    output logic       bit_valid,
    input  logic       bit_take
);
    logic [7:0] sr;
    logic [3:0] cnt;         // 0..8 bits currently buffered

    assign bit_valid  = (cnt != 0);
    assign bit_out    = sr[7];              // MSB first
    assign byte_ready = (cnt == 0);         // can load when empty

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr  <= 8'b0;
            cnt <= 4'b0;
        end else if (cnt == 0 && byte_valid) begin
            sr  <= byte_data;
            cnt <= 4'd8;
        end else if (bit_take && bit_valid) begin
            sr  <= sr << 1;
            cnt <= cnt - 4'd1;
        end
    end
endmodule
