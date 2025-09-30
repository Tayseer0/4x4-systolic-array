// 4x4 systolic array: west/north inputs, propagate through PEs,
// diagonal SE chain to output results systolically.
module array4x4 #(
  parameter int BW   = 16,
  parameter int ACCW = 40
)(
  input  logic clk,
  input  logic rst_n,

  // West edge (A rows)
  input  logic signed [BW-1:0] west_in [4],
  input  logic                 west_vld[4],

  // North edge (B cols)
  input  logic signed [BW-1:0] north_in[4],
  input  logic                 north_vld[4],

  // Controls
  input  logic                 acc_clr,
  input  logic                 out_phase,

  // SE sink
  output logic                 se_valid,
  output logic signed [ACCW-1:0] se_c
);
  // Internal wires for data propagation
  logic signed [BW-1:0] a [0:3][0:4]; // a[r][c] input to PE at (r,c)
  logic signed [BW-1:0] b [0:4][0:3]; // b[r][c] input to PE at (r,c)
  logic                 v [0:3][0:4];

  // Initialize west/north borders
  genvar r, c;
  generate
    for (r=0; r<4; r++) begin
      assign a[r][0] = west_in[r];
      assign v[r][0] = west_vld[r];
    end
    for (c=0; c<4; c++) begin
      assign b[0][c] = north_in[c];
    end
  endgenerate

  // Diagonal chain c_diag[r][c] flows to c_diag[r+1][c+1]
  logic signed [ACCW-1:0] c_diag [0:4][0:4];

  // Drain step (broadcast), increments while draining
  logic [7:0] drain_step;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) drain_step <= '0;
    else if (!out_phase) drain_step <= '0;
    else drain_step <= drain_step + 8'd1;
  end

  // Instantiate PEs
  generate
    for (r=0; r<4; r++) begin: ROW
      for (c=0; c<4; c++) begin: COL
        logic signed [BW-1:0] a_out_w, b_out_w;
        logic                  v_out_w;
        logic signed [ACCW-1:0] c_out_d, c_fin;

        pe #(.BW(BW), .ACCW(ACCW)) u_pe (
          .clk, .rst_n,
          .a_in     (a[r][c]),
          .b_in     (b[r][c]),
          .in_valid (v[r][c]),
          .acc_clr  (acc_clr),
          .out_phase(out_phase),
          .drain_step(drain_step),
          .row_id   (r[1:0]),
          .col_id   (c[1:0]),
          .a_out    (a_out_w),
          .b_out    (b_out_w),
          .out_valid(v_out_w),
          .c_in_diag(c_diag[r][c]),
          .c_out_diag(c_out_d),
          .c_final  (c_fin)
        );

        // Wire east/south neighbors
        assign a[r][c+1] = a_out_w;
        assign v[r][c+1] = v_out_w;
        assign b[r+1][c] = b_out_w;

        // Diagonal chain
        assign c_diag[r+1][c+1] = c_out_d;
      end
    end
  endgenerate

  // Borders for c_diag
  // Initialize NW border to zero
  generate
    for (r=0; r<=4; r++) begin
      assign c_diag[r][0] = '0;
    end
    for (c=0; c<=4; c++) begin
      assign c_diag[0][c] = '0;
    end
  endgenerate

  // SE sink output
  // Simple valid: when draining, we will emit up to 16 values (one per drain_step 0..15)
  assign se_valid = out_phase;
  assign se_c     = c_diag[4][4];

endmodule
