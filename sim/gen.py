#!/usr/bin/env python3
import argparse, numpy as np, os

def to_q15(x: np.ndarray) -> np.ndarray:
    y = np.clip(np.round(x * 32768.0), -32768, 32767).astype(np.int16)
    return y

def main():
    p = argparse.ArgumentParser(description="Generate Q1.15 A/B and golden C for (N x 4)*(4 x N)")
    p.add_argument("--N", type=int, choices=[4,8,16], required=True)
    p.add_argument("--seed", type=int, default=0xC0FFEE)
    p.add_argument("--dump_hex", action="store_true", help="Write A_N.hex, B_N.hex, C_N_gold.hex")
    p.add_argument("--outdir", type=str, default=".", help="Output directory")
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)
    A = rng.uniform(-1.0, 1.0, size=(args.N, 4)).astype(np.float64)
    B = rng.uniform(-1.0, 1.0, size=(4, args.N)).astype(np.float64)

    A_q = to_q15(A)
    B_q = to_q15(B)

    # Golden C in fixed-point math: 16x16->32 products, sum (40b safe), round/sat to Q1.15
    prod  = (A_q.astype(np.int32)[..., None] * B_q.astype(np.int32)[None, ...])  # (N,4,4,N)
    sum40 = prod.sum(axis=1).astype(np.int64)                                    # (N,N)
    y     = np.right_shift(sum40 + (1<<14), 15)
    C_q   = np.clip(y, -32768, 32767).astype(np.int16)

    print(f"N={args.N}  A:{A_q.shape}  B:{B_q.shape}  C:{C_q.shape}")

    if args.dump_hex:
        os.makedirs(args.outdir, exist_ok=True)
        with open(os.path.join(args.outdir, f"A_{args.N}.hex"), "w") as fa:
            for i in range(args.N):
                for k in range(4):
                    fa.write(f"{(A_q[i,k] & 0xFFFF):04x}\n")
        with open(os.path.join(args.outdir, f"B_{args.N}.hex"), "w") as fb:
            for k in range(4):
                for j in range(args.N):
                    fb.write(f"{(B_q[k,j] & 0xFFFF):04x}\n")
        with open(os.path.join(args.outdir, f"C_{args.N}_gold.hex"), "w") as fc:
            for i in range(args.N):
                for j in range(args.N):
                    fc.write(f"{(C_q[i,j] & 0xFFFF):04x}\n")

if __name__ == "__main__":
    main()
