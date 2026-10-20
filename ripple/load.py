"""Create the schema and bulk-load a generated dataset into Exasol.

    python -m ripple.load data/demo
"""

import sys
import time
from pathlib import Path

from ripple.db import connect, run_file

RAW = ["stores", "skus", "inventory_book", "cycle_counts", "sales_daily", "accounts", "orders",
       "order_lines", "pick_exceptions", "notify_requests", "returns", "tickets"]
RENAME = {"returns": "PRODUCT_RETURNS"}   # RETURNS is an SQL keyword
GT = {"gt_phantom_events": "PHANTOM_EVENTS", "gt_identity": "ACCOUNT_OWNERS", "gt_tickets": "TICKETS",
      "gt_exposures": "EXPOSURES", "gt_churn": "CHURN"}


def main(data_dir: Path):
    conn = connect()
    print("schema")
    run_file(conn, "00_schema.sql", verbose=False)
    targets = [(t, "RIPPLE_RAW", RENAME.get(t, t.upper())) for t in RAW] + [(f, "RIPPLE_GT", t) for f, t in GT.items()]
    total = time.time()
    for fname, schema, table in targets:
        path = data_dir / f"{fname}.csv"
        t = time.time()
        # IMPORT streams the file over pyexasol's HTTP transport straight into Exasol's parallel loader.
        conn.import_from_file(path, (schema, table), import_params={
            "skip": 1, "column_delimiter": '"',"column_separator": ",", "encoding": "UTF8",
            "null": "", "row_separator": "CRLF" if b"\r\n" in path.open("rb").read(4096) else "LF"})
        n = conn.execute(f"SELECT COUNT(*) AS N FROM {schema}.{table}").fetchval()
        print(f"  {schema}.{table:<16} {n:>10,} rows  {time.time() - t:5.1f}s")
    print(f"loaded in {time.time() - total:.1f}s")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "data/demo"))
