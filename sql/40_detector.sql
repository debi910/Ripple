-- Engine 1: phantom stock-out detector.
-- For every SKU in every store, a two-state hidden Markov filter (normal vs.
-- phantom: the system says in stock, the shelf is empty) runs day by day
-- inside an Exasol Python SET UDF, one parallel group per SKU-store. It fuses
-- four silos: POS sales, OMS short picks, picker exception logs and customer
-- tickets. Its emission rates are learned from the retailer's own historical
-- cycle counts, so it never sees the simulator's answer key.

-- 1. One dense row per SKU, store and day with every signal lined up.
CREATE OR REPLACE TABLE RIPPLE.SKU_DAY AS
WITH sales AS (
    SELECT STORE_ID, SKU_ID, SALE_DATE AS D, SUM(UNITS) AS UNITS FROM RIPPLE_RAW.SALES_DAILY GROUP BY 1, 2, 3
), shorts AS (
    SELECT o.STORE_ID, l.SKU_ID, o.ORDER_DATE AS D, COUNT(*) AS SHORT_LINES
    FROM RIPPLE_RAW.ORDER_LINES l JOIN RIPPLE.ORDERS_P o ON o.ORDER_ID = l.ORDER_ID
    WHERE l.LINE_STATUS <> 'fulfilled' GROUP BY 1, 2, 3
), picks AS (
    SELECT STORE_ID, SKU_ID, PICK_DATE AS D, COUNT(*) AS PICK_EX FROM RIPPLE_RAW.PICK_EXCEPTIONS GROUP BY 1, 2, 3
), tix AS (
    SELECT STORE_ID, SKU_ID, TICKET_DATE AS D, COUNT(*) AS STOCK_TICKETS
    FROM RIPPLE.TICKETS_ENRICHED WHERE STOCK_SIGNAL AND SKU_ID IS NOT NULL AND STORE_ID IS NOT NULL GROUP BY 1, 2, 3
), counts AS (
    SELECT STORE_ID, SKU_ID, COUNT_DATE AS D, MAX(BOOK_QTY) AS COUNT_BOOK, MAX(COUNTED_QTY) AS COUNT_QTY
    FROM RIPPLE_RAW.CYCLE_COUNTS GROUP BY 1, 2, 3
), base AS (
    SELECT b.STORE_ID, b.SKU_ID, b.SNAPSHOT_DATE AS D, b.BOOK_QTY AS BOOK_EOD,
           LAG(b.BOOK_QTY) OVER (PARTITION BY b.STORE_ID, b.SKU_ID ORDER BY b.SNAPSHOT_DATE) AS BOOK_SOD,
           COALESCE(s.UNITS, 0) AS UNITS, COALESCE(sh.SHORT_LINES, 0) AS SHORT_LINES,
           COALESCE(p.PICK_EX, 0) AS PICK_EX, COALESCE(t.STOCK_TICKETS, 0) AS STOCK_TICKETS,
           c.COUNT_BOOK, c.COUNT_QTY
    FROM RIPPLE_RAW.INVENTORY_BOOK b
    LEFT JOIN sales s   ON s.STORE_ID = b.STORE_ID AND s.SKU_ID = b.SKU_ID AND s.D = b.SNAPSHOT_DATE
    LEFT JOIN shorts sh ON sh.STORE_ID = b.STORE_ID AND sh.SKU_ID = b.SKU_ID AND sh.D = b.SNAPSHOT_DATE
    LEFT JOIN picks p   ON p.STORE_ID = b.STORE_ID AND p.SKU_ID = b.SKU_ID AND p.D = b.SNAPSHOT_DATE
    LEFT JOIN tix t     ON t.STORE_ID = b.STORE_ID AND t.SKU_ID = b.SKU_ID AND t.D = b.SNAPSHOT_DATE
    LEFT JOIN counts c  ON c.STORE_ID = b.STORE_ID AND c.SKU_ID = b.SKU_ID AND c.D = b.SNAPSHOT_DATE
), store_day AS (
    -- Store traffic index: weekends and festivals lift every SKU at once.
    SELECT STORE_ID, D, SUM(UNITS) AS STORE_UNITS FROM base GROUP BY 1, 2
), store_idx AS (
    SELECT STORE_ID, D,
           STORE_UNITS / NULLIF(AVG(STORE_UNITS) OVER (PARTITION BY STORE_ID ORDER BY D
                                ROWS BETWEEN 28 PRECEDING AND 1 PRECEDING), 0) AS DEMAND_INDEX
    FROM store_day
)
SELECT b.*, COALESCE(i.DEMAND_INDEX, 1) AS DEMAND_INDEX,
       -- Expected units from the trailing four weeks, used only for calibration and costing.
       AVG(b.UNITS + b.SHORT_LINES) OVER (PARTITION BY b.STORE_ID, b.SKU_ID ORDER BY b.D
           ROWS BETWEEN 28 PRECEDING AND 1 PRECEDING) AS LAMBDA_28
