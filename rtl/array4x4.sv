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
  input  logic                 out_phase,   // asserted during drain window

  // SE sink
  output logic                 se_valid,
  output logic signed [ACCW-1:0] se_c
);
  // ---------------- Data propagation (compute phase) ----------------
  logic signed [BW-1:0] a [0:3][0:4];
  logic signed [BW-1:0] b [0:4][0:3];
  logic                 v [0:3][0:4];

  genvar r,c;
  generate
    for (r=0;r<4;r++) begin
      assign a[r][0] = west_in[r];
      assign v[r][0] = west_vld[r];
    end
    for (c=0;c<4;c++) begin
      assign b[0][c] = north_in[c];
    end
  endgenerate

  // Each PE exposes its final accumulator and also passes A→E, B→S
  logic signed [ACCW-1:0] c_final [0:3][0:3];

  // Instantiate PEs (compute path only)
  generate
    for (r=0;r<4;r++) begin: ROW
      for (c=0;c<4;c++) begin: COL
        logic signed [BW-1:0] a_out_w, b_out_w;
        logic                  v_out_w;

        pe #(.BW(BW), .ACCW(ACCW)) u_pe (
          .clk, .rst_n,
          .a_in     (a[r][c]),
          .b_in     (b[r][c]),
          .in_valid (v[r][c]),
          .acc_clr  (acc_clr),
          // output-drain signals unused internally in this minimalist PE
          .out_phase(1'b0),
          .drain_step(8'd0),
          .row_id(r[1:0]), .col_id(c[1:0]),
          .a_out(a_out_w), .b_out(b_out_w), .out_valid(v_out_w),
          .c_in_diag('0), .c_out_diag(), .c_final(c_final[r][c])
        );

        assign a[r][c+1] = a_out_w;
        assign v[r][c+1] = v_out_w;
        assign b[r+1][c] = b_out_w;
      end
    end
  endgenerate

  // ---------------- SNAKE output shift (systolic drain) ----------------
  // Path ends at (3,3) (SE sink). Single-value stream: one token/cycle.
  // Snake NEXT mapping towards sink:
  //   Row0 (even): go LEFT ... (0,0) -> DOWN to (1,0)
  //   Row1 (odd) : go RIGHT ... (1,3) -> DOWN to (2,3)
  //   Row2 (even): go LEFT ... (2,0) -> DOWN to (3,0)
  //   Row3 (odd) : go RIGHT ... (3,3) -> SINK
  function automatic void next_of(input int r, input int c, output int nr, output int nc);
    if (r==0) begin
      if (c>0)      begin nr=r;   nc=c-1; end
      else          begin nr=1;   nc=0;   end
    end else if (r==1) begin
      if (c<3)      begin nr=r;   nc=c+1; end
      else          begin nr=2;   nc=3;   end
    end else if (r==2) begin
      if (c>0)      begin nr=r;   nc=c-1; end
      else          begin nr=3;   nc=0;   end
    end else begin // r==3
      if (c<3)      begin nr=r;   nc=c+1; end
      else          begin nr=3;   nc=3;   end // sink stays at (3,3)
    end
  endfunction

  // Token buffers per PE for drain phase
  logic signed [ACCW-1:0] token [0:3][0:3];
  logic [7:0]             drain_step;

  // drain_step counts 0..15 while out_phase=1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) drain_step <= '0;
    else if (!out_phase) drain_step <= '0;
    else drain_step <= drain_step + 8'd1;
  end

  // Load tokens on first drain cycle; then shift along snake one hop/cycle
  integer rr, cc, nr, nc;
  logic signed [ACCW-1:0] next_token [0:3][0:3];

  always_comb begin
    // default: no movement
    for (rr=0; rr<4; rr++) for (cc=0; cc<4; cc++) next_token[rr][cc] = '0;

    // place moves: each node pushes its token to its "next"
    for (rr=0; rr<4; rr++) begin
      for (cc=0; cc<4; cc++) begin
        next_of(rr,cc,nr,nc);
        next_token[nr][nc] = token[rr][cc];
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (rr=0; rr<4; rr++) for (cc=0; cc<4; cc++) token[rr][cc] <= '0;
    end else if (out_phase) begin
      if (drain_step==8'd0) begin
        // latch all finals at the start of drain
        for (rr=0; rr<4; rr++) for (cc=0; cc<4; cc++) token[rr][cc] <= c_final[rr][cc];
      end else begin
        // shift one hop along the snake
        for (rr=0; rr<4; rr++) for (cc=0; cc<4; cc++) token[rr][cc] <= next_token[rr][cc];
      end
    end
  end

  // Sink emits token at (3,3)
  assign se_valid = out_phase;
  assign se_c     = token[3][3];

endmodule
