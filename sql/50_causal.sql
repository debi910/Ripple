-- Engine 4: what a stock-out really costs in customers.
-- Phantom stock-outs strike at random, which makes them a natural experiment:
-- two shoppers at the same store, with the same habits, both order in the
-- same week; one hits a silent stock-out, one gets everything. Comparing what
-- they do over the next six weeks (stacked difference-in-differences, matched
-- on store and order frequency) isolates the churn the stock-out caused, not
-- just the churn that happens to follow it.

-- Person-level exposure: the worst thing that happened to them each week.
CREATE OR REPLACE TABLE RIPPLE.PERSON_WEEK_EXPOSURE AS
SELECT o.PERSON_ID, TRUNC(o.ORDER_DATE, 'IW') AS WK,
       MAX(CASE l.LINE_STATUS WHEN 'missing' THEN 2 WHEN 'substituted' THEN 1 ELSE 0 END) AS SEVERITY,
       COUNT(*) AS WEEK_LINES
FROM RIPPLE.ORDERS_P o JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
GROUP BY o.PERSON_ID, TRUNC(o.ORDER_DATE, 'IW');

CREATE OR REPLACE TABLE RIPPLE.PERSON_ORDER_MARGIN AS
SELECT o.PERSON_ID, o.ORDER_ID, o.ORDER_DATE,
       SUM(CASE WHEN l.FULFILLED_SKU_ID IS NOT NULL THEN l.QTY * (l.UNIT_PRICE - s.UNIT_COST) ELSE 0 END) AS MARGIN
FROM RIPPLE.ORDERS_P o
JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = COALESCE(l.FULFILLED_SKU_ID, l.SKU_ID)
GROUP BY o.PERSON_ID, o.ORDER_ID, o.ORDER_DATE;

