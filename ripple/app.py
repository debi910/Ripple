"""Ripple web app: a thin FastAPI layer over Exasol. Every number is a live SQL query.

    python -m ripple.app            # http://localhost:8765  (RIPPLE_PORT to change)
"""

import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from ripple.db import connect

WEB = Path(__file__).resolve().parent.parent / "web"
app = FastAPI(title="Ripple")
_conn, _lock = None, threading.Lock()


def q(sql: str, params: dict | None = None):
    """Run a query; return rows plus how long Exasol took, so the UI can show it."""
    global _conn
    with _lock:
        if _conn is None or _conn.is_closed:
            _conn = connect()
        t = time.perf_counter()
        st = _conn.execute(sql, params or {})
        rows = st.fetchall()
        ms = (time.perf_counter() - t) * 1000
        # Large DECIMALs arrive as strings over the websocket; hand JSON real numbers.
        numeric = {name for name, col in st.columns().items() if col["type"] in ("DECIMAL", "DOUBLE")}
    return [{k.lower(): (float(v) if k in numeric and isinstance(v, str) else v) for k, v in r.items()} for r in rows], ms


def reply(**parts):
    out, total = {}, 0.0
    for name, (rows, ms) in parts.items():
        out[name] = rows
        total += ms
    out["query_ms"] = round(total, 1)
    return JSONResponse(out, headers={"Cache-Control": "no-store"})


@app.get("/api/overview")
def overview():
    return reply(
        totals=q("""
            SELECT COUNT(*) AS episodes, SUM(CUSTOMERS_HIT) AS customers_hit,
                   SUM(LOST_SALE_INR) AS lost_sale, SUM(SUBSTITUTION_INR) AS substitution,
                   SUM(RETURNS_INR) AS returns_inr, SUM(TICKETS_INR) AS tickets_inr, SUM(CHURN_INR) AS churn,
                   SUM(TOTAL_INR) AS total, SUM(RETURNS_N) AS returns_n, SUM(TICKETS_N) AS tickets_n,
                   MIN(ONSET_DATE) AS first_day, MAX(LAST_DATE) AS last_day
            FROM RIPPLE.EPISODE_BILL"""),
        flow=q("""
            SELECT (SELECT COUNT(*) FROM RIPPLE.EPISODE_EXPOSURES) AS lines_hit,
                   (SELECT COUNT(*) FROM RIPPLE.EPISODE_EXPOSURES WHERE LINE_STATUS = 'missing') AS missing,
                   (SELECT COUNT(*) FROM RIPPLE.EPISODE_EXPOSURES WHERE LINE_STATUS = 'substituted') AS substituted,
                   (SELECT COUNT(*) FROM RIPPLE.LEDGER WHERE ENTRY = 'return') AS returns_n,
                   (SELECT COUNT(*) FROM RIPPLE.LEDGER WHERE ENTRY = 'ticket') AS tickets_n,
                   (SELECT SUM(ce.ATT_LOST_RATE) FROM (
                        SELECT l.PERSON_ID, MAX(c.ATT_LOST_RATE) AS ATT_LOST_RATE FROM RIPPLE.LEDGER l
                        JOIN RIPPLE.CAUSAL_EFFECTS c ON c.KIND = l.SOURCE_REF WHERE l.ENTRY = 'churn_risk'
                        GROUP BY l.PERSON_ID) ce) AS customers_lost
            FROM DUAL"""),
        by_category=q("""
            SELECT CATEGORY AS category, COUNT(*) AS episodes, SUM(LOST_SALE_INR) AS lost_sale, SUM(TOTAL_INR) AS total
            FROM RIPPLE.EPISODE_BILL GROUP BY CATEGORY ORDER BY total DESC"""),
        top=q("""
            SELECT EPISODE_ID AS id, STORE_NAME AS store, SKU_NAME AS sku, CATEGORY AS category,
                   ONSET_DATE AS onset, ALERT_DATE AS alert, DAYS_OPEN AS days, CUSTOMERS_HIT AS customers,
                   LOST_SALE_INR AS lost_sale, TOTAL_INR AS total
            FROM RIPPLE.EPISODE_BILL ORDER BY TOTAL_INR DESC LIMIT 12"""),
    )


