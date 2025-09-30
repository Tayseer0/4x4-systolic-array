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
