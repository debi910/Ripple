-- Baselines from the literature, scored on the same answer key as Ripple.
--   * Kang & Gershwin (2005): treat N consecutive zero-sales days on a stocked
--     item as a stock-out. We pick the best N in hindsight, which flatters it.
--   * Day-level AUC, so Ripple can sit beside Farias, Li & Peng (2024).
--   * Recount policies with the same daily budget: Ripple's list, a zero-sales
--     walk (count the longest silences first), and random counts.

CREATE OR REPLACE TABLE RIPPLE.BASELINE_METRICS (
    AREA VARCHAR(30), METRIC VARCHAR(80), APPROACH VARCHAR(40), VAL DOUBLE, NOTE VARCHAR(300)
);

-- Zero-sales run length on each visible day, and whether the shelf was truly empty.
CREATE OR REPLACE TABLE RIPPLE.BASELINE_DAYS AS
WITH runs AS (
    SELECT d.STORE_ID, d.SKU_ID, d.D, d.BOOK_SOD, d.UNITS, d.LAMBDA_28,
           SUM(CASE WHEN d.UNITS > 0 OR COALESCE(d.BOOK_SOD, 0) <= 0 THEN 1 ELSE 0 END)
             OVER (PARTITION BY d.STORE_ID, d.SKU_ID ORDER BY d.D ROWS UNBOUNDED PRECEDING) AS RUN_ID
    FROM RIPPLE.SKU_DAY d
)
SELECT r.STORE_ID, r.SKU_ID, r.D, r.LAMBDA_28,
       CASE WHEN r.UNITS = 0 AND r.BOOK_SOD > 0
            THEN ROW_NUMBER() OVER (PARTITION BY r.STORE_ID, r.SKU_ID, r.RUN_ID ORDER BY r.D) - 1 ELSE 0 END AS ZERO_RUN,
       s.P_PHANTOM,
       CASE WHEN g.EVENT_ID IS NOT NULL THEN 1 ELSE 0 END AS TRULY_EMPTY
FROM runs r
JOIN RIPPLE.PHANTOM_SCORES s ON s.VARIANT = 'all' AND s.STORE_ID = r.STORE_ID AND s.SKU_ID = r.SKU_ID AND s.D = r.D
LEFT JOIN RIPPLE_GT.PHANTOM_EVENTS g
       ON g.STORE_ID = r.STORE_ID AND g.SKU_ID = r.SKU_ID AND r.D BETWEEN g.START_DATE AND g.END_DATE
WHERE r.BOOK_SOD > 0;

-- 1. Kang & Gershwin rule for N = 1..28; keep the N with the best F1.
CREATE OR REPLACE TABLE RIPPLE.BASELINE_ZERO_RULE AS
WITH n AS (SELECT LEVEL AS N FROM DUAL CONNECT BY LEVEL <= 28),
crossings AS (
    SELECT n.N, b.STORE_ID, b.SKU_ID, b.D FROM n JOIN RIPPLE.BASELINE_DAYS b ON b.ZERO_RUN = n.N
),
hit AS (
    SELECT c.N, g.EVENT_ID, MIN(c.D) AS ALERT, MIN(g.START_DATE) AS S
    FROM crossings c JOIN RIPPLE_GT.PHANTOM_EVENTS g
      ON g.STORE_ID = c.STORE_ID AND g.SKU_ID = c.SKU_ID AND c.D BETWEEN g.START_DATE AND g.END_DATE + 1
    GROUP BY c.N, g.EVENT_ID
),
prec AS (
    SELECT c.N, COUNT(*) AS ALERTS,
           SUM(CASE WHEN EXISTS_FLAG = 1 THEN 1 ELSE 0 END) AS GOOD
    FROM (SELECT c.N, c.STORE_ID, c.SKU_ID, c.D,
                 MAX(CASE WHEN g.EVENT_ID IS NOT NULL THEN 1 ELSE 0 END) AS EXISTS_FLAG
          FROM crossings c LEFT JOIN RIPPLE_GT.PHANTOM_EVENTS g
            ON g.STORE_ID = c.STORE_ID AND g.SKU_ID = c.SKU_ID AND c.D BETWEEN g.START_DATE AND g.END_DATE + 1
          GROUP BY c.N, c.STORE_ID, c.SKU_ID, c.D) c
    GROUP BY c.N
)
SELECT p.N, h.CAUGHT / (SELECT COUNT(*) FROM RIPPLE_GT.PHANTOM_EVENTS) AS RECALL,
       p.GOOD / p.ALERTS AS PRECISION_, h.DAYS_TO_ALERT
