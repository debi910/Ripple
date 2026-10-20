-- Evaluation: the only stage that reads the simulator's answer key (RIPPLE_GT).
-- Every number Ripple shows is scored here, so judges can check our claims.

CREATE OR REPLACE TABLE RIPPLE.EVAL_METRICS (
    AREA VARCHAR(30), METRIC VARCHAR(80), VARIANT VARCHAR(30), VAL DOUBLE, NOTE VARCHAR(300)
);

-- Identity: pairwise precision and recall over account pairs.
INSERT INTO RIPPLE.EVAL_METRICS
WITH pred AS (SELECT a.ACCOUNT_ID A, b.ACCOUNT_ID B FROM RIPPLE.ACCOUNT_PERSON a
              JOIN RIPPLE.ACCOUNT_PERSON b ON a.PERSON_ID = b.PERSON_ID AND a.ACCOUNT_ID < b.ACCOUNT_ID),
truth AS (SELECT a.ACCOUNT_ID A, b.ACCOUNT_ID B FROM RIPPLE_GT.ACCOUNT_OWNERS a
          JOIN RIPPLE_GT.ACCOUNT_OWNERS b ON a.PERSON_ID = b.PERSON_ID AND a.ACCOUNT_ID < b.ACCOUNT_ID),
tp AS (SELECT COUNT(*) N FROM pred p JOIN truth t ON t.A = p.A AND t.B = p.B)
SELECT 'identity', 'pair_precision', NULL, tp.N / (SELECT COUNT(*) FROM pred), 'Merged account pairs that are truly one person' FROM tp
UNION ALL SELECT 'identity', 'pair_recall', NULL, tp.N / (SELECT COUNT(*) FROM truth), 'True same-person pairs we merged' FROM tp
UNION ALL SELECT 'identity', 'accounts', NULL, (SELECT COUNT(*) FROM RIPPLE_RAW.ACCOUNTS), NULL FROM DUAL
UNION ALL SELECT 'identity', 'resolved_people', NULL, (SELECT COUNT(DISTINCT PERSON_ID) FROM RIPPLE.ACCOUNT_PERSON), NULL FROM DUAL
UNION ALL SELECT 'identity', 'true_people', NULL, (SELECT COUNT(DISTINCT PERSON_ID) FROM RIPPLE_GT.ACCOUNT_OWNERS), NULL FROM DUAL;

-- Tickets: owner, intent and product.
INSERT INTO RIPPLE.EVAL_METRICS
WITH owner_map AS (
    SELECT ap.PERSON_ID, MIN(g.PERSON_ID) AS TRUE_PERSON
    FROM RIPPLE.ACCOUNT_PERSON ap JOIN RIPPLE_GT.ACCOUNT_OWNERS g ON g.ACCOUNT_ID = ap.ACCOUNT_ID GROUP BY ap.PERSON_ID
), t AS (
    SELECT e.*, g.PERSON_ID AS GT_PERSON, g.INTENT AS GT_INTENT, g.SKU_ID AS GT_SKU, m.TRUE_PERSON
    FROM RIPPLE.TICKETS_ENRICHED e JOIN RIPPLE_GT.TICKETS g ON g.TICKET_ID = e.TICKET_ID
    LEFT JOIN owner_map m ON m.PERSON_ID = e.PERSON_ID
)
SELECT 'tickets', 'owner_linked_share', NULL, AVG(CASE WHEN PERSON_ID IS NOT NULL THEN 1.0 ELSE 0 END), 'Tickets tied to a known shopper' FROM t
UNION ALL SELECT 'tickets', 'owner_accuracy', NULL, AVG(CASE WHEN TRUE_PERSON = GT_PERSON THEN 1.0 ELSE 0 END), 'Of linked tickets, right shopper' FROM t WHERE PERSON_ID IS NOT NULL
UNION ALL SELECT 'tickets', 'intent_accuracy', NULL, AVG(CASE WHEN INTENT = GT_INTENT THEN 1.0 ELSE 0 END), 'Eight intents, Hinglish and typos included' FROM t
UNION ALL SELECT 'tickets', 'sku_accuracy', NULL, AVG(CASE WHEN SKU_ID = GT_SKU THEN 1.0 ELSE 0 END), 'Stock complaints resolved to the exact SKU'
  FROM t WHERE GT_INTENT IN ('missing_item', 'substitution_complaint');