@app.get("/api/stores")
def stores():
    return reply(stores=q("SELECT STORE_ID AS id, NAME AS name, CITY AS city FROM RIPPLE_RAW.STORES ORDER BY NAME"),
                 days=q("SELECT MIN(D) AS first_day, MAX(D) AS last_day FROM RIPPLE.PHANTOM_SCORES"))


@app.get("/api/recount")
def recount(as_of: str, store_id: int | None = None, limit: int = 25):
    """The recount list as it would have looked on the morning of `as_of`, using only data up to then."""
    rows = q("""
        WITH open_now AS (
            SELECT s.STORE_ID, s.SKU_ID, s.P_PHANTOM, s.LAMBDA_HAT, s.LLR_SALES, s.LLR_OMS, s.LLR_PICK, s.LLR_TICKETS
            FROM RIPPLE.PHANTOM_SCORES s
            WHERE s.VARIANT = 'all' AND s.D = CAST({as_of} AS DATE) AND s.P_PHANTOM >= 0.3
              AND ({store_id} IS NULL OR s.STORE_ID = {store_id})
        ), cadence AS (
            SELECT c.STORE_ID, c.SKU_ID, MAX(c.COUNT_DATE) AS LAST_COUNT
            FROM RIPPLE_RAW.CYCLE_COUNTS c JOIN open_now o ON o.STORE_ID = c.STORE_ID AND o.SKU_ID = c.SKU_ID
            WHERE c.COUNT_DATE <= CAST({as_of} AS DATE) GROUP BY c.STORE_ID, c.SKU_ID
        )
        SELECT o.STORE_ID AS store_id, st.NAME AS store, o.SKU_ID AS sku_id, s.NAME AS sku, s.CATEGORY AS category,
               o.P_PHANTOM AS p, o.LAMBDA_HAT AS demand,
               GREATEST(COALESCE(cd.LAST_COUNT, CAST({as_of} AS DATE)) + COALESCE(cc.TYPICAL_GAP, 35) - CAST({as_of} AS DATE), 1) AS days_to_count,
               o.P_PHANTOM * o.LAMBDA_HAT * cpe.INR_PER_SHORT_LINE
                 * GREATEST(COALESCE(cd.LAST_COUNT, CAST({as_of} AS DATE)) + COALESCE(cc.TYPICAL_GAP, 35) - CAST({as_of} AS DATE), 1) AS saving,
               o.LLR_SALES AS llr_sales, o.LLR_OMS AS llr_oms, o.LLR_PICK AS llr_pick, o.LLR_TICKETS AS llr_tickets,
               (SELECT MIN(g.EPISODE_ID) FROM RIPPLE.EPISODES g WHERE g.STORE_ID = o.STORE_ID AND g.SKU_ID = o.SKU_ID
                  AND CAST({as_of} AS DATE) BETWEEN g.ONSET_DATE AND g.LAST_DATE) AS episode_id
        FROM open_now o
        JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = o.SKU_ID
        JOIN RIPPLE_RAW.STORES st ON st.STORE_ID = o.STORE_ID
        LEFT JOIN cadence cd ON cd.STORE_ID = o.STORE_ID AND cd.SKU_ID = o.SKU_ID
        LEFT JOIN RIPPLE.COUNT_CADENCE cc ON cc.STORE_ID = o.STORE_ID AND cc.SKU_ID = o.SKU_ID
        LEFT JOIN RIPPLE.COST_PER_EXPOSURE cpe ON cpe.CATEGORY = s.CATEGORY
        ORDER BY saving DESC NULLS LAST LIMIT {limit!d}""", {"as_of": as_of, "store_id": store_id, "limit": limit})
    return reply(items=rows)


