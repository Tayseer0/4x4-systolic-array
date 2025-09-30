// 16-bit fixed-point (Q1.15) PE: accumulates 4 products, forwards A->E, B->S.
// Also participates in an SE-diagonal output chain for systolic draining.
module pe #(
  parameter int BW   = 16,
  parameter int ACCW = 40
)(
  input  logic                     clk,
  input  logic                     rst_n,

  // Data from west/north
  input  logic signed [BW-1:0]     a_in,
  input  logic signed [BW-1:0]     b_in,
  input  logic                     in_valid,

  // Control
  input  logic                     acc_clr,     // pulse at tile start
  input  logic                     out_phase,   // 1 during output draining
  input  logic [7:0]               drain_step,  // increments while draining
  input  logic [1:0]               row_id,      // 0..3
  input  logic [1:0]               col_id,      // 0..3

  // Pass-through to east/south
  output logic signed [BW-1:0]     a_out,
  output logic signed [BW-1:0]     b_out,
  output logic                     out_valid,

  // SE-diagonal output chain
  input  logic signed [ACCW-1:0]   c_in_diag,   // from NW neighbor
  output logic signed [ACCW-1:0]   c_out_diag,  // to SE neighbor

  // Local finalized sum exposed (for debug if needed)
  output logic signed [ACCW-1:0]   c_final
);
  // Register-forward A/B/valid (one-stage)
  logic signed [BW-1:0] a_reg, b_reg;
  logic                  v_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin a_reg <= '0; b_reg <= '0; v_reg <= 1'b0; end
    else begin a_reg <= a_in; b_reg <= b_in; v_reg <= in_valid; end
  end
  assign a_out    = a_reg;
  assign b_out    = b_reg;
  assign out_valid= v_reg;

  // MAC (sign-extended to accumulator width)
  logic signed [2*BW-1:0] prod;
  assign prod = a_reg * b_reg;

  logic signed [ACCW-1:0] acc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) acc <= '0;
    else if (acc_clr) acc <= '0;
    else if (v_reg) acc <= acc + {{(ACCW-32){prod[31]}}, prod};
  end
  assign c_final = acc;

  // --- SE-diagonal chain injection policy ---
  // Each PE injects its c_final into the diagonal chain exactly once,
  // at a distinct drain_step = row_id*4 + col_id.
  // On other cycles, it forwards whatever arrived from the NW neighbor.
  logic signed [ACCW-1:0] inject_val;
  assign inject_val = c_final;

  always_comb begin
    if (out_phase && (drain_step == {6'd0,row_id,2'd0} + col_id)) begin
      c_out_diag = inject_val;
    end else begin
      c_out_diag = c_in_diag;
    end
  end
endmodule
