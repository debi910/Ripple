-- Engine 2: identity resolution.
-- One shopper owns several accounts (app, web, loyalty card, WhatsApp) and
-- writes to support from yet another address. We normalise contact points,
-- block candidate pairs, score them with Fellegi-Sunter style log-odds
-- weights, and close the graph with a Lua label-propagation script, all in
-- Exasol.

-- 1. Normalised keys per account.
CREATE OR REPLACE TABLE RIPPLE.ACCOUNT_KEYS AS
WITH base AS (
    SELECT ACCOUNT_ID, CHANNEL, PINCODE,
           TRIM(REGEXP_REPLACE(REGEXP_REPLACE(LOWER(DISPLAY_NAME), '[''.]', ' '), ' +', ' ')) AS NAME_N,
           LOWER(TRIM(EMAIL)) AS EMAIL_L,
           REGEXP_REPLACE(PHONE, '[^0-9]', '') AS PHONE_D
    FROM RIPPLE_RAW.ACCOUNTS
), em AS (
    SELECT b.*,
           REGEXP_REPLACE(SUBSTR(EMAIL_L, 1, INSTR(EMAIL_L, '@') - 1), '\+.*$', '') AS LOCAL_PART,
           SUBSTR(EMAIL_L, INSTR(EMAIL_L, '@') + 1) AS EMAIL_DOMAIN
    FROM base b
)
SELECT ACCOUNT_ID, CHANNEL, PINCODE, NAME_N,
       REGEXP_SUBSTR(NAME_N, '^[a-z]+') AS NAME_FIRST,
       CASE WHEN INSTR(NAME_N, ' ') > 0 THEN REGEXP_SUBSTR(NAME_N, '[a-z]+$') END AS NAME_LAST,
       CASE WHEN EMAIL_L IS NULL OR EMAIL_L = '' THEN NULL
            WHEN EMAIL_DOMAIN = 'gmail.com' THEN REPLACE(LOCAL_PART, '.', '') || '@gmail.com'
            ELSE LOCAL_PART || '@' || EMAIL_DOMAIN END AS EMAIL_N,
       CASE WHEN LENGTH(PHONE_D) >= 10 THEN SUBSTR(PHONE_D, LENGTH(PHONE_D) - 9) END AS PHONE_N
FROM em;

-- How many distinct first names hide behind one phone number. A family phone
-- shared by "Priya" and "Rahul" must not merge them.
CREATE OR REPLACE TABLE RIPPLE.PHONE_SHARING AS
SELECT PHONE_N, COUNT(DISTINCT SOUNDEX(NAME_FIRST)) AS FIRST_NAMES
FROM RIPPLE.ACCOUNT_KEYS WHERE PHONE_N IS NOT NULL AND LENGTH(NAME_FIRST) > 1 GROUP BY PHONE_N;

-- 2. Blocking: only accounts sharing an email, a phone, or (pincode, surname sound, initial) are compared.
CREATE OR REPLACE TABLE RIPPLE.ID_CANDIDATES AS
SELECT DISTINCT LEAST(a.ACCOUNT_ID, b.ACCOUNT_ID) AS A, GREATEST(a.ACCOUNT_ID, b.ACCOUNT_ID) AS B
FROM RIPPLE.ACCOUNT_KEYS a JOIN RIPPLE.ACCOUNT_KEYS b
  ON a.EMAIL_N = b.EMAIL_N AND a.ACCOUNT_ID < b.ACCOUNT_ID
UNION
SELECT a.ACCOUNT_ID, b.ACCOUNT_ID
FROM RIPPLE.ACCOUNT_KEYS a JOIN RIPPLE.ACCOUNT_KEYS b
  ON a.PHONE_N = b.PHONE_N AND a.ACCOUNT_ID < b.ACCOUNT_ID
UNION
SELECT a.ACCOUNT_ID, b.ACCOUNT_ID
FROM RIPPLE.ACCOUNT_KEYS a JOIN RIPPLE.ACCOUNT_KEYS b
  ON a.PINCODE = b.PINCODE AND SOUNDEX(a.NAME_LAST) = SOUNDEX(b.NAME_LAST)
 AND SUBSTR(a.NAME_FIRST, 1, 1) = SUBSTR(b.NAME_FIRST, 1, 1) AND a.ACCOUNT_ID < b.ACCOUNT_ID;

