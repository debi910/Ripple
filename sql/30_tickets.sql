-- Engine 3: ticket understanding.
-- A Python UDF reads each ticket inside Exasol: intent (including Hinglish and
-- typos), then which exact SKU the customer means. "the milk" only becomes a
-- SKU once identity resolution tells us which orders this person placed.

CREATE OR REPLACE PYTHON3 SCALAR SCRIPT RIPPLE.TICKET_INTENT(ticket_id DECIMAL(12,0), body VARCHAR(2000))
EMITS (ticket_id DECIMAL(12,0), intent VARCHAR(40), confidence DOUBLE, stock_signal BOOLEAN) AS
import re

def squash(s):
    # Customers double and drop letters; collapse repeats on both sides.
    return re.sub(r"(.)\1+", r"\1", s.lower())

RULES = {
    "substitution_complaint": [(r"instead", 3), (r"in place of", 3), (r"replace", 3), (r"swap", 3),
                               (r"substitut", 3), (r"other brand", 2), (r"bhej diya", 3), (r"not what i paid", 2),
                               (r"did not want", 1), (r"quality is not same", 2)],
    "missing_item": [(r"mis+ing", 3), (r"without the", 3), (r"not in the bag", 3), (r"nahi aya", 3),
                     (r"cancel+ed .* after i paid", 3), (r"charged for it", 2), (r"was not in", 2),
                     (r"refund", 0.5)],
    "availability_query": [(r"back in stock", 4), (r"available again", 4), (r"restock", 3), (r"notify me", 3),
                           (r"kab ayega", 4), (r"discontinued", 3), (r"out of stock since", 3),
                           (r"in stock but", 4), (r"never gets delivered", 3), (r"is available", 2),
                           (r"cant find", 2)],
    "late_delivery": [(r"\blate\b", 3), (r"delay", 3), (r"still waiting", 3), (r"rider", 2), (r"minute delivery", 2)],
    "quality_issue": [(r"expi?r", 3), (r"torn", 3), (r"spoil", 3), (r"damaged", 3)],
    "payment_issue": [(r"debited", 3), (r"refund not", 3), (r"upi", 3), (r"payment", 2), (r"coupon", 3),
                      (r"deducted", 2)],
    "account_closure": [(r"delete my", 4), (r"close my acount", 4), (r"unsubscribe", 4), (r"deactivate", 4),
                        (r"band karo", 4), (r"switching to", 3), (r"done with this", 3)],
    "general": [(r"how do i", 2), (r"how to", 2), (r"can i", 1.5), (r"do you deliver", 2), (r"crash", 2)],
}
COMPILED = {k: [(re.compile(squash(p)), w) for p, w in v] for k, v in RULES.items()}
STOCK = {"substitution_complaint", "missing_item", "availability_query"}

def run(ctx):
    text = squash(ctx.body or "")
    scores = {k: sum(w for rx, w in rules if rx.search(text)) for k, rules in COMPILED.items()}
    best = max(scores, key=scores.get)
    total = sum(scores.values())
    if scores[best] == 0:
        ctx.emit(ctx.ticket_id, "general", 0.2, False)
        return
    ctx.emit(ctx.ticket_id, best, round(scores[best] / total, 3), best in STOCK)
/

-- Scores candidate SKUs ("sku_id|name|flag" separated by ';') against the text.
-- flag = 1 marks a line that was missing or substituted, which is the likelier subject.
CREATE OR REPLACE PYTHON3 SCALAR SCRIPT RIPPLE.PRODUCT_MATCH(ticket_id DECIMAL(12,0), store_id DECIMAL(9,0), body VARCHAR(2000), candidates VARCHAR(2000000))
EMITS (ticket_id DECIMAL(12,0), store_id DECIMAL(9,0), sku_id DECIMAL(9,0), match_score DOUBLE) AS
import re

STOP = {"the", "and", "of", "a", "in", "pcs", "tabs", "pack", "sachets", "fresh"}

def squash(s):
    return re.sub(r"(.)\1+", r"\1", s.lower())

def tokens(s):
    return [t for t in re.findall(r"[a-z]+", squash(s)) if len(t) > 2 and t not in STOP]

def close(a, b):
    if a == b:
        return True
    if len(a) < 5 or abs(len(a) - len(b)) > 1:
        return False
    # one dropped letter
    if len(a) > len(b):
        a, b = b, a
    return any(b[:i] + b[i + 1:] == a for i in range(len(b)))