FROM base b JOIN store_idx i ON i.STORE_ID = b.STORE_ID AND i.D = b.D;

-- 2. Self-calibration from cycle counts. A count that finds an empty shelf the
--    system thought was stocked is a labelled phantom; the three days before it
--    tell us how loudly each signal speaks during a phantom versus normal days.
CREATE OR REPLACE TABLE RIPPLE.DETECTOR_CALIBRATION AS
WITH labelled AS (
    SELECT STORE_ID, SKU_ID, D AS COUNT_DATE,
           CASE WHEN COUNT_BOOK > 0 AND COUNT_QTY = 0 THEN 'phantom' ELSE 'normal' END AS LABEL
    FROM RIPPLE.SKU_DAY WHERE COUNT_BOOK IS NOT NULL
), win AS (
    SELECT l.LABEL, d.UNITS, d.SHORT_LINES, d.PICK_EX, d.STOCK_TICKETS,
           GREATEST(COALESCE(d.LAMBDA_28, 0), 0.05) * d.DEMAND_INDEX AS EXP_DEMAND
    FROM labelled l JOIN RIPPLE.SKU_DAY d
      ON d.STORE_ID = l.STORE_ID AND d.SKU_ID = l.SKU_ID AND d.D BETWEEN l.COUNT_DATE - 3 AND l.COUNT_DATE - 1
    WHERE d.BOOK_SOD > 0
)
SELECT LABEL, COUNT(*) AS DAYS,
       SUM(SHORT_LINES) / SUM(EXP_DEMAND) AS SHORT_RATE,
       SUM(PICK_EX) / SUM(EXP_DEMAND) AS PICK_RATE,
       SUM(STOCK_TICKETS) / SUM(EXP_DEMAND) AS TICKET_RATE,
       SUM(UNITS) / SUM(EXP_DEMAND) AS SALES_RATE
FROM win GROUP BY LABEL;

CREATE OR REPLACE TABLE RIPPLE.DETECTOR_PARAMS AS
SELECT
    -- Phantom onset hazard: confirmed phantoms per SKU-day covered by counts.
    (SELECT COUNT(*) FROM RIPPLE.SKU_DAY WHERE COUNT_BOOK > 0 AND COUNT_QTY = 0)
      / (SELECT COUNT(*) FROM RIPPLE.SKU_DAY) AS ONSET_HAZARD,
    n.SHORT_RATE + 0.002 AS N_SHORT, p.SHORT_RATE + 0.002 AS P_SHORT,
    n.PICK_RATE + 0.001 AS N_PICK, p.PICK_RATE + 0.001 AS P_PICK,
    n.TICKET_RATE + 0.001 AS N_TICKET, p.TICKET_RATE + 0.001 AS P_TICKET
FROM (SELECT * FROM RIPPLE.DETECTOR_CALIBRATION WHERE LABEL = 'normal') n
CROSS JOIN (SELECT * FROM RIPPLE.DETECTOR_CALIBRATION WHERE LABEL = 'phantom') p;

-- 3. The filter. Inputs arrive ordered by day within each SKU-store group.
CREATE OR REPLACE PYTHON3 SET SCRIPT RIPPLE.PHANTOM_FILTER(
    store_id DECIMAL(9,0), sku_id DECIMAL(9,0), d DATE,
    book_sod DECIMAL(9,0), book_eod DECIMAL(9,0), units DECIMAL(9,0), short_lines DECIMAL(9,0),
    pick_ex DECIMAL(9,0), stock_tickets DECIMAL(9,0), demand_index DOUBLE, counted BOOLEAN,
    onset DOUBLE, n_short DOUBLE, p_short DOUBLE, n_pick DOUBLE, p_pick DOUBLE,
    n_ticket DOUBLE, p_ticket DOUBLE,
    use_oms BOOLEAN, use_pick BOOLEAN, use_tickets BOOLEAN)
