"""Dev helper: dump EVAL_METRICS and stage timings for the currently loaded world as markdown."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from ripple.db import connect  # noqa: E402

c = connect()
out = ["| Area | Metric | Variant | Value |", "|---|---|---|---|"]
for r in c.execute("SELECT AREA, METRIC, VARIANT, VAL FROM RIPPLE.EVAL_METRICS ORDER BY 1, 2, 3").fetchall():
    out.append(f"| {r['AREA']} | {r['METRIC']} | {r['VARIANT'] or ''} | {float(r['VAL']):,.4f} |")
out += ["", "| Stage | Seconds |", "|---|---|"]
for r in c.execute("SELECT STAGE, SUM(SECONDS) S FROM RIPPLE.RUN_TIMINGS GROUP BY STAGE ORDER BY STAGE").fetchall():
    out.append(f"| {r['STAGE']} | {float(r['S']):.1f} |")
out += ["", "| Table | Rows |", "|---|---|"]
for t in ["INVENTORY_BOOK", "SALES_DAILY", "ACCOUNTS", "ORDERS", "ORDER_LINES", "TICKETS", "PRODUCT_RETURNS"]:
    out.append(f"| {t} | {int(c.execute(f'SELECT COUNT(*) FROM RIPPLE_RAW.{t}').fetchval()):,} |")
print("\n".join(out))