def run(ctx):
    if not ctx.candidates:
        ctx.emit(ctx.ticket_id, ctx.store_id, None, 0.0)
        return
    words = tokens(ctx.body or "")
    best, best_score = None, 0.0
    for cand in ctx.candidates.split(";"):
        parts = cand.split("|")
        if len(parts) != 3:
            continue
        sku, name, flag = parts
        sku_tokens = tokens(name)
        hits = sum(1 for t in sku_tokens if any(close(t, w) for w in words))
        score = hits / max(1, len(sku_tokens)) * 2 + hits + (0.75 if flag == "1" else 0)
        if hits and score > best_score:
            best, best_score = int(sku), score
    ctx.emit(ctx.ticket_id, ctx.store_id, best, round(best_score, 3))
/

-- 1. Who wrote each ticket: order reference first, then email, then phone.
CREATE OR REPLACE TABLE RIPPLE.TICKET_OWNER AS
WITH t AS (
    SELECT TICKET_ID, CREATED_AT, CAST(CREATED_AT AS DATE) AS TICKET_DATE, BODY,
           CAST(NULLIF(REGEXP_REPLACE(ORDER_REF, '[^0-9]', ''), '') AS DECIMAL(12,0)) AS REF_ORDER,
           CASE WHEN FROM_EMAIL IS NULL OR FROM_EMAIL = '' THEN NULL
                WHEN LOWER(FROM_EMAIL) LIKE '%@gmail.com'
                  THEN REPLACE(REGEXP_REPLACE(SUBSTR(LOWER(FROM_EMAIL), 1, INSTR(FROM_EMAIL, '@') - 1), '\+.*$', ''), '.', '') || '@gmail.com'
                ELSE REGEXP_REPLACE(SUBSTR(LOWER(FROM_EMAIL), 1, INSTR(FROM_EMAIL, '@') - 1), '\+.*$', '')
                     || SUBSTR(LOWER(FROM_EMAIL), INSTR(FROM_EMAIL, '@')) END AS EMAIL_N,
           CASE WHEN LENGTH(REGEXP_REPLACE(FROM_PHONE, '[^0-9]', '')) >= 10
                THEN SUBSTR(REGEXP_REPLACE(FROM_PHONE, '[^0-9]', ''), LENGTH(REGEXP_REPLACE(FROM_PHONE, '[^0-9]', '')) - 9) END AS PHONE_N
    FROM RIPPLE_RAW.TICKETS
)
SELECT t.TICKET_ID, t.CREATED_AT, t.TICKET_DATE, t.BODY, t.REF_ORDER,
       COALESCE(o.PERSON_ID, ce.PERSON_ID, cp.PERSON_ID) AS PERSON_ID,
       CASE WHEN o.PERSON_ID IS NOT NULL THEN 'order_ref' WHEN ce.PERSON_ID IS NOT NULL THEN 'email'
            WHEN cp.PERSON_ID IS NOT NULL THEN 'phone' ELSE 'unresolved' END AS LINKED_BY
FROM t
LEFT JOIN RIPPLE.ORDERS_P o ON o.ORDER_ID = t.REF_ORDER
LEFT JOIN (SELECT VAL, MIN(PERSON_ID) AS PERSON_ID FROM RIPPLE.CONTACT_POINTS WHERE KIND = 'email' GROUP BY VAL) ce
       ON ce.VAL = t.EMAIL_N
LEFT JOIN (SELECT VAL, MIN(PERSON_ID) AS PERSON_ID FROM RIPPLE.CONTACT_POINTS WHERE KIND = 'phone' GROUP BY VAL) cp
       ON cp.VAL = t.PHONE_N;

-- 2. Intent.
CREATE OR REPLACE TABLE RIPPLE.TICKET_INTENTS AS
SELECT RIPPLE.TICKET_INTENT(TICKET_ID, BODY) FROM RIPPLE_RAW.TICKETS;

-- 3. Candidate products: what this person ordered in the 3 days before writing
--    (or the referenced order), with problem lines flagged.
CREATE OR REPLACE TABLE RIPPLE.TICKET_CANDIDATES AS
SELECT tw.TICKET_ID,
       LISTAGG(DISTINCT l.SKU_ID || '|' || s.NAME || '|' || CASE WHEN l.LINE_STATUS <> 'fulfilled' THEN '1' ELSE '0' END, ';')
         WITHIN GROUP (ORDER BY l.SKU_ID) AS CANDIDATES,
       MIN(o.STORE_ID) AS STORE_ID
