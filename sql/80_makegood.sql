-- The make-good list: act on the bill before the shopper leaves.
-- Most people a phantom hits never write in (about 1 in 26 complains), so the
-- helpdesk never hears from the ones most likely to quietly leave. This ranks
-- those silent shoppers by the money at stake and suggests one small,
-- concrete offer each. The policy follows published field evidence:
--   * a small credit, never a bare apology (Halperin, Ho, List & Muir: a coupon
--     lifted spend, an apology alone did nothing, repeated apologies backfired);
--   * one offer per shopper, however many stock-outs hit them;
--   * repeat hits weigh more (Knox & van Oest: a second failure soon after the
--     first is the worst case);
--   * no blanket discount (Anderson, Fitzsimons & Simester);
--   * name a substitute the shopper has bought before (Hoang & Breugelmans).

CREATE OR REPLACE TABLE RIPPLE.MAKEGOOD_POLICY AS
SELECT 'credit_substituted' AS ITEM, 40 AS VAL, 'Credit (INR) after a swapped item' AS NOTE FROM DUAL
UNION ALL SELECT 'credit_missing', 60, 'Credit (INR) after a missing item' FROM DUAL
UNION ALL SELECT 'credit_repeat', 90, 'Credit (INR) after two or more hits within four weeks' FROM DUAL
UNION ALL SELECT 'repeat_multiplier', 1.5, 'Assumed extra churn risk for a repeat hit (Knox & van Oest), until measured' FROM DUAL
UNION ALL SELECT 'recovery_rate', 0.35, 'Assumed share of at-risk value a credit wins back (recovery only partly offsets a failure)' FROM DUAL;

-- One row per hit shopper with everything the offer depends on.
CREATE OR REPLACE TABLE RIPPLE.MAKEGOOD_BASE AS
WITH hits AS (
    SELECT x.PERSON_ID, x.EPISODE_ID, e.STORE_ID, x.SKU_ID, x.LINE_STATUS, x.ORDER_DATE
    FROM RIPPLE.EPISODE_EXPOSURES x JOIN RIPPLE.EPISODES e ON e.EPISODE_ID = x.EPISODE_ID
), per_person AS (
    SELECT PERSON_ID,
           COUNT(DISTINCT EPISODE_ID) AS EPISODES_HIT,
           MAX(CASE WHEN LINE_STATUS = 'missing' THEN 1 ELSE 0 END) AS ANY_MISSING,
           MIN(ORDER_DATE) AS FIRST_HIT, MAX(ORDER_DATE) AS LAST_HIT
    FROM hits GROUP BY PERSON_ID
), worst AS (
    -- The most recent, most serious hit is what the message refers to.
    SELECT PERSON_ID, EPISODE_ID, STORE_ID, SKU_ID, LINE_STATUS, ORDER_DATE FROM (
        SELECT h.*, ROW_NUMBER() OVER (PARTITION BY PERSON_ID
               ORDER BY CASE LINE_STATUS WHEN 'missing' THEN 0 ELSE 1 END, ORDER_DATE DESC) AS RN
        FROM hits h) WHERE RN = 1
), wrote_in AS (
    SELECT DISTINCT PERSON_ID FROM RIPPLE.LEDGER WHERE ENTRY = 'ticket'
), last_order AS (
    SELECT PERSON_ID, MAX(ORDER_DATE) AS LAST_ORDER FROM RIPPLE.ORDERS_P GROUP BY PERSON_ID
)
SELECT p.PERSON_ID, p.EPISODES_HIT, p.FIRST_HIT, p.LAST_HIT,
       CASE WHEN p.EPISODES_HIT >= 2 AND DAYS_BETWEEN(p.LAST_HIT, p.FIRST_HIT) <= 28 THEN 1 ELSE 0 END AS REPEAT_HIT,
       CASE WHEN p.ANY_MISSING = 1 THEN 'missing' ELSE 'substituted' END AS KIND,
       w.EPISODE_ID, w.STORE_ID, w.SKU_ID, w.ORDER_DATE AS HIT_DATE,
       CASE WHEN wi.PERSON_ID IS NULL THEN 1 ELSE 0 END AS SILENT,
       lo.LAST_ORDER, COALESCE(v.CLV_6M, 0) AS CLV_6M
FROM per_person p
JOIN worst w ON w.PERSON_ID = p.PERSON_ID
LEFT JOIN wrote_in wi ON wi.PERSON_ID = p.PERSON_ID
LEFT JOIN last_order lo ON lo.PERSON_ID = p.PERSON_ID
LEFT JOIN RIPPLE.PERSON_VALUE v ON v.PERSON_ID = p.PERSON_ID;

