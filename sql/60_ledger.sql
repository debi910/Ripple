-- The ripple ledger: the full bill of every phantom stock-out.
-- Each entry is one receipt pointing at the exact source row (an order line,
-- a return, a ticket, a person) that produced it, so every rupee on the
-- dashboard can be traced back to evidence.

-- Handling costs are assumptions, kept in one table so a retailer can swap in their own.
CREATE OR REPLACE TABLE RIPPLE.COST_ASSUMPTIONS AS
SELECT 'return_handling' AS ITEM, 35 AS INR, 'Reverse pickup, inspection and restocking per returned line' AS NOTE FROM DUAL
UNION ALL SELECT 'ticket_handling', 45, 'Agent time per support ticket' FROM DUAL
UNION ALL SELECT 'clv_horizon_weeks', 26, 'Weeks of margin lost when a shopper leaves' FROM DUAL;

CREATE OR REPLACE TABLE RIPPLE.EPISODES AS
SELECT ROW_NUMBER() OVER (ORDER BY ALERT_DATE, STORE_ID, SKU_ID) AS EPISODE_ID,
       STORE_ID, SKU_ID, ONSET_DATE, ALERT_DATE, LAST_DATE, PEAK_P, LAMBDA_HAT,
       DAYS_BETWEEN(LAST_DATE, ONSET_DATE) + 1 AS DAYS_OPEN
FROM RIPPLE.PHANTOM_EPISODES WHERE VARIANT = 'all';

-- Every order line a phantom touched, and who it touched (resolved person, not account).
CREATE OR REPLACE TABLE RIPPLE.EPISODE_EXPOSURES AS
SELECT e.EPISODE_ID, o.PERSON_ID, o.ACCOUNT_ID, o.ORDER_ID, l.LINE_NO, o.ORDER_DATE, l.SKU_ID,
       l.FULFILLED_SKU_ID, l.LINE_STATUS, l.QTY, l.UNIT_PRICE
FROM RIPPLE.EPISODES e
JOIN RIPPLE.ORDERS_P o ON o.STORE_ID = e.STORE_ID AND o.ORDER_DATE BETWEEN e.ONSET_DATE AND e.LAST_DATE
JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID AND l.SKU_ID = e.SKU_ID AND l.LINE_STATUS <> 'fulfilled';

CREATE OR REPLACE TABLE RIPPLE.LEDGER AS
-- 1. Margin on the item the customer paid for and never received.
SELECT x.EPISODE_ID, x.PERSON_ID, 'lost_sale' AS ENTRY, 'ORDER_LINES' AS SOURCE_TABLE,
       x.ORDER_ID || '/' || x.LINE_NO AS SOURCE_REF, x.ORDER_DATE AS ENTRY_DATE,
       x.QTY * (s.PRICE - s.UNIT_COST) AS INR,
       'Missing ' || s.NAME || ' x' || x.QTY AS NOTE
FROM RIPPLE.EPISODE_EXPOSURES x JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = x.SKU_ID
WHERE x.LINE_STATUS = 'missing'
UNION ALL
-- 2. Margin given up by sending a cheaper or lower-margin substitute.
SELECT x.EPISODE_ID, x.PERSON_ID, 'substitution_margin', 'ORDER_LINES', x.ORDER_ID || '/' || x.LINE_NO, x.ORDER_DATE,
       x.QTY * ((s.PRICE - s.UNIT_COST) - (f.PRICE - f.UNIT_COST)),
       'Sent ' || f.NAME || ' for ' || s.NAME
FROM RIPPLE.EPISODE_EXPOSURES x
JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = x.SKU_ID JOIN RIPPLE_RAW.SKUS f ON f.SKU_ID = x.FULFILLED_SKU_ID
WHERE x.LINE_STATUS = 'substituted'
UNION ALL
-- 3. The substitute came back: margin reversed, handling paid, perishables written off.
SELECT x.EPISODE_ID, x.PERSON_ID, 'return', 'PRODUCT_RETURNS', TO_CHAR(r.RETURN_ID), r.RETURN_DATE,
       x.QTY * (f.PRICE - f.UNIT_COST) + (SELECT INR FROM RIPPLE.COST_ASSUMPTIONS WHERE ITEM = 'return_handling')
         + CASE WHEN f.PERISHABLE THEN x.QTY * f.UNIT_COST ELSE 0 END,
       'Returned substitute ' || f.NAME || ' (reason code: ' || r.REASON_CODE || ')'
