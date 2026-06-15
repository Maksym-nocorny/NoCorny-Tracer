#!/usr/bin/env python3
"""Generate XOR-obfuscated byte arrays for Secrets.swift.

Usage:
    python3 scripts/obfuscate_secrets.py [dropboxAppKey]

If dropboxAppKey is passed as an argument it is used directly (scriptable);
otherwise the script prompts for it interactively. Quote the argument if it
contains shell-special characters.

Paste the output into Sources/NoCornyTracer/Secrets.swift.
"""
import os
import sys

# Honor a command-line argument when provided, else fall back to the prompt.
# An explicitly-passed empty string ("") is treated as the (empty) value, not a prompt.
dropbox_app_key = sys.argv[1] if len(sys.argv) > 1 else input("Enter dropboxAppKey: ").strip()

secrets = {
    "dropboxAppKey": dropbox_app_key,
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