-- 3. Behavioural fingerprint: people are creatures of habit, so two accounts
--    of one shopper buy the same things. Cosine similarity of SKU purchase
--    vectors, computed only for candidate pairs.
CREATE OR REPLACE TABLE RIPPLE.ACCOUNT_SKU AS
SELECT o.ACCOUNT_ID, l.SKU_ID, COUNT(*) AS N
FROM RIPPLE_RAW.ORDERS o JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
GROUP BY o.ACCOUNT_ID, l.SKU_ID;

CREATE OR REPLACE TABLE RIPPLE.ID_BASKET_SIM AS
WITH norms AS (
    SELECT ACCOUNT_ID, SQRT(SUM(N * N)) AS NORM, SUM(N) AS LINES FROM RIPPLE.ACCOUNT_SKU GROUP BY ACCOUNT_ID
)
SELECT c.A, c.B, SUM(a.N * b.N) / (MIN(na.NORM) * MIN(nb.NORM)) AS COSINE,
       LEAST(MIN(na.LINES), MIN(nb.LINES)) AS MIN_LINES
FROM RIPPLE.ID_CANDIDATES c
JOIN RIPPLE.ACCOUNT_SKU a ON a.ACCOUNT_ID = c.A
JOIN RIPPLE.ACCOUNT_SKU b ON b.ACCOUNT_ID = c.B AND b.SKU_ID = a.SKU_ID
JOIN norms na ON na.ACCOUNT_ID = c.A
JOIN norms nb ON nb.ACCOUNT_ID = c.B
GROUP BY c.A, c.B;

-- 4. Pair scores. Weights are log-odds style: agreement on a rare, personal
-- key is strong evidence, disagreement on the name is strong counter-evidence.
CREATE OR REPLACE TABLE RIPPLE.ID_PAIRS AS
WITH f AS (
    SELECT c.A, c.B,
           CASE WHEN a.EMAIL_N = b.EMAIL_N THEN 1 ELSE 0 END AS EMAIL_EQ,
           CASE WHEN a.PHONE_N = b.PHONE_N THEN 1 ELSE 0 END AS PHONE_EQ,
           COALESCE(ps.FIRST_NAMES, 1) AS PHONE_NAMES,
           CASE WHEN a.PINCODE = b.PINCODE THEN 1 ELSE 0 END AS PIN_EQ,
           COALESCE(bs.COSINE, 0) AS BASKET_COS, COALESCE(bs.MIN_LINES, 0) AS MIN_LINES,
           CASE
             WHEN a.NAME_N = b.NAME_N THEN 'exact'
             WHEN a.NAME_FIRST = b.NAME_LAST AND a.NAME_LAST = b.NAME_FIRST THEN 'exact'
             WHEN a.NAME_LAST IS NOT NULL AND b.NAME_LAST IS NOT NULL
                  AND EDIT_DISTANCE(a.NAME_N, b.NAME_N) <= 2 THEN 'close'
             WHEN a.NAME_LAST = b.NAME_LAST AND (LENGTH(a.NAME_FIRST) = 1 OR LENGTH(b.NAME_FIRST) = 1)
                  AND SUBSTR(a.NAME_FIRST, 1, 1) = SUBSTR(b.NAME_FIRST, 1, 1) THEN 'initial'
             WHEN (a.NAME_LAST IS NULL OR b.NAME_LAST IS NULL)
                  AND EDIT_DISTANCE(a.NAME_FIRST, b.NAME_FIRST) <= 1 THEN 'first_only'
             ELSE 'differ'
           END AS NAME_AGREE
    FROM RIPPLE.ID_CANDIDATES c
    JOIN RIPPLE.ACCOUNT_KEYS a ON a.ACCOUNT_ID = c.A
    JOIN RIPPLE.ACCOUNT_KEYS b ON b.ACCOUNT_ID = c.B
    LEFT JOIN RIPPLE.PHONE_SHARING ps ON ps.PHONE_N = a.PHONE_N
    LEFT JOIN RIPPLE.ID_BASKET_SIM bs ON bs.A = c.A AND bs.B = c.B
)
SELECT f.*,
       10 * EMAIL_EQ
     + CASE WHEN PHONE_EQ = 1 AND PHONE_NAMES <= 2 THEN 6 WHEN PHONE_EQ = 1 THEN 4 ELSE 0 END
     + PIN_EQ
     + CASE WHEN PHONE_EQ = 1 AND PIN_EQ = 1 THEN 3 ELSE 0 END
     + CASE WHEN BASKET_COS >= 0.35 THEN 3 WHEN BASKET_COS >= 0.2 THEN 1.5
            WHEN BASKET_COS < 0.05 AND MIN_LINES >= 8 THEN -1 ELSE 0 END
     + CASE NAME_AGREE WHEN 'exact' THEN 3 WHEN 'close' THEN 2 WHEN 'initial' THEN 1.5
                       WHEN 'first_only' THEN 1 ELSE -4 END AS SCORE