FROM prec p
JOIN (SELECT N, COUNT(*) AS CAUGHT, AVG(DAYS_BETWEEN(ALERT, S)) AS DAYS_TO_ALERT FROM hit GROUP BY N) h ON h.N = p.N;

INSERT INTO RIPPLE.BASELINE_METRICS
WITH best AS (
    SELECT * FROM RIPPLE.BASELINE_ZERO_RULE
    ORDER BY 2 * RECALL * PRECISION_ / NULLIF(RECALL + PRECISION_, 0) DESC LIMIT 1
)
SELECT 'detector', 'recall', 'zero_sales_rule', RECALL, 'Kang & Gershwin rule, best N = ' || TO_CHAR(N) || ' chosen in hindsight' FROM best
UNION ALL SELECT 'detector', 'precision', 'zero_sales_rule', PRECISION_, NULL FROM best
UNION ALL SELECT 'detector', 'days_onset_to_alert', 'zero_sales_rule', DAYS_TO_ALERT, NULL FROM best
UNION ALL SELECT 'detector', 'best_n', 'zero_sales_rule', N, NULL FROM best
UNION ALL SELECT 'detector', METRIC, 'ripple', VAL, NOTE FROM RIPPLE.EVAL_METRICS
          WHERE AREA = 'detector' AND VARIANT = 'all' AND METRIC IN ('recall', 'precision', 'days_onset_to_alert');