@app.get("/api/series")
def series(store_id: int, sku_id: int, start: str, end: str):
    return reply(days=q("""
        SELECT d.D AS d, d.BOOK_EOD AS book, d.UNITS AS units, d.SHORT_LINES AS shorts, d.PICK_EX AS picks,
               d.STOCK_TICKETS AS tickets, s.P_PHANTOM AS p, s.LAMBDA_HAT AS lam,
               CASE WHEN d.COUNT_BOOK IS NOT NULL THEN 1 ELSE 0 END AS counted
        FROM RIPPLE.SKU_DAY d
        LEFT JOIN RIPPLE.PHANTOM_SCORES s ON s.VARIANT = 'all' AND s.STORE_ID = d.STORE_ID AND s.SKU_ID = d.SKU_ID AND s.D = d.D
        WHERE d.STORE_ID = {store_id} AND d.SKU_ID = {sku_id} AND d.D BETWEEN CAST({start} AS DATE) AND CAST({end} AS DATE)
        ORDER BY d.D""", {"store_id": store_id, "sku_id": sku_id, "start": start, "end": end}),
        quotes=q("""
        SELECT TICKET_DATE AS d, INTENT AS intent, BODY AS body, LINKED_BY AS linked_by FROM RIPPLE.TICKETS_ENRICHED
        WHERE STORE_ID = {store_id} AND SKU_ID = {sku_id} AND STOCK_SIGNAL
          AND TICKET_DATE BETWEEN CAST({start} AS DATE) AND CAST({end} AS DATE)
        ORDER BY TICKET_DATE DESC LIMIT 6""", {"store_id": store_id, "sku_id": sku_id, "start": start, "end": end}))


@app.get("/api/episode/{episode_id}")
def episode(episode_id: int):
    head, ms = q("SELECT * FROM RIPPLE.EPISODE_BILL WHERE EPISODE_ID = {e}", {"e": episode_id})
    if not head:
        raise HTTPException(404, "no such episode")
    people = q("""
        WITH p AS (
            SELECT l.PERSON_ID, SUM(l.INR) AS INR,
                   SUM(CASE WHEN l.ENTRY = 'return' THEN 1 ELSE 0 END) AS RETURNS_N,
                   SUM(CASE WHEN l.ENTRY = 'ticket' THEN 1 ELSE 0 END) AS TICKETS_N
            FROM RIPPLE.LEDGER l WHERE l.EPISODE_ID = {e} GROUP BY l.PERSON_ID
        )
        SELECT p.PERSON_ID AS person_id, p.INR AS inr, p.RETURNS_N AS returns_n, p.TICKETS_N AS tickets_n,
               COUNT(a.ACCOUNT_ID) AS accounts,
               LISTAGG(DISTINCT ak.CHANNEL, ', ') WITHIN GROUP (ORDER BY ak.CHANNEL) AS channels,
               MIN(acc.DISPLAY_NAME) AS name,
               MAX(CASE WHEN o.LAST_ORDER < (SELECT MAX(ORDER_DATE) FROM RIPPLE.ORDERS_P) - 21 THEN 1 ELSE 0 END) AS gone_quiet
        FROM p
        JOIN RIPPLE.ACCOUNT_PERSON a ON a.PERSON_ID = p.PERSON_ID
        JOIN RIPPLE.ACCOUNT_KEYS ak ON ak.ACCOUNT_ID = a.ACCOUNT_ID
        JOIN RIPPLE_RAW.ACCOUNTS acc ON acc.ACCOUNT_ID = a.ACCOUNT_ID
        LEFT JOIN (SELECT PERSON_ID, MAX(ORDER_DATE) AS LAST_ORDER FROM RIPPLE.ORDERS_P GROUP BY PERSON_ID) o
               ON o.PERSON_ID = p.PERSON_ID
        GROUP BY p.PERSON_ID, p.INR, p.RETURNS_N, p.TICKETS_N
        ORDER BY p.INR DESC LIMIT 60""", {"e": episode_id})
    return reply(episode=(head, ms), people=people)


