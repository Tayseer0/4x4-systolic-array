`timescale 1ns/1ps
module tb_system;
  timeunit 1ns; timeprecision 1ps;

  // DUT I/O
  logic        clk=0, rst_n=0;
  logic [31:0] addrA, addrB, addrI, addrO;
  logic        enA, enB, enI;
  logic [15:0] dataA, dataB;
  logic [31:0] dataI;
  logic [15:0] dataO;
  logic        ap_start, ap_done;

  // Clock
  always #1 clk = ~clk; // 500 MHz sim tick (arbitrary)

  // DUT
  systolic_top dut(
    .clk, .rst_n,
    .addrA, .enA, .dataA,
    .addrB, .enB, .dataB,
    .addrI, .enI, .dataI,
    .addrO, .dataO,
    .ap_start, .ap_done
  );

  // --- Test params ---
  int Ns [3] = '{4,8,16};

  // Fixed-point helpers (Q1.15)
  function automatic shortint to_q15(real x);
    real y = x * 32768.0;
    if (y >  32767.0) y =  32767.0;
    if (y < -32768.0) y = -32768.0;
    to_q15 = shortint'($rtoi(y));
  endfunction

  function automatic shortint q15_round_sat(longint signed acc40);
    longint signed y = acc40 + (1<<14); // round before >>15
    longint signed s = y >>> 15;
    if (s >  32767) return shortint'(32767);
    if (s < -32768) return shortint'(-32768);
    return shortint'(s[15:0]);
  endfunction

  // Golden compute for Nx4 * 4xN (integer math)
  task automatic golden_mmm(input int N,
                            input shortint A_flat[], // length N*4
                            input shortint B_flat[], // length 4*N
                            output shortint C_flat[] // length N*N
                            );
    longint signed sum;
    for (int i=0;i<N;i++) begin
      for (int j=0;j<N;j++) begin
        sum = 0;
        for (int k=0;k<4;k++) begin
          int a = A_flat[i*4 + k];
          int b = B_flat[k*N + j];
          // 16x16 -> 32, accumulate to 40
          sum += (longint'(a) * longint'(b));
        end
        C_flat[i*N + j] = q15_round_sat(sum);
      end
    end
  endtask

  // Write helpers
  task automatic write_A(input int N, input shortint A_flat[]);
    for (int i=0;i<N;i++) begin
      for (int k=0;k<4;k++) begin
        addrA = A_base(N) + i*4 + k;
        dataA = A_flat[i*4 + k][15:0];
        enA   = 1; @(posedge clk); enA = 0; @(posedge clk);
      end
    end
  endtask
  task automatic write_B(input int N, input shortint B_flat[]);
    for (int k=0;k<4;k++) begin
      for (int j=0;j<N;j++) begin
        addrB = B_base(N) + k*N + j;
        dataB = B_flat[k*N + j][15:0];
        enB   = 1; @(posedge clk); enB = 0; @(posedge clk);
      end
    end
  endtask

  // Read O into array
  task automatic read_O(input int N, output shortint C_flat[]);
    for (int i=0;i<N;i++) begin
      for (int j=0;j<N;j++) begin
        addrO = O_base(N) + i*N + j;
        @(posedge clk);
        C_flat[i*N + j] = dataO;
      end
    end
  endtask

  // Bases (must match controller)
  function automatic int A_base(input int N);
    case(N) 4: A_base=0; 8: A_base=2048; 16: A_base=8192; default: A_base=0; endcase
  endfunction
  function automatic int B_base(input int N);
    case(N) 4: B_base=256; 8: B_base=4096; 16: B_base=12288; default: B_base=0; endcase
  endfunction
  function automatic int O_base(input int N);
    case(N) 4: O_base=512; 8: O_base=6144; 16: O_base=16384; default: O_base=0; endcase
  endfunction

  // Random but deterministic data
  task automatic gen_mats(input int N, output shortint A_flat[], output shortint B_flat[]);
    int seed = 32'hC0FFEE;
    for (int i=0;i<N;i++) begin
      for (int k=0;k<4;k++) begin
        seed = $urandom(seed);
        real v = (seed%2001 - 1000)/1000.0; // [-1,1]
        A_flat[i*4 + k] = to_q15(v);
      end
    end
    for (int k=0;k<4;k++) begin
      for (int j=0;j<N;j++) begin
        seed = $urandom(seed+7);
        real v = (seed%2001 - 1000)/1000.0;
        B_flat[k*N + j] = to_q15(v);
      end
    end
  endtask

  // Instruction write
  task automatic write_I();
    int ip=0;
    foreach (Ns[ii]) begin
      addrI = ip; dataI = Ns[ii]; enI=1; @(posedge clk); enI=0; @(posedge clk); ip++;
    end
    // terminator 0
    addrI = ip; dataI = 32'd0; enI=1; @(posedge clk); enI=0; @(posedge clk);
  endtask

  // Reset
  initial begin
    enA=0; enB=0; enI=0; ap_start=0;
    repeat(10) @(posedge clk); rst_n=1;
  end

  // Main test
  initial begin
    shortint A4 [4*4],  B4 [4*4],   C4_g [4*4],   C4_d [4*4];
    shortint A8 [8*4],  B8 [4*8],   C8_g [8*8],   C8_d [8*8];
    shortint A16[16*4], B16[4*16],  C16_g[16*16], C16_d[16*16];

    // Generate and preload memories
    gen_mats(4,  A4,  B4);  golden_mmm(4,  A4,  B4,  C4_g);
    gen_mats(8,  A8,  B8);  golden_mmm(8,  A8,  B8,  C8_g);
    gen_mats(16, A16, B16); golden_mmm(16, A16, B16, C16_g);

    // Write A/B
    write_A(4,  A4);  write_B(4,  B4);
    write_A(8,  A8);  write_B(8,  B8);
    write_A(16, A16); write_B(16, B16);

    // Write instructions [4,8,16,0]
    write_I();

    // Start
    @(posedge clk); ap_start=1; @(posedge clk); ap_start=0;

    // Wait for done
    wait (ap_done==1);

    // Read outputs & compare
    read_O(4,  C4_d);
    read_O(8,  C8_d);
    read_O(16, C16_d);

    int err4=0, err8=0, err16=0;
    for (int i=0;i<16;i++) if (C4_d[i]  !== C4_g[i])  err4++;
    for (int i=0;i<64;i++) if (C8_d[i]  !== C8_g[i])  err8++;
    for (int i=0;i<256;i++)if (C16_d[i] !== C16_g[i]) err16++;

    if (err4==0)  $display("PASS N=4   err=%0d",  err4);  else $display("FAIL N=4   err=%0d",err4);
    if (err8==0)  $display("PASS N=8   err=%0d",  err8);  else $display("FAIL N=8   err=%0d",err8);
    if (err16==0) $display("PASS N=16  err=%0d", err16); else $display("FAIL N=16  err=%0d",err16);

    $finish;
  end

  // Optional waves
  initial begin
    $dumpfile("waves.vcd"); $dumpvars(0, tb_system);
  end
endmodule
