"""One command from nothing to a scored Ripple ledger in Exasol.

    python -m ripple.build                  # demo scale, seed 42
    python -m ripple.build --scale large    # scale test
"""

import argparse
import time
from pathlib import Path

from generator.generate import SCALES, simulate
from ripple import load, pipeline


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scale", choices=SCALES, default="demo")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--skip-generate", action="store_true", help="reuse CSVs already in data/<scale>")
    args = ap.parse_args()
    out = Path("data") / args.scale
    t = time.time()
    if not args.skip_generate:
        print(f"== generating synthetic world ({args.scale}, seed {args.seed})")
        simulate(SCALES[args.scale], args.seed, out)
    print("== loading into Exasol")
    load.main(out)
    print("== running in-database engines")
    pipeline.main([])
    print(f"== done in {time.time() - t:.0f}s. Start the app with: python -m ripple.app")


if __name__ == "__main__":
    main()