-- Detector: event-level recall and precision, and how early it fires.
INSERT INTO RIPPLE.EVAL_METRICS
WITH hits AS (
    SELECT e.VARIANT, g.EVENT_ID, MIN(e.ALERT_DATE) AS ALERT, MIN(g.START_DATE) AS S, MIN(g.END_DATE) AS E
    FROM RIPPLE_GT.PHANTOM_EVENTS g JOIN RIPPLE.PHANTOM_EPISODES e
      ON e.STORE_ID = g.STORE_ID AND e.SKU_ID = g.SKU_ID AND e.ALERT_DATE BETWEEN g.START_DATE AND g.END_DATE + 1
    GROUP BY e.VARIANT, g.EVENT_ID
), good AS (
    SELECT VARIANT, COUNT(*) AS N, SUM(IS_REAL) AS TP FROM (
        SELECT e.VARIANT, e.STORE_ID, e.SKU_ID, e.ALERT_DATE,
               MAX(CASE WHEN g.EVENT_ID IS NOT NULL THEN 1 ELSE 0 END) AS IS_REAL
        FROM RIPPLE.PHANTOM_EPISODES e LEFT JOIN RIPPLE_GT.PHANTOM_EVENTS g
          ON g.STORE_ID = e.STORE_ID AND g.SKU_ID = e.SKU_ID AND e.ALERT_DATE BETWEEN g.START_DATE AND g.END_DATE + 1
        GROUP BY e.VARIANT, e.STORE_ID, e.SKU_ID, e.ALERT_DATE)
    GROUP BY VARIANT
)
SELECT 'detector', 'recall', h.VARIANT, COUNT(*) / (SELECT COUNT(*) FROM RIPPLE_GT.PHANTOM_EVENTS), 'Phantom stock-outs caught' FROM hits h GROUP BY h.VARIANT
UNION ALL SELECT 'detector', 'precision', VARIANT, TP / N, 'Alerts that were real phantoms' FROM good
UNION ALL SELECT 'detector', 'days_onset_to_alert', VARIANT, AVG(DAYS_BETWEEN(ALERT, S)), 'Days from shelf going empty to alert' FROM hits GROUP BY VARIANT
UNION ALL SELECT 'detector', 'days_early_vs_book', VARIANT, AVG(DAYS_BETWEEN(E, ALERT)), 'Days before the stock record would have been corrected' FROM hits GROUP BY VARIANT;

-- Causal: the same matched design re-run with the true churn date as outcome.
INSERT INTO RIPPLE.EVAL_METRICS
WITH owner_map AS (
    SELECT ap.PERSON_ID, MIN(g.PERSON_ID) AS TRUE_PERSON
    FROM RIPPLE.ACCOUNT_PERSON ap JOIN RIPPLE_GT.ACCOUNT_OWNERS g ON g.ACCOUNT_ID = ap.ACCOUNT_ID GROUP BY ap.PERSON_ID
), p AS (
    SELECT cp.*, CASE cp.SEVERITY WHEN 2 THEN 'missing' WHEN 1 THEN 'substituted' END AS KIND,
           CASE WHEN cp.PRE_ORDERS = 0 THEN 0 WHEN cp.PRE_ORDERS = 1 THEN 1 WHEN cp.PRE_ORDERS <= 3 THEN 2
                WHEN cp.PRE_ORDERS <= 6 THEN 3 ELSE 4 END AS FREQ_BAND,
           CASE WHEN cp.WEEK_LINES <= 3 THEN 0 WHEN cp.WEEK_LINES <= 6 THEN 1 WHEN cp.WEEK_LINES <= 10 THEN 2 ELSE 3 END AS BASKET_BAND,
           CASE WHEN c.CHURN_DATE BETWEEN cp.WK AND cp.WK + 55 THEN 1.0 ELSE 0 END AS TRUE_CHURN
    FROM RIPPLE.CAUSAL_PANEL cp JOIN owner_map m ON m.PERSON_ID = cp.PERSON_ID
    LEFT JOIN RIPPLE_GT.CHURN c ON c.PERSON_ID = m.TRUE_PERSON
), s AS (
    SELECT WK, STORE_ID, FREQ_BAND, BASKET_BAND, KIND, TREATED, COUNT(*) N, AVG(TRUE_CHURN) R FROM p GROUP BY 1, 2, 3, 4, 5, 6
)
SELECT 'causal', 'att_true_churn', t.KIND, SUM(t.N * (t.R - c.R)) / SUM(t.N), 'Same design, true churn as outcome'
FROM s t JOIN s c ON c.WK = t.WK AND c.STORE_ID = t.STORE_ID AND c.FREQ_BAND = t.FREQ_BAND AND c.BASKET_BAND = t.BASKET_BAND
 AND c.TREATED = 0 AND c.N >= 5
WHERE t.TREATED = 1 GROUP BY t.KIND
UNION ALL SELECT 'causal', 'att_lost_rate', KIND, ATT_LOST_RATE, 'Ripple estimate from observable data' FROM RIPPLE.CAUSAL_EFFECTS
UNION ALL SELECT 'causal', 'ci95', KIND, CI95, NULL FROM RIPPLE.CAUSAL_EFFECTS;

-- Ledger: does the bill find the customers phantoms really touched?
INSERT INTO RIPPLE.EVAL_METRICS
SELECT 'ledger', 'phantom_exposures_captured', NULL,
       (SELECT COUNT(*) FROM RIPPLE.EPISODE_EXPOSURES)
       / (SELECT COUNT(*) FROM RIPPLE_GT.EXPOSURES WHERE DURING_PHANTOM), 'Order lines hit by real phantoms that the ledger bills'
FROM DUAL
UNION ALL SELECT 'ledger', 'total_bill_inr', NULL, (SELECT SUM(TOTAL_INR) FROM RIPPLE.EPISODE_BILL), NULL FROM DUAL
UNION ALL SELECT 'ledger', 'lost_sale_only_inr', NULL, (SELECT SUM(LOST_SALE_INR) FROM RIPPLE.EPISODE_BILL),
       'What a lost-sales report would show' FROM DUAL;
