// Controller: reads instructions N, streams A/B edges for each 4x4 output tile,
// orchestrates accumulate, then drains results via the SE chain to O_mem.
// Memory maps (example):
//   A_base[4]=0, B_base[4]=256, O_base[4]=512
//   A_base[8]=2048, B_base[8]=4096, O_base[8]=6144
//   A_base[16]=8192, B_base[16]=12288, O_base[16]=16384
module controller #(
  parameter int AW = 12
)(
  input  logic clk,
  input  logic rst_n,

  input  logic ap_start,
  output logic ap_done,

  // I-mem (read-only during run)
  output logic [AW-1:0] i_addr,
  input  logic [31:0]   i_dout,

  // A/B read ports
  output logic [AW-1:0] a_addr,
  output logic [AW-1:0] b_addr,
  input  logic [15:0]   a_dout,
  input  logic [15:0]   b_dout,

  // O write port
  output logic [AW-1:0] o_addr,
  output logic          o_we,
  output logic [15:0]   o_din,

  // Array edges & controls
  output logic signed [15:0] west_in [4],
  output logic               west_vld[4],
  output logic signed [15:0] north_in[4],
  output logic               north_vld[4],
  output logic               acc_clr,
  output logic               out_phase,
  input  logic               se_valid,
  input  logic signed [39:0] se_c
);

  // ----------------- Memory base addresses (hard-coded map) -----------------
  function automatic [AW-1:0] A_base(input int N);
    case (N)
      4  : A_base = 12'd0;
      8  : A_base = 12'd2048;
      16 : A_base = 12'd8192;
      default: A_base = 12'd0;
    endcase
  endfunction
  function automatic [AW-1:0] B_base(input int N);
    case (N)
      4  : B_base = 12'd256;
      8  : B_base = 12'd4096;
      16 : B_base = 12'd12288;
      default: B_base = 12'd0;
    endcase
  endfunction
  function automatic [AW-1:0] O_base(input int N);
    case (N)
      4  : O_base = 12'd512;
      8  : O_base = 12'd6144;
      16 : O_base = 12'd16384;
      default: O_base = 12'd0;
    endcase
  endfunction

  // ----------------- FSM -----------------
  typedef enum logic [2:0] {
    IDLE, FETCH_N, CHECK_END, TILE_SETUP, FEED, WAIT_PROP, DRAIN, NEXT_TILE, NEXT_N, DONE
  } state_t;

  state_t st, st_n;

  // Instruction scan pointer
  logic [AW-1:0] iptr;

  // Current instruction N
  int N;
  int tiles_per_dim; // N/4
  int ti, tj;        // tile indices
  int feed_t;        // 0..3 across K=4
  int drain_cnt;     // 0..15 outputs per tile
  int drain_written; // how many outputs written to O_mem for this tile

  // Cycle counter (for metrics)
  logic [63:0] cycle_counter;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) cycle_counter <= '0;
    else if (st==IDLE && ap_start) cycle_counter <= '0;
    else if (st!=DONE) cycle_counter <= cycle_counter + 64'd1;
  end

  // Default outputs
  always_comb begin
    i_addr     = iptr;
    a_addr     = '0;
    b_addr     = '0;
    o_addr     = '0;
    o_we       = 1'b0;
    o_din      = '0;

    acc_clr    = 1'b0;
    out_phase  = 1'b0;

    for (int r=0;r<4;r++) begin
      west_in[r]  = '0;
      west_vld[r] = 1'b0;
      north_in[r] = '0;
      north_vld[r]= 1'b0;
    end
  end

  // Helpers: fixed-point round & saturate Q1.15 from 40-bit acc
  function automatic logic [15:0] round_sat_q15(input logic signed [39:0] x);
    logic signed [39:0] y;
    logic signed [39:0] add;
    add = 40'sd1 <<< 14; // for rounding before >>15
    y   = x + add;
    // arithmetic shift
    logic signed [39:0] s = y >>> 15;
    // saturate to 16-bit signed
    if (s > 40'sd32767)        round_sat_q15 = 16'sd32767;
    else if (s < -40'sd32768)  round_sat_q15 = -16'sd32768;
    else                       round_sat_q15 = s[15:0];
  endfunction

  // Address generators (A[i][k] row-major, B[k][j] row-major)
  function automatic [AW-1:0] addr_A(input int N, input int i, input int k);
    addr_A = A_base(N) + i*4 + k;
  endfunction
  function automatic [AW-1:0] addr_B(input int N, input int k, input int j);
    addr_B = B_base(N) + k*N + j;
  endfunction
  function automatic [AW-1:0] addr_O(input int N, input int i, input int j);
    addr_O = O_base(N) + i*N + j;
  endfunction

  // Sequential state
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= IDLE;
      iptr <= '0;
      N <= 0;
      ti <= 0; tj <= 0; feed_t <= 0;
      drain_cnt <= 0; drain_written <= 0;
    end else begin
      st <= st_n;
      case (st)
        IDLE: begin
          if (ap_start) iptr <= '0;
        end
        FETCH_N: begin
          // i_dout valid same cycle after addr; keep simple 1-cycle FSM
        end
        CHECK_END: begin
          // latch N
          N <= i_dout[15:0];
          if (i_dout[15:0] != 0) begin
            tiles_per_dim <= (i_dout[15:0] >> 2); // N/4
            ti <= 0; tj <= 0; feed_t <= 0;
          end
        end
        TILE_SETUP: begin
          feed_t <= 0;
          drain_cnt <= 0;
          drain_written <= 0;
        end
        FEED: begin
          // advance feed_t 0..3
          if (feed_t < 3) feed_t <= feed_t + 1;
        end
        WAIT_PROP: begin
          // count some fixed slack cycles (K + (P-1)+(P-1)) ~ 10
        end
        DRAIN: begin
          if (se_valid) begin
            drain_cnt <= drain_cnt + 1;
          end
        end
        NEXT_TILE: begin
          // advance tj/ti
        end
        NEXT_N: begin
          iptr <= iptr + 1;
        end
        default: ;
      endcase
    end
  end

  // Simple wait counter for propagation (10 cycles)
  logic [4:0] wait_ctr;

  // Next state and outputs
  always_comb begin
    st_n   = st;
    ap_done= 1'b0;

    // defaults already set above; now assert per state
    case (st)
      IDLE: begin
        if (ap_start) st_n = FETCH_N;
      end
      FETCH_N: begin
        st_n = CHECK_END;
      end
      CHECK_END: begin
        if (i_dout[15:0] == 0) st_n = DONE;
        else st_n = TILE_SETUP;
      end
      TILE_SETUP: begin
        // Clear accumulators before a tile
        acc_clr = 1'b1;
        // prime counters
        st_n = FEED;
      end
      FEED: begin
        // Feed A rows (ti*4..ti*4+3, k=feed_t) to west; one element per row
        // Feed B cols (k=feed_t, tj*4..tj*4+3) to north; one element per col
        for (int r=0; r<4; r++) begin
          a_addr       = addr_A(N, ti*4 + r, feed_t);
          west_in[r]   = a_dout;
          west_vld[r]  = 1'b1;
        end
        for (int c=0; c<4; c++) begin
          b_addr       = addr_B(N, feed_t, tj*4 + c);
          north_in[c]  = b_dout;
          north_vld[c] = 1'b1;
        end

        if (feed_t == 3) begin
          st_n = WAIT_PROP;
        end
      end
      WAIT_PROP: begin
        // Wait fixed 10 cycles for wavefront to complete accumulations
        if (wait_ctr == 5'd10) begin
          st_n = DRAIN;
        end
      end
      DRAIN: begin
        out_phase = 1'b1; // array emits one c per cycle on SE chain (16 total)
        if (se_valid) begin
          // Write c to O (rounded/saturated)
          // Decide destination index based on drain_cnt order:
          // We map diagonal injection order to a linear row-major within the tile:
          int idx = drain_cnt; // 0..15, we remap to row-major within tile
          int rr = idx / 4;
          int cc = idx % 4;
          o_addr = addr_O(N, ti*4 + rr, tj*4 + cc);
          o_we   = 1'b1;
          o_din  = round_sat_q15(se_c);
          if (drain_cnt == 15) begin
            st_n = NEXT_TILE;
          end
        end
      end
      NEXT_TILE: begin
        // Advance tile indices
        if (tj < tiles_per_dim-1) begin
          tj   = tj + 1;
          st_n = TILE_SETUP;
        end else if (ti < tiles_per_dim-1) begin
          tj   = 0;
          ti   = ti + 1;
          st_n = TILE_SETUP;
        end else begin
          // finished all tiles for this N
          st_n = NEXT_N;
        end
      end
      NEXT_N: begin
        st_n = FETCH_N;
      end
      DONE: begin
        ap_done = 1'b1;
        if (!ap_start) st_n = DONE; // stay done
      end
      default: st_n = IDLE;
    endcase
  end

  // wait counter logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wait_ctr <= '0;
    else if (st!=WAIT_PROP) wait_ctr <= '0;
    else wait_ctr <= wait_ctr + 5'd1;
  end

endmodule