-- 2. Day-level AUC (Mann-Whitney, ties counted half) for Ripple's posterior and
--    for the zero-run length.
INSERT INTO RIPPLE.BASELINE_METRICS
WITH scored AS (
    SELECT 'ripple' AS APPROACH, ROUND(P_PHANTOM, 6) AS SCORE, TRULY_EMPTY FROM RIPPLE.BASELINE_DAYS
    UNION ALL SELECT 'zero_sales_rule', ZERO_RUN, TRULY_EMPTY FROM RIPPLE.BASELINE_DAYS
), grouped AS (
    SELECT APPROACH, SCORE, SUM(TRULY_EMPTY) AS POS, SUM(1 - TRULY_EMPTY) AS NEG FROM scored GROUP BY APPROACH, SCORE
), cum AS (
    SELECT APPROACH, SCORE, POS, NEG,
           SUM(NEG) OVER (PARTITION BY APPROACH ORDER BY SCORE ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS NEG_BELOW
    FROM grouped
)
SELECT 'detector', 'auc_day_level', APPROACH,
       SUM(POS * (COALESCE(NEG_BELOW, 0) + 0.5 * NEG)) / (SUM(POS) * SUM(NEG)),
       'Farias, Li & Peng report 0.67 on real data with injected anomalies'
FROM cum GROUP BY APPROACH;

-- 3. Recount policies, each allowed 3 counts per store per day. A count made the
--    morning after a list finds a real phantom and saves the remaining empty
--    days times the shelf's expected daily loss; each phantom is credited once.
CREATE OR REPLACE TABLE RIPPLE.BASELINE_RECOUNT AS
WITH daily_cost AS (
    SELECT b.STORE_ID, b.SKU_ID, b.D, b.ZERO_RUN, b.P_PHANTOM,
           GREATEST(COALESCE(b.LAMBDA_28, 0), 0.05) * COALESCE(cpe.INR_PER_SHORT_LINE, 0) AS LOSS_PER_DAY
    FROM RIPPLE.BASELINE_DAYS b
    JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = b.SKU_ID
    LEFT JOIN RIPPLE.COST_PER_EXPOSURE cpe ON cpe.CATEGORY = s.CATEGORY
), ranked AS (
    SELECT c.*,
           ROW_NUMBER() OVER (PARTITION BY STORE_ID, D ORDER BY P_PHANTOM * LOSS_PER_DAY DESC, SKU_ID) AS R_RIPPLE,
           ROW_NUMBER() OVER (PARTITION BY STORE_ID, D ORDER BY ZERO_RUN DESC, LOSS_PER_DAY DESC, SKU_ID) AS R_ZERO,
           ROW_NUMBER() OVER (PARTITION BY STORE_ID, D ORDER BY MOD(SKU_ID * 7919 + DAYS_BETWEEN(D, DATE '2000-01-01') * 104729, 1000003)) AS R_RANDOM
    FROM daily_cost c
), picks AS (
    SELECT 'ripple' AS APPROACH, STORE_ID, SKU_ID, D + 1 AS COUNT_DAY, LOSS_PER_DAY FROM ranked WHERE R_RIPPLE <= 3
    UNION ALL SELECT 'zero_sales_walk', STORE_ID, SKU_ID, D + 1, LOSS_PER_DAY FROM ranked WHERE R_ZERO <= 3
    UNION ALL SELECT 'random', STORE_ID, SKU_ID, D + 1, LOSS_PER_DAY FROM ranked WHERE R_RANDOM <= 3
), found_ev AS (
    SELECT p.APPROACH, g.EVENT_ID, MIN(p.COUNT_DAY) AS FIRST_COUNT, MAX(g.END_DATE) AS END_DATE, MAX(p.LOSS_PER_DAY) AS LOSS_PER_DAY
    FROM picks p JOIN RIPPLE_GT.PHANTOM_EVENTS g
      ON g.STORE_ID = p.STORE_ID AND g.SKU_ID = p.SKU_ID AND p.COUNT_DAY BETWEEN g.START_DATE AND g.END_DATE
    GROUP BY p.APPROACH, g.EVENT_ID
)
SELECT APPROACH, COUNT(*) AS PHANTOMS_FOUND,
       SUM(DAYS_BETWEEN(END_DATE, FIRST_COUNT)) AS EMPTY_DAYS_AVOIDED,
       SUM(DAYS_BETWEEN(END_DATE, FIRST_COUNT) * LOSS_PER_DAY) AS INR_SAVED
FROM found_ev GROUP BY APPROACH;

INSERT INTO RIPPLE.BASELINE_METRICS
SELECT 'recount', 'inr_saved', APPROACH, INR_SAVED, TO_CHAR(PHANTOMS_FOUND) || ' phantoms found, '
       || TO_CHAR(EMPTY_DAYS_AVOIDED) || ' empty shelf-days avoided, 3 counts per store per day' FROM RIPPLE.BASELINE_RECOUNT;

-- 4. Does the make-good list find the shoppers who really leave?
INSERT INTO RIPPLE.BASELINE_METRICS
WITH owner_map AS (
    SELECT ap.PERSON_ID, MIN(g.PERSON_ID) AS TRUE_PERSON
    FROM RIPPLE.ACCOUNT_PERSON ap JOIN RIPPLE_GT.ACCOUNT_OWNERS g ON g.ACCOUNT_ID = ap.ACCOUNT_ID GROUP BY ap.PERSON_ID
), silent AS (
    SELECT b.PERSON_ID, CASE WHEN l.PERSON_ID IS NOT NULL THEN 1 ELSE 0 END AS LISTED,
           CASE WHEN c.PERSON_ID IS NOT NULL AND c.CHURN_DATE >= b.FIRST_HIT THEN 1.0 ELSE 0 END AS CHURNED
    FROM RIPPLE.MAKEGOOD_BASE b
    JOIN owner_map m ON m.PERSON_ID = b.PERSON_ID
    LEFT JOIN RIPPLE.MAKEGOOD_LIST l ON l.PERSON_ID = b.PERSON_ID
    LEFT JOIN RIPPLE_GT.CHURN c ON c.PERSON_ID = m.TRUE_PERSON
    WHERE b.SILENT = 1
)
SELECT 'makegood', 'true_churn_rate', CASE LISTED WHEN 1 THEN 'listed' ELSE 'not_listed' END, AVG(CHURNED),
       'Silent hit shoppers who really left after the hit' FROM silent GROUP BY LISTED;
