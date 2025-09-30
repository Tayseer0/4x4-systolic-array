`timescale 1ns/1ps
module tb_system;
  timeunit 1ns; timeprecision 1ps;

  // ---------------- DUT I/O ----------------
  logic        clk=0, rst_n=0;
  logic [31:0] addrA, addrB, addrI, addrO;
  logic        enA, enB, enI;
  logic [15:0] dataA, dataB;
  logic [31:0] dataI;
  logic [15:0] dataO;
  logic        ap_start, ap_done;

  // Clock: 1ns period (1 GHz sim tick; arbitrary)
  always #0.5 clk = ~clk;

  // Device Under Test
  systolic_top dut(
    .clk, .rst_n,
    .addrA, .enA, .dataA,
    .addrB, .enB, .dataB,
    .addrI, .enI, .dataI,
    .addrO, .dataO,
    .ap_start, .ap_done
  );

  // ---------------- Helpers ----------------

  // Base addresses (MATCH controller.sv)
  function automatic int A_base(input int N);
    case(N) 4: A_base=0; 8: A_base=2048; 16: A_base=8192; default: A_base=0; endcase
  endfunction
  function automatic int B_base(input int N);
    case(N) 4: B_base=256; 8: B_base=4096; 16: B_base=12288; default: B_base=0; endcase
  endfunction
  function automatic int O_base(input int N);
    case(N) 4: O_base=512; 8: O_base=6144; 16: O_base=16384; default: O_base=0; endcase
  endfunction

  // Load 16-bit hex file into a flat TB array
  task automatic load_hex_16(input string fname, output logic [15:0] arr[], input int expected_len);
    int ok;
    arr = new[expected_len];
    ok = $readmemh(fname, arr);
    if (ok == 0) begin
      $error("Failed to read hex file %s", fname);
      $finish;
    end
  endtask

  // Write A to DUT memory via top ports (row-major A[i,k], length N*4)
  task automatic write_A_from_arr(input int N, input logic [15:0] A_flat[]);
    for (int i=0;i<N;i++) begin
      for (int k=0;k<4;k++) begin
        addrA = A_base(N) + i*4 + k;
        dataA = A_flat[i*4 + k];
        enA = 1; @(posedge clk); enA = 0; @(posedge clk);
      end
    end
  endtask

  // Write B to DUT memory via top ports (row-major B[k,j], length 4*N)
  task automatic write_B_from_arr(input int N, input logic [15:0] B_flat[]);
    for (int k=0;k<4;k++) begin
      for (int j=0;j<N;j++) begin
        addrB = B_base(N) + k*N + j;
        dataB = B_flat[k*N + j];
        enB = 1; @(posedge clk); enB = 0; @(posedge clk);
      end
    end
  endtask

  // Read O from DUT memory via top ports into flat array (row-major C[i,j], length N*N)
  task automatic read_O_into_arr(input int N, output logic [15:0] C_flat[]);
    C_flat = new[N*N];
    for (int i=0;i<N;i++) begin
      for (int j=0;j<N;j++) begin
        addrO = O_base(N) + i*N + j;
        @(posedge clk); // synchronous read (spram returns next cycle)
        @(posedge clk);
        C_flat[i*N + j] = dataO;
      end
    end
  endtask

  // Compare two 16-bit arrays; return mismatch count
  function automatic int compare_16(input logic [15:0] got[], input logic [15:0] gold[]);
    int errs=0;
    if (got.size() != gold.size()) begin
      $error("Size mismatch: got=%0d gold=%0d", got.size(), gold.size());
      return 1<<30;
    end
    for (int i=0;i<got.size();i++) if (got[i] !== gold[i]) errs++;
    return errs;
  endfunction

  // Write instructions [4,8,16,0] via top ports
  task automatic write_instructions();
    int ip=0;
    logic [31:0] arr_instr [4] = '{32'd4,32'd8,32'd16,32'd0};
    foreach (arr_instr[ii]) begin
      addrI = ip;
      dataI = arr_instr[ii];
      enI   = 1; @(posedge clk); enI = 0; @(posedge clk);
      ip++;
    end
  endtask

  // ---------------- Test sequence ----------------

  initial begin
    // Reset
    enA=0; enB=0; enI=0; ap_start=0;
    repeat (8) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // Load hex from Python generator
    logic [15:0] A4[];  logic [15:0] B4[];  logic [15:0] C4_gold[];
    logic [15:0] A8[];  logic [15:0] B8[];  logic [15:0] C8_gold[];
    logic [15:0] A16[]; logic [15:0] B16[]; logic [15:0] C16_gold[];

    load_hex_16("A_4.hex",   A4,  4*4);
    load_hex_16("B_4.hex",   B4,  4*4);
    load_hex_16("C_4_gold.hex",  C4_gold,  4*4);

    load_hex_16("A_8.hex",   A8,  8*4);
    load_hex_16("B_8.hex",   B8,  4*8);
    load_hex_16("C_8_gold.hex",  C8_gold,  8*8);

    load_hex_16("A_16.hex",  A16, 16*4);
    load_hex_16("B_16.hex",  B16, 4*16);
    load_hex_16("C_16_gold.hex", C16_gold, 16*16);

    // Preload DUT memories via top write ports
    write_A_from_arr(4,  A4);  write_B_from_arr(4,  B4);
    write_A_from_arr(8,  A8);  write_B_from_arr(8,  B8);
    write_A_from_arr(16, A16); write_B_from_arr(16, B16);

    // Write instruction memory [4,8,16,0]
    write_instructions();

    // Start
    @(posedge clk); ap_start = 1; @(posedge clk); ap_start = 0;

    // Wait done
    wait (ap_done == 1);

    // Read back C from O-mem and compare to Python golden
    logic [15:0] C4_d[], C8_d[], C16_d[];
    read_O_into_arr(4,   C4_d);
    read_O_into_arr(8,   C8_d);
    read_O_into_arr(16,  C16_d);

    int e4   = compare_16(C4_d,  C4_gold);
    int e8   = compare_16(C8_d,  C8_gold);
    int e16  = compare_16(C16_d, C16_gold);

    if (e4==0)  $display("PASS N=4   err=%0d",  e4);  else $display("FAIL N=4   err=%0d",  e4);
    if (e8==0)  $display("PASS N=8   err=%0d",  e8);  else $display("FAIL N=8   err=%0d",  e8);
    if (e16==0) $display("PASS N=16  err=%0d",  e16); else $display("FAIL N=16  err=%0d", e16);

    $finish;
  end

  // Optional waves for debug / VCD→SAIF flow
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_system);
  end

endmodule