FROM RIPPLE.TICKET_OWNER tw
JOIN (SELECT tw2.TICKET_ID, o.ORDER_ID, o.STORE_ID FROM RIPPLE.TICKET_OWNER tw2
      JOIN RIPPLE.ORDERS_P o ON o.ORDER_ID = tw2.REF_ORDER
      UNION ALL
      SELECT tw2.TICKET_ID, o.ORDER_ID, o.STORE_ID FROM RIPPLE.TICKET_OWNER tw2
      JOIN RIPPLE.ORDERS_P o ON tw2.REF_ORDER IS NULL AND o.PERSON_ID = tw2.PERSON_ID
       AND o.ORDER_DATE BETWEEN tw2.TICKET_DATE - 3 AND tw2.TICKET_DATE) o ON o.TICKET_ID = tw.TICKET_ID
JOIN RIPPLE_RAW.ORDER_LINES l ON l.ORDER_ID = o.ORDER_ID
JOIN RIPPLE_RAW.SKUS s ON s.SKU_ID = l.SKU_ID
JOIN RIPPLE.TICKET_INTENTS i ON i.TICKET_ID = tw.TICKET_ID AND i.INTENT IN ('substitution_complaint', 'missing_item', 'quality_issue')
GROUP BY tw.TICKET_ID;

-- Availability questions name a product the customer could not order, so
-- they are matched against the catalogue of the shopper's usual store.
CREATE OR REPLACE TABLE RIPPLE.PERSON_HOME_STORE AS
SELECT PERSON_ID, STORE_ID FROM (
    SELECT PERSON_ID, STORE_ID, ROW_NUMBER() OVER (PARTITION BY PERSON_ID ORDER BY COUNT(*) DESC, STORE_ID) AS RN
    FROM RIPPLE.ORDERS_P GROUP BY PERSON_ID, STORE_ID) WHERE RN = 1;

-- Candidates for an availability question: the whole catalogue of the shopper's
-- usual store, with SKUs the book shows as out of stock that day flagged.
CREATE OR REPLACE TABLE RIPPLE.TICKET_AVAIL_CANDIDATES AS
SELECT tw.TICKET_ID, h.STORE_ID,
       LISTAGG(s.SKU_ID || '|' || s.NAME || '|' || CASE WHEN b.BOOK_QTY = 0 THEN '1' ELSE '0' END, ';')
         WITHIN GROUP (ORDER BY s.SKU_ID) AS CANDIDATES
FROM RIPPLE.TICKET_OWNER tw
JOIN RIPPLE.TICKET_INTENTS i ON i.TICKET_ID = tw.TICKET_ID AND i.INTENT = 'availability_query'
JOIN RIPPLE.PERSON_HOME_STORE h ON h.PERSON_ID = tw.PERSON_ID
CROSS JOIN RIPPLE_RAW.SKUS s
LEFT JOIN RIPPLE_RAW.INVENTORY_BOOK b
       ON b.STORE_ID = h.STORE_ID AND b.SKU_ID = s.SKU_ID AND b.SNAPSHOT_DATE = tw.TICKET_DATE - 1
GROUP BY tw.TICKET_ID, h.STORE_ID;

CREATE OR REPLACE TABLE RIPPLE.TICKET_PRODUCT AS
SELECT RIPPLE.PRODUCT_MATCH(c.TICKET_ID, c.STORE_ID, tw.BODY, c.CANDIDATES)
FROM RIPPLE.TICKET_CANDIDATES c JOIN RIPPLE.TICKET_OWNER tw ON tw.TICKET_ID = c.TICKET_ID
UNION ALL
SELECT RIPPLE.PRODUCT_MATCH(c.TICKET_ID, c.STORE_ID, tw.BODY, c.CANDIDATES)
FROM RIPPLE.TICKET_AVAIL_CANDIDATES c JOIN RIPPLE.TICKET_OWNER tw ON tw.TICKET_ID = c.TICKET_ID;

-- 4. One row per ticket with everything Ripple knows about it.
CREATE OR REPLACE TABLE RIPPLE.TICKETS_ENRICHED AS
SELECT tw.TICKET_ID, tw.CREATED_AT, tw.TICKET_DATE, tw.PERSON_ID, tw.LINKED_BY, tw.REF_ORDER,
       i.INTENT, i.CONFIDENCE, i.STOCK_SIGNAL,
       p.STORE_ID, CASE WHEN p.MATCH_SCORE >= 2 THEN p.SKU_ID END AS SKU_ID, p.MATCH_SCORE,
       tw.BODY
FROM RIPPLE.TICKET_OWNER tw
JOIN RIPPLE.TICKET_INTENTS i ON i.TICKET_ID = tw.TICKET_ID
LEFT JOIN RIPPLE.TICKET_PRODUCT p ON p.TICKET_ID = tw.TICKET_ID;
