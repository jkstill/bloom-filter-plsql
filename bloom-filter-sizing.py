#!/usr/bin/env python3

import argparse
import math

def optimal_params(n, p):
    m = math.ceil(-n * math.log(p) / (math.log(2) ** 2))  # bits needed
    k = max(1, round((m / n) * math.log(2)))               # hashes to use
    return m, k

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compute optimal Bloom filter bit-vector size (m) and hash count (k).")
    parser.add_argument("-n", "--num-items", type=int, default=1_000_000, help="expected number of items (default: 1000000)")
    parser.add_argument("-p", "--false-positive-rate", type=float, default=0.01, help="desired false positive probability (default: 0.01)")
    args = parser.parse_args()

    m, k = optimal_params(args.num_items, args.false_positive_rate)
    print(f"Optimal number of bits (m): {m}")
    print(f"Optimal number of hash functions (k): {k}")
