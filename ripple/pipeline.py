"""Run Ripple's in-database engines in order and record how long each step takes.

    python -m ripple.pipeline            # every stage
    python -m ripple.pipeline 40 50      # only stages whose file starts with 40 or 50
"""

import sys
import time

from ripple.db import SQL_DIR, connect, split_statements

STAGES = sorted(p.name for p in SQL_DIR.glob("[1-9]*.sql"))


def main(only: list[str]):
    conn = connect()
    conn.execute("CREATE SCHEMA IF NOT EXISTS RIPPLE")
    conn.execute("CREATE TABLE IF NOT EXISTS RIPPLE.RUN_TIMINGS (STAGE VARCHAR(40), STEP VARCHAR(200), "
                 "SECONDS DOUBLE, ROWS_AFFECTED DECIMAL(18,0), RUN_AT TIMESTAMP)")
    for stage in STAGES:
        if only and not any(stage.startswith(o) for o in only):
            continue
        print(stage)
        conn.execute("DELETE FROM RIPPLE.RUN_TIMINGS WHERE STAGE = {s}", {"s": stage})
        t_stage = time.time()
        for stmt in split_statements((SQL_DIR / stage).read_text(encoding="utf-8")):
            head = " ".join(l for l in stmt.splitlines() if not l.strip().startswith("--"))
            head = " ".join(head.split())[:180]
            t = time.time()
            st = conn.execute(stmt)
            secs = time.time() - t
            rows = st.rowcount() if hasattr(st, "rowcount") else None
            conn.execute("INSERT INTO RIPPLE.RUN_TIMINGS VALUES ({stage}, {step}, {secs}, {rows}, CURRENT_TIMESTAMP)",
                         {"stage": stage, "step": head, "secs": secs, "rows": rows})
            print(f"  {secs:6.2f}s  {head[:100]}")
        print(f"  = {time.time() - t_stage:.1f}s")
    conn.commit()


if __name__ == "__main__":
    main(sys.argv[1:])