EMITS (store_id DECIMAL(9,0), sku_id DECIMAL(9,0), d DATE, p_phantom DOUBLE, lambda_hat DOUBLE,
       llr_sales DOUBLE, llr_oms DOUBLE, llr_pick DOUBLE, llr_tickets DOUBLE) AS
from math import lgamma, log, exp

NB_K = 2.5          # negative-binomial dispersion: daily retail sales are over-dispersed
STAY = 0.995        # a phantom rarely heals by itself unless stock arrives
ALPHA = 0.08        # learning rate of the demand estimate

def nb_logpmf(x, m):
    m = max(m, 1e-6)
    return lgamma(x + NB_K) - lgamma(NB_K) - lgamma(x + 1) + NB_K * log(NB_K / (NB_K + m)) + x * log(m / (NB_K + m))

def pois_logpmf(x, m):
    m = max(m, 1e-6)
    return x * log(m) - m - lgamma(x + 1)

def run(ctx):
    lam, warm, p = None, [], 0.0
    while True:
        store, sku, day = ctx.store_id, ctx.sku_id, ctx.d
        book_sod = ctx.book_sod if ctx.book_sod is not None else ctx.book_eod
        units, idx = float(ctx.units), max(ctx.demand_index or 1.0, 0.2)
        shorts, picks, tix = float(ctx.short_lines), float(ctx.pick_ex), float(ctx.stock_tickets)
        restocked = ctx.book_eod is not None and book_sod is not None and ctx.book_eod > book_sod
        llr = [0.0, 0.0, 0.0, 0.0]

        if lam is None:
            warm.append(units + shorts)
            if len(warm) >= 14:
                lam = max(sum(warm) / len(warm), 0.02)
            ctx.emit(store, sku, day, 0.0, lam, 0.0, 0.0, 0.0, 0.0)
        elif book_sod <= 0:
            # Visibly out of stock: the app hides the item, nothing to infer.
            p = 0.0
            ctx.emit(store, sku, day, 0.0, lam, 0.0, 0.0, 0.0, 0.0)
        else:
            m = lam * idx
            prior = p * STAY + (1 - p) * ctx.onset
            # Sales: a phantom shelf sells (almost) nothing.
            llr[0] = (log(0.98) if units == 0 else log(1e-3)) - nb_logpmf(units, m)
            # Short picks on a shelf that genuinely sold out (or held a single unit) are
            # explained by demand, not by a phantom, so they carry no evidence.
            sold_out = float(book_sod) - units <= 1
            if ctx.use_oms and not sold_out:
                llr[1] = pois_logpmf(shorts, ctx.p_short * m) - pois_logpmf(shorts, ctx.n_short * m)
            if ctx.use_pick and not sold_out:
                llr[2] = pois_logpmf(picks, ctx.p_pick * m) - pois_logpmf(picks, ctx.n_pick * m)
            if ctx.use_tickets:
                llr[3] = pois_logpmf(tix, ctx.p_ticket * m + 0.002) - pois_logpmf(tix, ctx.n_ticket * m + 0.002)
            logit = log(prior / (1 - prior)) + sum(llr)
            logit = max(min(logit, 30), -30)
            p = 1 / (1 + exp(-logit))
            ctx.emit(store, sku, day, p, lam, llr[0], llr[1], llr[2], llr[3])
            if p < 0.5:
                lam += ALPHA * (1 - p) * ((units + shorts) / idx - lam)
                lam = max(lam, 0.02)
        if restocked or ctx.counted:
            p = 0.0  # stock arrived or the shelf was counted: the book is true again
        if not ctx.next():
            break
/

