#!/usr/bin/env python3
"""Generate XOR-obfuscated byte arrays for Secrets.swift.

Usage:
    python3 scripts/obfuscate_secrets.py

Paste the output into Sources/NoCornyTracer/Secrets.swift.
"""
import os

secrets = {
    "proxyBaseURL": input("Enter proxyBaseURL: ").strip(),
    "appSecret": input("Enter appSecret: ").strip(),
    "dropboxAppKey": input("Enter dropboxAppKey: ").strip(),
}

key = list(os.urandom(64))

print("\n// --- Paste into Secrets.swift ---\n")
print("private static let k: [UInt8] = [")
for i in range(0, len(key), 16):
    chunk = ", ".join(str(b) for b in key[i:i+16])
    print(f"    {chunk},")
print("]\n")

for name, value in secrets.items():
    value_bytes = value.encode("utf-8")
    xored = [b ^ key[i % len(key)] for i, b in enumerate(value_bytes)]
    lines = []
    for i in range(0, len(xored), 16):
        chunk = ", ".join(str(b) for b in xored[i:i+16])
        lines.append(f"         {chunk}")
    joined = ",\n".join(lines)
    print(f"static var {name}: String {{")
    print(f"    xor([{joined[9:]}])")
    print("}\n")
