// Simple synchronous single-port RAM (DW parameterized)
module spram #(
  parameter int AW = 12,
  parameter int DW = 16
)(
  input  logic           clk,
  input  logic [AW-1:0]  addr,
  input  logic           we,
  input  logic [DW-1:0]  din,
  output logic [DW-1:0]  dout
);
  logic [DW-1:0] mem [0:(1<<AW)-1];

  always_ff @(posedge clk) begin
    if (we) mem[addr] <= din;
    dout <= mem[addr];
  end
endmodule
