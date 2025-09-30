# 4×4 Systolic Array (Q1.15) — Design Notes

## Block Diagram
- Memories: A (N×4), B (4×N), I (instr list), O (N×N)
- Controller: reads N, tiles N/4×N/4 tiles, drives edges, drain
- Array: 4×4 PEs; A from west rows, B from north cols; SE-diagonal output chain

## Fixed-Point
- In: Q1.15 (16b signed)
- Prod: 32b; Acc: 40b; Out: round/sat to Q1.15

## Memory Map
- A_base{4,8,16} = {0, 2048, 8192}
- B_base{4,8,16} = {256, 4096, 12288}
- O_base{4,8,16} = {512, 6144, 16384}

## Schedule (per tile)
FEED t=0..3 → WAIT 10 cycles → DRAIN 16 cycles (one SE emission per cycle)
