"""
Decode an Ethereum event log using an ABI.

Usage:
    python decode_log.py abi.json log.json
"""

import json
import sys
from eth_abi import decode
from Crypto.Hash import keccak

if len(sys.argv) != 3:
    print("Uso: python decode_log.py <abi.json> <log.json>")
    sys.exit(1)

with open(sys.argv[1]) as f:
    abi = json.load(f)

with open(sys.argv[2]) as f:
    log = json.load(f)

# Find matching event by topic0
topic0 = log["topics"][0]

for item in abi:
    if item.get("type") != "event":
        continue

    sig = f"{item['name']}({','.join(i['type'] for i in item['inputs'])})"
    k = keccak.new(digest_bits=256)
    k.update(sig.encode())
    hash_hex = "0x" + k.hexdigest()

    if hash_hex != topic0:
        continue

    # Matched — decode data params
    params = [i for i in item["inputs"] if not i.get("indexed")]
    types = [p["type"] for p in params]

    data_hex = log["data"][2:]  # remove 0x
    expected = len(types) * 64
    if len(data_hex) < expected:
        full = data_hex[: (len(data_hex) // 64) * 64]
        rest = data_hex[(len(data_hex) // 64) * 64:]
        data_hex = full + rest.zfill(64)

    values = decode(types, bytes.fromhex(data_hex))

    print(f"Event: {sig}\n")
    for p, v in zip(params, values):
        line = f"  {p['name']}: {v}"
        if isinstance(v, int) and v >= 10**15:
            line += f"  ({v / 10**18:.4f} ETH)"
        print(line)

    sys.exit(0)

print("No matching event found in ABI for this log.")
sys.exit(1)
