// bit_buffer.sv — byte stream in, one bit/clock out (MSB first).
// Refills a byte when empty; stalls (bit_valid=0) when starved → back-pressure.
module bit_buffer (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       byte_valid,
    input  logic [7:0] byte_data,
    output logic       byte_ready,
    output logic       bit_out,
    output logic       bit_valid,
    input  logic       bit_take
);
    logic [7:0] sr;
    logic [3:0] cnt;                 // bits currently buffered (0..8)

    assign bit_valid  = (cnt != 0);
    assign bit_out    = sr[7];       // MSB first
    assign byte_ready = (cnt == 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr  <= 8'b0;
            cnt <= 4'b0;
        end else if (cnt == 0 && byte_valid) begin
            sr  <= byte_data;                       // refill
            cnt <= 4'd8;
        end else if (bit_take && bit_valid) begin
            sr  <= sr << 1;                         // consume one bit
            cnt <= cnt - 4'd1;
        end
    end
endmodule
