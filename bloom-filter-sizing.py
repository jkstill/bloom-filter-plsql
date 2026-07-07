#!/usr/bin/env python3



import math

def optimal_params(n, p):
    m = math.ceil(-n * math.log(p) / (math.log(2) ** 2))  # bits needed
    k = max(1, round((m / n) * math.log(2)))               # hashes to use
    return m, k

print(optimal_params(1_000_000, 0.01))  # about (9_585_059, 7)

if __name__ == "__main__":
    n = int(input("Enter the number of items (n): "))
    p = float(input("Enter the desired false positive probability (p): "))
    m, k = optimal_params(n, p)
    print(f"Optimal number of bits (m): {m}")
    print(f"Optimal number of hash functions (k): {k}")

