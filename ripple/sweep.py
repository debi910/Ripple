"""Stress test: rebuild the world at several complaint rates and keep the scores.

Published research says only about 1 in 26 unhappy customers complains, so a
detector that leans on tickets would look good on generous synthetic data and
fail in a real store. This rebuilds the demo world at each rate and stores
every metric in RIPPLE_BENCH.SWEEP (a schema the build never drops), which the
Proof tab charts.

    python -m ripple.sweep                      # 0.02 0.10 0.25, then the default 0.04
    python -m ripple.sweep 0.04 0.30
"""

import sys
import time
from pathlib import Path

from generator.generate import SCALES, TICKET_RATE, simulate
from ripple import load, pipeline
from ripple.db import connect


def main(rates: list[float]):
    conn = connect()
    conn.execute("CREATE SCHEMA IF NOT EXISTS RIPPLE_BENCH")
    conn.execute("CREATE TABLE IF NOT EXISTS RIPPLE_BENCH.SWEEP (TICKET_RATE DOUBLE, AREA VARCHAR(30), "
                 "METRIC VARCHAR(80), VARIANT VARCHAR(30), VAL DOUBLE, RUN_AT TIMESTAMP)")
    for rate in rates:
        t = time.time()
        print(f"== ticket rate {rate}")
        out = Path("data") / f"sweep_{rate}"
        simulate(SCALES["demo"], 42, out, rate)
        load.main(out)
        pipeline.main([])
        conn = connect()
        conn.execute("DELETE FROM RIPPLE_BENCH.SWEEP WHERE TICKET_RATE = {r}", {"r": rate})
        conn.execute("INSERT INTO RIPPLE_BENCH.SWEEP SELECT {r}, AREA, METRIC, VARIANT, VAL, CURRENT_TIMESTAMP "
                     "FROM RIPPLE.EVAL_METRICS", {"r": rate})
        conn.commit()
        print(f"== ticket rate {rate} done in {time.time() - t:.0f}s")


if __name__ == "__main__":
    # The default rate runs last, so the database is left holding the standard world.
    main([float(x) for x in sys.argv[1:]] or [0.02, 0.10, 0.25, TICKET_RATE])
