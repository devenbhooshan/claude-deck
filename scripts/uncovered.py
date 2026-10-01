#!/usr/bin/env python3
"""Prints the source of every code region tests never executed, from `llvm-cov export` JSON on stdin.
Usage: xcrun llvm-cov export -format=text RUNNER -instr-profile=PROFDATA | scripts/uncovered.py [path-filter]"""
import json, sys

want = sys.argv[1] if len(sys.argv) > 1 else ""
data = json.load(sys.stdin)["data"][0]
hits = {}
for fn in data["functions"]:
    for line_start, col_start, line_end, col_end, count, file_id, _, kind in fn["regions"]:
        path = fn["filenames"][file_id]
        if count == 0 and kind == 0 and want in path and "/Core/" in path:
            hits.setdefault(path, set()).add(line_start)
for path in sorted(hits):
    lines = open(path).read().split("\n")
    print(path.split("/Sources/")[-1] + ":")
    for n in sorted(hits[path]):
        print(f"  {n:4} | {lines[n - 1].strip()}")