-- A substitute this shopper already trusts: their most-bought sibling of the
-- missing SKU, else the sibling their store sells most.
CREATE OR REPLACE TABLE RIPPLE.MAKEGOOD_SUBSTITUTE AS
WITH sib AS (
    SELECT b.PERSON_ID, s2.SKU_ID AS SUB_SKU
    FROM RIPPLE.MAKEGOOD_BASE b
    JOIN RIPPLE_RAW.SKUS s1 ON s1.SKU_ID = b.SKU_ID
    JOIN RIPPLE_RAW.SKUS s2 ON s2.SUBSTITUTE_GROUP = s1.SUBSTITUTE_GROUP AND s2.SKU_ID <> s1.SKU_ID
), own AS (
    SELECT sib.PERSON_ID, sib.SUB_SKU, COUNT(*) AS BOUGHT
    FROM sib
    JOIN RIPPLE.ORDERS_P o ON o.PERSON_ID = sib.PERSON_ID
    JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID AND l.FULFILLED_SKU_ID = sib.SUB_SKU
    GROUP BY sib.PERSON_ID, sib.SUB_SKU
), store_best AS (
    SELECT b.PERSON_ID, sib.SUB_SKU, SUM(sd.UNITS) AS STORE_UNITS
    FROM RIPPLE.MAKEGOOD_BASE b
    JOIN sib ON sib.PERSON_ID = b.PERSON_ID
    JOIN RIPPLE_RAW.SALES_DAILY sd ON sd.STORE_ID = b.STORE_ID AND sd.SKU_ID = sib.SUB_SKU
    GROUP BY b.PERSON_ID, sib.SUB_SKU
)
SELECT PERSON_ID, SUB_SKU, BOUGHT_BEFORE FROM (
    SELECT sb.PERSON_ID, sb.SUB_SKU, COALESCE(o.BOUGHT, 0) AS BOUGHT_BEFORE,
           ROW_NUMBER() OVER (PARTITION BY sb.PERSON_ID ORDER BY COALESCE(o.BOUGHT, 0) DESC, sb.STORE_UNITS DESC) AS RN
    FROM store_best sb LEFT JOIN own o ON o.PERSON_ID = sb.PERSON_ID AND o.SUB_SKU = sb.SUB_SKU
) WHERE RN = 1;

-- The list: silent shoppers whose expected recovered margin beats the credit.
CREATE OR REPLACE TABLE RIPPLE.MAKEGOOD_LIST AS
WITH pol AS (
    SELECT MAX(CASE WHEN ITEM = 'credit_substituted' THEN VAL END) AS C_SUB,
           MAX(CASE WHEN ITEM = 'credit_missing' THEN VAL END) AS C_MISS,
           MAX(CASE WHEN ITEM = 'credit_repeat' THEN VAL END) AS C_REP,
           MAX(CASE WHEN ITEM = 'repeat_multiplier' THEN VAL END) AS REP_MULT,
           MAX(CASE WHEN ITEM = 'recovery_rate' THEN VAL END) AS RECOVERY_RATE
    FROM RIPPLE.MAKEGOOD_POLICY
), scored AS (
    SELECT b.*, ce.ATT_LOST_RATE * CASE WHEN b.REPEAT_HIT = 1 THEN pol.REP_MULT ELSE 1 END AS CHURN_LIFT,
           CASE WHEN b.REPEAT_HIT = 1 THEN pol.C_REP WHEN b.KIND = 'missing' THEN pol.C_MISS ELSE pol.C_SUB END AS CREDIT_INR,
           pol.RECOVERY_RATE
    FROM RIPPLE.MAKEGOOD_BASE b
    JOIN RIPPLE.CAUSAL_EFFECTS ce ON ce.KIND = b.KIND
    CROSS JOIN pol
    WHERE b.SILENT = 1
)
SELECT ROW_NUMBER() OVER (ORDER BY s.CHURN_LIFT * s.CLV_6M * s.RECOVERY_RATE - s.CREDIT_INR DESC, s.PERSON_ID) AS PRIORITY,
       s.PERSON_ID, s.KIND, s.REPEAT_HIT, s.EPISODES_HIT, s.HIT_DATE, s.EPISODE_ID, s.STORE_ID,
       st.NAME AS STORE_NAME, s.SKU_ID, k.NAME AS SKU_NAME, sub.SUB_SKU, ks.NAME AS SUB_NAME, sub.BOUGHT_BEFORE,
       s.CLV_6M, s.CHURN_LIFT, s.CHURN_LIFT * s.CLV_6M AS AT_RISK_INR, s.CREDIT_INR,
       s.CHURN_LIFT * s.CLV_6M * s.RECOVERY_RATE AS EXPECTED_RECOVERED_INR,
       s.CHURN_LIFT * s.CLV_6M * s.RECOVERY_RATE - s.CREDIT_INR AS NET_INR,
       s.LAST_ORDER,
       'Sorry your ' || k.NAME || ' ' || CASE s.KIND WHEN 'missing' THEN 'didn''t arrive' ELSE 'was swapped' END
         || ' on ' || TO_CHAR(s.HIT_DATE, 'DD Mon') || '. We''ve added Rs ' || TO_CHAR(s.CREDIT_INR)
         || ' to your account.' || CASE WHEN sub.SUB_SKU IS NOT NULL
              THEN ' If it''s ever short again, we''ll send ' || ks.NAME || ' instead.' ELSE '' END AS MESSAGE
FROM scored s
JOIN RIPPLE_RAW.SKUS k ON k.SKU_ID = s.SKU_ID
JOIN RIPPLE_RAW.STORES st ON st.STORE_ID = s.STORE_ID
LEFT JOIN RIPPLE.MAKEGOOD_SUBSTITUTE sub ON sub.PERSON_ID = s.PERSON_ID
LEFT JOIN RIPPLE_RAW.SKUS ks ON ks.SKU_ID = sub.SUB_SKU
WHERE s.CHURN_LIFT * s.CLV_6M * s.RECOVERY_RATE > s.CREDIT_INR;
