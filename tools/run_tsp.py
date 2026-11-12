#!/usr/bin/env python3
"""Runs the mock TSP and prints the address the iPhone should use.

Usage:
    python3 tools/run_tsp.py
    python3 tools/run_tsp.py --port 9000 --key-ttl 1800
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server"))

from mock_tsp import main as tsp_main  # noqa: E402

if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--key-ttl", type=int, default=3600)
    parser.add_argument("--verbose", action="store_true")
    args, _ = parser.parse_known_args()

    sys.argv = ["mock_tsp.py",
                "--host", args.host,
                "--port", str(args.port),
                "--key-ttl", str(args.key_ttl)]
    if args.verbose:
        sys.argv.append("--verbose")
    sys.exit(tsp_main())
