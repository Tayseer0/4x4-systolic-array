module controller #(
  parameter int AW = 12
)(
  input  logic clk,
  input  logic rst_n,

  input  logic ap_start,
  output logic ap_done,

  // I-mem
  output logic [AW-1:0] i_addr,
  input  logic [31:0]   i_dout,

  // A/B reads
  output logic [AW-1:0] a_addr,
  output logic [AW-1:0] b_addr,
  input  logic [15:0]   a_dout,
  input  logic [15:0]   b_dout,

  // O writes
  output logic [AW-1:0] o_addr,
  output logic          o_we,
  output logic [15:0]   o_din,

  // Array edges
  output logic signed [15:0] west_in [4],
  output logic               west_vld[4],
  output logic signed [15:0] north_in[4],
  output logic               north_vld[4],
  output logic               acc_clr,
  output logic               out_phase,
  input  logic               se_valid,
  input  logic signed [39:0] se_c
);

  // ---- base address helpers ----
  function automatic [AW-1:0] A_base(input int N);
    case (N) 4:12'd0; 8:12'd2048; 16:12'd8192; default:12'd0; endcase
  endfunction
  function automatic [AW-1:0] B_base(input int N);
    case (N) 4:12'd256; 8:12'd4096; 16:12'd12288; default:12'd0; endcase
  endfunction
  function automatic [AW-1:0] O_base(input int N);
    case (N) 4:12'd512; 8:12'd6144; 16:12'd16384; default:12'd0; endcase
  endfunction
  function automatic [AW-1:0] addr_A(input int N, input int i, input int k);
    return A_base(N) + i*4 + k;
  endfunction
  function automatic [AW-1:0] addr_B(input int N, input int k, input int j);
    return B_base(N) + k*N + j;
  endfunction
  function automatic [AW-1:0] addr_O(input int N, input int i, input int j);
    return O_base(N) + i*N + j;
  endfunction

  // ---- state ----
  typedef enum logic [2:0] {IDLE, FETCH_N, CHECK_END, TILE_SETUP, FEED_ADDR, FEED_DATA, WAIT_PROP, DRAIN, NEXT_TILE, NEXT_N, DONE} state_t;
  state_t st, st_n;

  logic [AW-1:0] iptr;
  int N, tiles_per_dim, ti, tj, feed_t;
  logic [4:0] wait_ctr;
  int drain_cnt;

  // FEED pipeline regs for A/B (handle 1-cycle RAM read latency)
  logic signed [15:0] a_pipe[4], b_pipe[4];
  // default outputs
  always_comb begin
    i_addr    = iptr;
    a_addr    = '0; b_addr = '0;
    o_addr    = '0; o_we = 1'b0; o_din = '0;
    acc_clr   = 1'b0; out_phase = 1'b0;
    for (int r=0;r<4;r++) begin
      west_in[r]  = '0; west_vld[r]='0;
      north_in[r] = '0; north_vld[r]='0;
    end
    ap_done = 1'b0;
  end

  // round/saturate Q1.15
  function automatic logic [15:0] round_sat_q15(input logic signed [39:0] x);
    logic signed [39:0] y = x + (40'sd1<<<14);
    logic signed [39:0] s = y >>> 15;
    if (s >  40'sd32767) return 16'sd32767;
    if (s < -40'sd32768) return -16'sd32768;
    return s[15:0];
  endfunction

  // DRAIN mapping (snake to SE): rr,cc for drain_cnt=0..15
  const int rr_lut [16] = '{3,3,3,3, 2,2,2,2, 1,1,1,1, 0,0,0,0};
  const int cc_lut [16] = '{3,2,1,0, 0,1,2,3, 3,2,1,0, 0,1,2,3};

  // seq
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st<=IDLE; iptr<='0; N<=0; ti<=0; tj<=0; feed_t<=0; wait_ctr<='0; drain_cnt<=0;
      for (int r=0;r<4;r++) begin a_pipe[r]<='0; b_pipe[r]<='0; end
    end else begin
      st <= st_n;
      case (st)
        IDLE:       if (ap_start) iptr <= '0;
        CHECK_END:  begin N <= i_dout[15:0]; if (i_dout[15:0]!=0) tiles_per_dim <= (i_dout[15:0]>>2); end
        TILE_SETUP: begin feed_t<=0; wait_ctr<='0; drain_cnt<=0; end
        FEED_ADDR:  ; // issue addresses
        FEED_DATA:  begin
          // latch A/B into feed pipes
          for (int r=0;r<4;r++) a_pipe[r] <= a_dout;
          for (int c=0;c<4;c++) b_pipe[c] <= b_dout;
          if (feed_t<3) feed_t <= feed_t + 1;
        end
        WAIT_PROP:  wait_ctr <= wait_ctr + 5'd1;
        DRAIN:      if (se_valid) drain_cnt <= drain_cnt + 1;
        NEXT_TILE:  ;
        NEXT_N:     iptr <= iptr + 1;
        default: ;
      endcase
    end
  end

  // next-state & drive
  always_comb begin
    st_n = st;
    case (st)
      IDLE:      if (ap_start) st_n = FETCH_N;
      FETCH_N:   st_n = CHECK_END;
      CHECK_END: st_n = (i_dout[15:0]==0) ? DONE : TILE_SETUP;
      TILE_SETUP: begin acc_clr=1'b1; st_n = FEED_ADDR; end

      FEED_ADDR: begin
        // set read addresses for this k=feed_t
        for (int r=0;r<4;r++) a_addr = addr_A(N, ti*4 + r, feed_t);
        for (int c=0;c<4;c++) b_addr = addr_B(N, feed_t, tj*4 + c);
        st_n = FEED_DATA; // consume next cycle
      end

      FEED_DATA: begin
        // drive edges with registered a_pipe/b_pipe from last cycle
        for (int r=0;r<4;r++) begin west_in[r] = a_pipe[r]; west_vld[r]=1'b1; end
        for (int c=0;c<4;c++) begin north_in[c]= b_pipe[c]; north_vld[c]=1'b1; end
        if (feed_t==3) st_n = WAIT_PROP; else st_n = FEED_ADDR;
      end

      WAIT_PROP: st_n = (wait_ctr==5'd10) ? DRAIN : WAIT_PROP;

      DRAIN: begin
        out_phase = 1'b1;
        if (se_valid) begin
          int rr = rr_lut[drain_cnt];
          int cc = cc_lut[drain_cnt];
          o_addr = addr_O(N, ti*4 + rr, tj*4 + cc);
          o_we   = 1'b1;
          o_din  = round_sat_q15(se_c);
          st_n   = (drain_cnt==15) ? NEXT_TILE : DRAIN;
        end
      end

      NEXT_TILE: begin
        if (tj < tiles_per_dim-1) begin tj = tj+1; st_n=TILE_SETUP;
        end else if (ti < tiles_per_dim-1) begin ti = ti+1; tj=0; st_n=TILE_SETUP;
        end else begin st_n = NEXT_N; end
      end

      NEXT_N:    st_n = FETCH_N;
      DONE:      ap_done = 1'b1;
      default: ;
    endcase
  end
endmodule