FROM f;

CREATE OR REPLACE TABLE RIPPLE.ID_EDGES AS
SELECT A, B, SCORE FROM RIPPLE.ID_PAIRS WHERE SCORE >= 6;

-- 5. Connected components by label propagation, driven by a Lua script that
-- runs inside the database until no label changes.
CREATE OR REPLACE LUA SCRIPT RIPPLE.RESOLVE_CLUSTERS() RETURNS ROWCOUNT AS
    query([[CREATE OR REPLACE TABLE RIPPLE.ID_LABEL AS
            SELECT ACCOUNT_ID, ACCOUNT_ID AS LABEL FROM RIPPLE.ACCOUNT_KEYS]])
    local changed, rounds = 1, 0
    while changed > 0 and rounds < 50 do
        rounds = rounds + 1
        local r = query([[MERGE INTO RIPPLE.ID_LABEL t USING (
                SELECT x.ACCOUNT_ID, MIN(l.LABEL) AS NEW_LABEL
                FROM (SELECT A AS ACCOUNT_ID, B AS NB FROM RIPPLE.ID_EDGES
                      UNION ALL SELECT B, A FROM RIPPLE.ID_EDGES) x
                JOIN RIPPLE.ID_LABEL l ON l.ACCOUNT_ID = x.NB
                GROUP BY x.ACCOUNT_ID) s
            ON t.ACCOUNT_ID = s.ACCOUNT_ID
            WHEN MATCHED THEN UPDATE SET t.LABEL = s.NEW_LABEL WHERE s.NEW_LABEL < t.LABEL]])
        changed = r.rows_affected
    end
    exit({rows_affected = rounds})
/

EXECUTE SCRIPT RIPPLE.RESOLVE_CLUSTERS();

CREATE OR REPLACE TABLE RIPPLE.ACCOUNT_PERSON AS
SELECT ACCOUNT_ID, LABEL AS PERSON_ID FROM RIPPLE.ID_LABEL;

-- Every contact point we know for a resolved person, so tickets can find their owner.
CREATE OR REPLACE TABLE RIPPLE.CONTACT_POINTS AS
SELECT DISTINCT 'email' AS KIND, k.EMAIL_N AS VAL, p.PERSON_ID
FROM RIPPLE.ACCOUNT_KEYS k JOIN RIPPLE.ACCOUNT_PERSON p ON p.ACCOUNT_ID = k.ACCOUNT_ID WHERE k.EMAIL_N IS NOT NULL
UNION
SELECT DISTINCT 'phone', k.PHONE_N, p.PERSON_ID
FROM RIPPLE.ACCOUNT_KEYS k JOIN RIPPLE.ACCOUNT_PERSON p ON p.ACCOUNT_ID = k.ACCOUNT_ID WHERE k.PHONE_N IS NOT NULL;

-- Orders keyed to the person, not the account.
CREATE OR REPLACE TABLE RIPPLE.ORDERS_P AS
SELECT o.ORDER_ID, o.ACCOUNT_ID, p.PERSON_ID, o.STORE_ID, o.ORDERED_AT, CAST(o.ORDERED_AT AS DATE) AS ORDER_DATE
FROM RIPPLE_RAW.ORDERS o JOIN RIPPLE.ACCOUNT_PERSON p ON p.ACCOUNT_ID = o.ACCOUNT_ID;