FROM RIPPLE.EPISODE_EXPOSURES x
JOIN RIPPLE_RAW.PRODUCT_RETURNS r ON r.ORDER_ID = x.ORDER_ID AND r.LINE_NO = x.LINE_NO
JOIN RIPPLE_RAW.SKUS f ON f.SKU_ID = x.FULFILLED_SKU_ID
UNION ALL
-- 4. Support tickets this person raised about it within three days.
SELECT t.EPISODE_ID, t.PERSON_ID, 'ticket', 'TICKETS', TO_CHAR(t.TICKET_ID), t.TICKET_DATE,
       (SELECT INR FROM RIPPLE.COST_ASSUMPTIONS WHERE ITEM = 'ticket_handling'), t.BODY
FROM (
    SELECT x.EPISODE_ID, x.PERSON_ID, te.TICKET_ID, te.TICKET_DATE, te.BODY,
           ROW_NUMBER() OVER (PARTITION BY te.TICKET_ID ORDER BY DAYS_BETWEEN(te.TICKET_DATE, x.ORDER_DATE)) AS RN
    FROM (SELECT DISTINCT EPISODE_ID, PERSON_ID, ORDER_DATE, SKU_ID FROM RIPPLE.EPISODE_EXPOSURES) x
    JOIN RIPPLE.TICKETS_ENRICHED te
      ON te.PERSON_ID = x.PERSON_ID AND te.TICKET_DATE BETWEEN x.ORDER_DATE AND x.ORDER_DATE + 3
     AND te.STOCK_SIGNAL AND (te.SKU_ID IS NULL OR te.SKU_ID = x.SKU_ID)
) t WHERE t.RN = 1
UNION ALL
-- 5. Shoppers it drove away: the causal lift in lost-shopper rate times what the shopper was worth.
SELECT p.EPISODE_ID, p.PERSON_ID, 'churn_risk', 'CAUSAL_EFFECTS', p.KIND, p.FIRST_DATE,
       ce.ATT_LOST_RATE * COALESCE(v.CLV_6M, 0),
       'Causal lift ' || TO_CHAR(ROUND(ce.ATT_LOST_RATE * 100, 1)) || ' pts x 26-week value Rs ' || TO_CHAR(ROUND(v.CLV_6M))
FROM (
    SELECT EPISODE_ID, PERSON_ID, MIN(ORDER_DATE) AS FIRST_DATE,
           CASE WHEN MAX(CASE WHEN LINE_STATUS = 'missing' THEN 1 ELSE 0 END) = 1 THEN 'missing' ELSE 'substituted' END AS KIND
    FROM RIPPLE.EPISODE_EXPOSURES GROUP BY EPISODE_ID, PERSON_ID
) p
JOIN RIPPLE.CAUSAL_EFFECTS ce ON ce.KIND = p.KIND
LEFT JOIN RIPPLE.PERSON_VALUE v ON v.PERSON_ID = p.PERSON_ID
WHERE ce.ATT_LOST_RATE > 0;

-- The bill per episode, next to what a conventional view would report (the lost sale alone).
CREATE OR REPLACE TABLE RIPPLE.EPISODE_BILL AS
SELECT e.EPISODE_ID, e.STORE_ID, st.NAME AS STORE_NAME, e.SKU_ID, s.NAME AS SKU_NAME, s.CATEGORY,
       e.ONSET_DATE, e.ALERT_DATE, e.LAST_DATE, e.DAYS_OPEN, e.PEAK_P,
       COUNT(DISTINCT l.PERSON_ID) AS CUSTOMERS_HIT,
       SUM(CASE WHEN l.ENTRY = 'lost_sale' THEN l.INR ELSE 0 END) AS LOST_SALE_INR,
       SUM(CASE WHEN l.ENTRY = 'substitution_margin' THEN l.INR ELSE 0 END) AS SUBSTITUTION_INR,
       SUM(CASE WHEN l.ENTRY = 'return' THEN l.INR ELSE 0 END) AS RETURNS_INR,
       SUM(CASE WHEN l.ENTRY = 'ticket' THEN l.INR ELSE 0 END) AS TICKETS_INR,
       SUM(CASE WHEN l.ENTRY = 'churn_risk' THEN l.INR ELSE 0 END) AS CHURN_INR,
       SUM(l.INR) AS TOTAL_INR,
       SUM(CASE WHEN l.ENTRY = 'return' THEN 1 ELSE 0 END) AS RETURNS_N,
       SUM(CASE WHEN l.ENTRY = 'ticket' THEN 1 ELSE 0 END) AS TICKETS_N
FROM RIPPLE.EPISODES e
JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = e.SKU_ID
JOIN RIPPLE_RAW.STORES st ON st.STORE_ID = e.STORE_ID
LEFT JOIN RIPPLE.LEDGER l ON l.EPISODE_ID = e.EPISODE_ID
GROUP BY e.EPISODE_ID, e.STORE_ID, st.NAME, e.SKU_ID, s.NAME, s.CATEGORY,
         e.ONSET_DATE, e.ALERT_DATE, e.LAST_DATE, e.DAYS_OPEN, e.PEAK_P;