@app.get("/api/person/{person_id}")
def person(person_id: int, episode_id: int | None = None):
    return reply(
        accounts=q("""
            SELECT a.ACCOUNT_ID AS account_id, acc.CHANNEL AS channel, acc.DISPLAY_NAME AS name, acc.EMAIL AS email,
                   acc.PHONE AS phone, acc.PINCODE AS pincode
            FROM RIPPLE.ACCOUNT_PERSON a JOIN RIPPLE_RAW.ACCOUNTS acc ON acc.ACCOUNT_ID = a.ACCOUNT_ID
            WHERE a.PERSON_ID = {p} ORDER BY a.ACCOUNT_ID""", {"p": person_id}),
        links=q("""
            SELECT e.A AS a, e.B AS b, e.SCORE AS score, p.NAME_AGREE AS name_agree, p.EMAIL_EQ AS email_eq,
                   p.PHONE_EQ AS phone_eq, p.PIN_EQ AS pin_eq, ROUND(p.BASKET_COS, 2) AS basket_cos
            FROM RIPPLE.ID_EDGES e JOIN RIPPLE.ID_PAIRS p ON p.A = e.A AND p.B = e.B
            JOIN RIPPLE.ACCOUNT_PERSON x ON x.ACCOUNT_ID = e.A WHERE x.PERSON_ID = {p}""", {"p": person_id}),
        receipts=q("""
            SELECT EPISODE_ID AS episode_id, ENTRY AS entry, SOURCE_TABLE AS src, SOURCE_REF AS src_ref,
                   ENTRY_DATE AS d, INR AS inr, NOTE AS note
            FROM RIPPLE.LEDGER WHERE PERSON_ID = {p} AND ({e} IS NULL OR EPISODE_ID = {e})
            ORDER BY ENTRY_DATE, ENTRY""", {"p": person_id, "e": episode_id}),
        orders=q("""
            SELECT TRUNC(ORDER_DATE, 'IW') AS wk, COUNT(*) AS n FROM RIPPLE.ORDERS_P WHERE PERSON_ID = {p}
            GROUP BY 1 ORDER BY 1""", {"p": person_id}),
    )


@app.get("/api/proof")
def proof():
    return reply(
        metrics=q("SELECT AREA AS area, METRIC AS metric, VARIANT AS variant, VAL AS val, NOTE AS note FROM RIPPLE.EVAL_METRICS"),
        causal=q("SELECT * FROM RIPPLE.CAUSAL_EFFECTS ORDER BY KIND"),
        calibration=q("SELECT * FROM RIPPLE.DETECTOR_CALIBRATION ORDER BY LABEL"),
        timings=q("""SELECT STAGE AS stage, SUM(SECONDS) AS seconds, MAX(RUN_AT) AS run_at FROM RIPPLE.RUN_TIMINGS
                     GROUP BY STAGE ORDER BY STAGE"""),
        scale=q("""SELECT (SELECT COUNT(*) FROM RIPPLE_RAW.ORDER_LINES) AS order_lines,
                          (SELECT COUNT(*) FROM RIPPLE_RAW.INVENTORY_BOOK) AS sku_days,
                          (SELECT COUNT(*) FROM RIPPLE_RAW.ORDERS) AS orders,
                          (SELECT COUNT(*) FROM RIPPLE_RAW.TICKETS) AS tickets,
                          (SELECT COUNT(*) FROM RIPPLE_RAW.ACCOUNTS) AS accounts FROM DUAL"""),
    )


@app.get("/api/sql")
def sql_log():
    return reply(steps=q("SELECT STAGE AS stage, STEP AS step, SECONDS AS seconds FROM RIPPLE.RUN_TIMINGS ORDER BY RUN_AT"))


app.mount("/static", StaticFiles(directory=WEB), name="static")


@app.get("/")
def index():
    return FileResponse(WEB / "index.html")


if __name__ == "__main__":
    import uvicorn
    import os
    # 8000 often sits inside Windows' Hyper-V reserved port range, so default elsewhere.
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("RIPPLE_PORT", 8765)))