-- Cohorts: every week that leaves six full weeks of follow-up and four weeks of history.
CREATE OR REPLACE TABLE RIPPLE.CAUSAL_PANEL AS
WITH bounds AS (SELECT MIN(ORDER_DATE) AS D0, MAX(ORDER_DATE) AS D1 FROM RIPPLE.ORDERS_P),
weeks AS (
    SELECT DISTINCT WK FROM RIPPLE.PERSON_WEEK_EXPOSURE, bounds
    WHERE WK >= D0 + 28 AND WK + 55 <= D1
),
first_bad AS (
    SELECT PERSON_ID, MIN(WK) AS FIRST_BAD_WK FROM RIPPLE.PERSON_WEEK_EXPOSURE WHERE SEVERITY > 0 GROUP BY PERSON_ID
),
units AS (
    -- Shoppers who ordered in cohort week w: treated if this was their first bad
    -- week, control if they have no bad week until their follow-up ends.
    SELECT w.WK, e.PERSON_ID, e.SEVERITY, e.WEEK_LINES,
           CASE WHEN e.SEVERITY > 0 AND fb.FIRST_BAD_WK = w.WK THEN 1
                WHEN e.SEVERITY = 0 AND (fb.FIRST_BAD_WK IS NULL OR fb.FIRST_BAD_WK > w.WK + 55) THEN 0 END AS TREATED
    FROM weeks w JOIN RIPPLE.PERSON_WEEK_EXPOSURE e ON e.WK = w.WK
    LEFT JOIN first_bad fb ON fb.PERSON_ID = e.PERSON_ID
)
SELECT u.WK, u.PERSON_ID, u.TREATED, u.SEVERITY, u.WEEK_LINES, h.STORE_ID,
       SUM(CASE WHEN m.ORDER_DATE BETWEEN u.WK - 28 AND u.WK - 1 THEN 1 ELSE 0 END) AS PRE_ORDERS,
       SUM(CASE WHEN m.ORDER_DATE BETWEEN u.WK - 28 AND u.WK - 1 THEN m.MARGIN ELSE 0 END) AS PRE_MARGIN,
       SUM(CASE WHEN m.ORDER_DATE BETWEEN u.WK + 7 AND u.WK + 48 THEN 1 ELSE 0 END) AS POST_ORDERS,
       SUM(CASE WHEN m.ORDER_DATE BETWEEN u.WK + 7 AND u.WK + 48 THEN m.MARGIN ELSE 0 END) AS POST_MARGIN,
       -- Lost: no order at all from week 2 to week 8 after the cohort week.
       CASE WHEN SUM(CASE WHEN m.ORDER_DATE BETWEEN u.WK + 14 AND u.WK + 55 THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END AS LOST
FROM units u
JOIN RIPPLE.PERSON_HOME_STORE h ON h.PERSON_ID = u.PERSON_ID
JOIN RIPPLE.PERSON_ORDER_MARGIN m ON m.PERSON_ID = u.PERSON_ID AND m.ORDER_DATE BETWEEN u.WK - 28 AND u.WK + 55
WHERE u.TREATED IS NOT NULL
GROUP BY u.WK, u.PERSON_ID, u.TREATED, u.SEVERITY, u.WEEK_LINES, h.STORE_ID;

-- Matching strata: cohort week x store x prior order frequency x basket size that week.
CREATE OR REPLACE TABLE RIPPLE.CAUSAL_STRATA AS
SELECT WK, STORE_ID,
       CASE WHEN PRE_ORDERS = 0 THEN 0 WHEN PRE_ORDERS = 1 THEN 1 WHEN PRE_ORDERS <= 3 THEN 2
            WHEN PRE_ORDERS <= 6 THEN 3 ELSE 4 END AS FREQ_BAND,
       CASE WHEN WEEK_LINES <= 3 THEN 0 WHEN WEEK_LINES <= 6 THEN 1 WHEN WEEK_LINES <= 10 THEN 2 ELSE 3 END AS BASKET_BAND,
       CASE SEVERITY WHEN 2 THEN 'missing' WHEN 1 THEN 'substituted' END AS KIND,
       TREATED, COUNT(*) AS N,
       AVG(LOST * 1.0) AS LOST_RATE,
       AVG(POST_ORDERS - PRE_ORDERS * 1.5) AS D_ORDERS,      -- post window is 1.5x the pre window
       AVG(POST_MARGIN - PRE_MARGIN * 1.5) AS D_MARGIN
FROM RIPPLE.CAUSAL_PANEL
GROUP BY 1, 2, 3, 4, 5, 6;

-- Treated strata are compared with the control stratum of the same week, store and band,
-- weighted by the number of treated shoppers (an average treatment effect on the treated).
CREATE OR REPLACE TABLE RIPPLE.CAUSAL_EFFECTS AS
WITH paired AS (
    SELECT t.KIND, t.N AS NT, c.N AS NC, t.LOST_RATE AS LT, c.LOST_RATE AS LC,
           t.D_ORDERS - c.D_ORDERS AS DID_ORDERS, t.D_MARGIN - c.D_MARGIN AS DID_MARGIN
    FROM RIPPLE.CAUSAL_STRATA t
    JOIN RIPPLE.CAUSAL_STRATA c
      ON c.WK = t.WK AND c.STORE_ID = t.STORE_ID AND c.FREQ_BAND = t.FREQ_BAND AND c.BASKET_BAND = t.BASKET_BAND AND c.TREATED = 0
    WHERE t.TREATED = 1 AND c.N >= 5
)
SELECT KIND, SUM(NT) AS TREATED_N, SUM(NC) AS CONTROL_N,
       SUM(NT * LT) / SUM(NT) AS LOST_RATE_TREATED,
       SUM(NT * LC) / SUM(NT) AS LOST_RATE_CONTROL,
       SUM(NT * (LT - LC)) / SUM(NT) AS ATT_LOST_RATE,
       1.96 * SQRT(SUM(NT * NT * (LT * (1 - LT) / NT + LC * (1 - LC) / NC))) / SUM(NT) AS CI95,
       SUM(NT * DID_ORDERS) / SUM(NT) AS ATT_ORDERS_6W,
       SUM(NT * DID_MARGIN) / SUM(NT) AS ATT_MARGIN_6W
FROM paired GROUP BY KIND;

-- What a lost shopper is worth: their weekly margin while active, carried for 26 weeks.
CREATE OR REPLACE TABLE RIPPLE.PERSON_VALUE AS
SELECT PERSON_ID, SUM(MARGIN) / GREATEST(DAYS_BETWEEN(MAX(ORDER_DATE), MIN(ORDER_DATE)) + 7, 28) * 7 * 26 AS CLV_6M,
       COUNT(*) AS ORDERS
FROM RIPPLE.PERSON_ORDER_MARGIN GROUP BY PERSON_ID;