-- 4. Run the filter with all signals, and twice more with signals removed, so
--    the value of joining each silo can be measured (ablation).
CREATE OR REPLACE TABLE RIPPLE.PHANTOM_SCORES AS
SELECT 'all' AS VARIANT, f.* FROM (
    SELECT RIPPLE.PHANTOM_FILTER(d.STORE_ID, d.SKU_ID, d.D, d.BOOK_SOD, d.BOOK_EOD, d.UNITS, d.SHORT_LINES,
               d.PICK_EX, d.STOCK_TICKETS, d.DEMAND_INDEX, d.COUNT_BOOK IS NOT NULL,
               p.ONSET_HAZARD, p.N_SHORT, p.P_SHORT, p.N_PICK, p.P_PICK, p.N_TICKET, p.P_TICKET,
               TRUE, TRUE, TRUE ORDER BY d.D)
    FROM RIPPLE.SKU_DAY d CROSS JOIN RIPPLE.DETECTOR_PARAMS p
    GROUP BY d.STORE_ID, d.SKU_ID) f
UNION ALL
SELECT 'pos_only', f.* FROM (
    SELECT RIPPLE.PHANTOM_FILTER(d.STORE_ID, d.SKU_ID, d.D, d.BOOK_SOD, d.BOOK_EOD, d.UNITS, d.SHORT_LINES,
               d.PICK_EX, d.STOCK_TICKETS, d.DEMAND_INDEX, d.COUNT_BOOK IS NOT NULL,
               p.ONSET_HAZARD, p.N_SHORT, p.P_SHORT, p.N_PICK, p.P_PICK, p.N_TICKET, p.P_TICKET,
               FALSE, FALSE, FALSE ORDER BY d.D)
    FROM RIPPLE.SKU_DAY d CROSS JOIN RIPPLE.DETECTOR_PARAMS p
    GROUP BY d.STORE_ID, d.SKU_ID) f
UNION ALL
SELECT 'pos_tickets', f.* FROM (
    SELECT RIPPLE.PHANTOM_FILTER(d.STORE_ID, d.SKU_ID, d.D, d.BOOK_SOD, d.BOOK_EOD, d.UNITS, d.SHORT_LINES,
               d.PICK_EX, d.STOCK_TICKETS, d.DEMAND_INDEX, d.COUNT_BOOK IS NOT NULL,
               p.ONSET_HAZARD, p.N_SHORT, p.P_SHORT, p.N_PICK, p.P_PICK, p.N_TICKET, p.P_TICKET,
               FALSE, FALSE, TRUE ORDER BY d.D)
    FROM RIPPLE.SKU_DAY d CROSS JOIN RIPPLE.DETECTOR_PARAMS p
    GROUP BY d.STORE_ID, d.SKU_ID) f;

-- 5. Episodes: runs of days the filter believes are phantom (p >= 0.9),
--    back-dated to the first silent day of the run.
CREATE OR REPLACE TABLE RIPPLE.PHANTOM_EPISODES AS
WITH flagged AS (
    SELECT VARIANT, STORE_ID, SKU_ID, D, P_PHANTOM, LAMBDA_HAT,
           CASE WHEN P_PHANTOM >= 0.9 THEN 1 ELSE 0 END AS HOT,
           CASE WHEN P_PHANTOM >= 0.3 THEN 1 ELSE 0 END AS WARM
    FROM RIPPLE.PHANTOM_SCORES
), islands AS (
    -- A warm island is the stretch of suspicion; it becomes an episode if it ever turns hot.
    SELECT f.*, SUM(CASE WHEN WARM = 0 THEN 1 ELSE 0 END)
               OVER (PARTITION BY VARIANT, STORE_ID, SKU_ID ORDER BY D ROWS UNBOUNDED PRECEDING) AS ISLAND
    FROM flagged f
)
SELECT VARIANT, STORE_ID, SKU_ID,
       MIN(CASE WHEN WARM = 1 THEN D END) AS ONSET_DATE,
       MIN(CASE WHEN HOT = 1 THEN D END) AS ALERT_DATE,
       MAX(CASE WHEN WARM = 1 THEN D END) AS LAST_DATE,
       MAX(P_PHANTOM) AS PEAK_P,
       AVG(CASE WHEN WARM = 1 THEN LAMBDA_HAT END) AS LAMBDA_HAT
FROM islands
WHERE WARM = 1
GROUP BY VARIANT, STORE_ID, SKU_ID, ISLAND
HAVING MAX(HOT) = 1;
