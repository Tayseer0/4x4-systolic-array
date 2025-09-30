// Top-level wrapper: memories + controller + array
module systolic_top (
  input  logic        clk,
  input  logic        rst_n,

  // load Data A (write-only before start)
  input  logic [31:0] addrA,
  input  logic        enA,
  input  logic [15:0] dataA,

  // load Data B (write-only before start)
  input  logic [31:0] addrB,
  input  logic        enB,
  input  logic [15:0] dataB,

  // load Instruction memory (vector of sizes, ending with 0)
  input  logic [31:0] addrI,
  input  logic        enI,
  input  logic [31:0] dataI,

  // read Output memory (post-run)
  input  logic [31:0] addrO,
  output logic [15:0] dataO,

  // control
  input  logic        ap_start,   // pulse
  output logic        ap_done     // level
);
  // -------- Parameters (depths sized generously) --------
  localparam int AW = 12; // 4K entries per memory (16-bit A/B/O, 32-bit I via two halves or 32 DW)
  // Memories (simple single-port synchronous)
  logic [15:0] memA_dout, memB_dout, memO_dout;
  logic [31:0] memI_dout;

  // Internal ports driven by controller during run
  logic [AW-1:0] A_addr_r, B_addr_r, O_addr_w, I_addr_r;
  logic          O_we_w;
  logic [15:0]   O_din_w;

  // Address muxing: external writes before start; during run controller drives
  // For simplicity, we share the single port:
  // - Writes: from external enA/enB/enI (pre-load)
  // - Reads: from controller (during run)
  // We rely on protocol: TB finishes writes before ap_start.

  // A memory
  spram #(.AW(AW), .DW(16)) u_memA (
    .clk  (clk),
    .addr (enA ? addrA[AW-1:0] : A_addr_r),
    .we   (enA),
    .din  (dataA),
    .dout (memA_dout)
  );

  // B memory
  spram #(.AW(AW), .DW(16)) u_memB (
    .clk  (clk),
    .addr (enB ? addrB[AW-1:0] : B_addr_r),
    .we   (enB),
    .din  (dataB),
    .dout (memB_dout)
  );

  // I memory (32-bit wide for convenience)
  spram #(.AW(AW), .DW(32)) u_memI (
    .clk  (clk),
    .addr (enI ? addrI[AW-1:0] : I_addr_r),
    .we   (enI),
    .din  (dataI),
    .dout (memI_dout)
  );

  // O memory (read-only externally; written by controller)
  spram #(.AW(AW), .DW(16)) u_memO (
    .clk  (clk),
    .addr (O_we_w ? O_addr_w : addrO[AW-1:0]),
    .we   (O_we_w),
    .din  (O_din_w),
    .dout (memO_dout)
  );
  assign dataO = memO_dout;

  // ---------- Array edges + controls ----------
  logic signed [15:0] west_in [4];
  logic               west_vld[4];
  logic signed [15:0] north_in[4];
  logic               north_vld[4];

  logic               acc_clr, out_phase;
  logic               se_valid;
  logic signed [39:0] se_c;

  array4x4 #(.BW(16), .ACCW(40)) u_array (
    .clk, .rst_n,
    .west_in, .west_vld,
    .north_in, .north_vld,
    .acc_clr, .out_phase,
    .se_valid, .se_c
  );

  // ---------- Controller ----------
  controller #(.AW(AW)) u_ctrl (
    .clk, .rst_n,
    .ap_start, .ap_done,

    .i_addr (I_addr_r),
    .i_dout (memI_dout),

    .a_addr (A_addr_r),
    .b_addr (B_addr_r),
    .a_dout (memA_dout),
    .b_dout (memB_dout),

    .o_addr (O_addr_w),
    .o_we   (O_we_w),
    .o_din  (O_din_w),

    .west_in, .west_vld,
    .north_in, .north_vld,
    .acc_clr, .out_phase,
    .se_valid, .se_c
  );

endmodule
