# Ripple

**The full bill of every stock-out.** Ripple runs on Exasol Personal. It
catches *phantom* stock-outs (the system says in stock, the shelf is empty)
about a day and a half after they start, two weeks before the stock record
would be corrected. It then follows every affected shopper, merged across
duplicate accounts, through the substitution, the return, the angry ticket and
the quiet exit, and prices each step with a receipt.

> A stock-out is not one lost sale. On our demo retailer, the lost-sales view
> says **₹4.4 lakh**. Ripple's ledger says **₹25.1 lakh**: 5.7 times as much,
> spread across three systems that never talk to each other.

Track 2 of the Exasol hackathon (Customers, Channels & Demand) lists four
problems. Ripple treats them as one causal chain, because in real life they
are: a stock-out found too late becomes a return that erodes margin, then a
churn signal sitting in a support ticket, written by a customer each system
sees differently.

---

## The problem

**Who has it:** quick-commerce and omnichannel grocers. Their dark stores
promise ten-minute delivery from inventory that is wrong more often than anyone
admits.

**Why it matters:**

* Inventory distortion costs retail about **$1.7 trillion a year**, and
  out-of-stocks account for about $1.2 trillion of that
  ([IHL Group](https://www.ihlservices.com/product/fixing-inventory-distortion-whos-winning-whos-failing-whats-working/)).
* Audits of major chains found errors in **more than 65% of SKU-store
  inventory records**. *Phantom inventory* never raises a stock-out alert,
  because the system believes the shelf is full
  ([Farias, Li & Peng](https://arxiv.org/pdf/2006.13126v1)).
* Shoppers return about **16% of what they buy**, around $850B in the US in 2025
  ([NRF via SupplyChain247](https://www.supplychain247.com/article/2025-retail-returns-hit-850-billion)).
* Most unhappy customers never complain. Each ticket stands for several silent
  ones.

**What existing tools miss:** each tool sees one system. Demand planners
see stock records, not the customer saying "app shows in stock but never
delivers". Returns platforms record "not as expected", not "this was a
substitute for an item we didn't have". Helpdesk AI scores tickets, not people,
so it can't see that the same shopper also had a missing item under another
email. The cost of a stock-out ends up split across systems and is never added
up.

## What Ripple does

1. **Detects phantom stock-outs early.** A Bayesian filter for each SKU in each
   store reads four systems at once: POS sales, order-management short picks,
   picker exception logs and customer tickets. It calibrates itself from the
   retailer's own past cycle counts.
2. **Resolves who the customer really is.** Accounts are merged across app,
   web, loyalty and WhatsApp using contact normalisation, fuzzy names, shared
   phones (with a household guard) and a purchase-basket fingerprint. A Lua
   script closes the graph inside Exasol.
3. **Reads the tickets.** In-database Python UDFs read intent (Hinglish and
   typos included) and work out *which* SKU "the milk" means from what that
   person just ordered.
4. **Measures the churn a stock-out causes, not the churn that follows it.**
   Phantoms strike at random, so they form a natural experiment. Ripple
   compares shoppers who hit one with matched shoppers at the same store who did
   not, the same week.
5. **Writes the ledger.** Every rupee is a receipt pointing at an order line,
   a return, a ticket or a person.
6. **Tells each store what to count tomorrow,** ranked by expected money saved
   before the next scheduled count, not by probability alone.

## Why this is not another dashboard

* **Measured accuracy.** The simulator writes an answer key that Ripple never
  reads. Every number below is scored against it, live, on the Proof tab.
* **An ablation that shows why joining silos matters.** The same filter with
  sales alone catches 65% of phantoms, about eight days late. With all four
  systems it catches 88% in about a day and a half.
* **A causal estimate, not a correlation.** Shoppers who hit a stock-out
  differ from those who don't. The matched design removes that, and the Proof
  tab checks the estimate against the true effect.
* **Receipts.** Click any shopper and see every cost line with its source row.
* **Self-calibration.** No hand-tuned thresholds. The detector learns its
  emission rates from cycle counts the retailer already has.

## Results (demo world, seed 42)

12 dark stores · 267 SKUs · 40,000 shoppers with 70,107 accounts · 120 days ·
266k orders · 841k order lines · 11.7k tickets · 526 injected phantom stock-outs

| Engine | Metric | Result |
|---|---|---|
| Phantom detector, all four systems | stock-outs caught / alert precision | **87.6%** / 83.7% |
| | days from empty shelf to alert | **1.6** |
| | days before the stock record would be corrected | **14.6** |
| Detector, POS sales only | caught / days to alert | 64.8% / 8.1 |
| Detector, POS + tickets | caught / days to alert | 69.6% / 5.8 |
| Identity graph | merged pairs correct (precision) / recall | **99.9%** / 83.0% |
| | 70,107 accounts resolved to | 44,540 people (true: 40,000) |
| Ticket reader | intent accuracy (8 intents) | **96.4%** |
| | right shopper (of linked tickets) / exact SKU on complaints | 99.3% / 85.3% |
| Causal churn | lift in lost-shopper rate after a missing item | **+5.6 pts ± 1.5** (true effect +12.1) |
| | after a substitution | +1.4 pts ± 1.4 (true +6.5) |
| Ledger | broken lines billed that a real phantom caused / real ones billed | 95.7% / 98.5% |
| | total bill vs. lost-sale view | **₹25.1 L vs ₹4.4 L (5.7×)** |

**At scale** (30 stores, 200k shoppers, 180 days, 5.7M order lines, about 12M rows
in all) on the same 8 GB laptop: the load takes 28 s and the whole pipeline about
6 minutes, most of it the per-SKU-day filter. The detector catches 90.8% of 2,624
phantoms in 1.3 days, identity merges stay 99.8% correct, and the bill is ₹1.63 Cr
against a ₹26 L lost-sale view. Full numbers are in [docs/BENCHMARK.md](docs/BENCHMARK.md).

The causal estimate is conservative on purpose. Ripple only sees orders, so a
shopper who leaves late in the window looks like one who is pausing. The bill
understates the churn cost rather than inflating it. See
[docs/METHOD.md](docs/METHOD.md).

## How Ripple uses Exasol Personal

Everything after CSV generation happens inside the database:

| Exasol feature | Where |
|---|---|
| Bulk `IMPORT` over HTTP transport | loading ~2M rows in about 7 s ([ripple/load.py](ripple/load.py)) |
| **Python SET UDF** with `GROUP BY` + `ORDER BY`, one HMM filter per SKU-store group, three ablation variants per pass | [sql/40_detector.sql](sql/40_detector.sql) |
| **Python scalar UDFs** emitting multiple columns: ticket intent and fuzzy product matching | [sql/30_tickets.sql](sql/30_tickets.sql) |
| **Lua script** running label propagation to a fixed point with `MERGE` | [sql/20_identity.sql](sql/20_identity.sql) |
| `EDIT_DISTANCE`, `SOUNDEX`, `REGEXP_*` for entity resolution in SQL | [sql/20_identity.sql](sql/20_identity.sql) |
| Window functions for gaps-and-islands episodes, trailing demand and traffic indices | [sql/40_detector.sql](sql/40_detector.sql) |
| Stacked difference-in-differences in plain SQL | [sql/50_causal.sql](sql/50_causal.sql) |
| Live interactive queries behind every view (the app shows Exasol's response time) | [ripple/app.py](ripple/app.py) |

Stage timings land in `RIPPLE.RUN_TIMINGS` and on the Proof tab.

## Quick start

Full instructions for Windows (WSL), macOS and Linux are in
[docs/RUN_GUIDE.md](docs/RUN_GUIDE.md).

```bash
# 1. Exasol Personal
curl https://downloads.exasol.com/exasol-personal/installer.sh | sh
exasol install local
exasol slc install PYTHON3

# 2. Ripple
python -m pip install -r requirements.txt
python -m ripple.build          # generate, load, run every engine (about 2 min)
python -m ripple.app            # http://localhost:8765
```

## Repository layout

```
generator/      seeded synthetic world (catalogue, shoppers, day-by-day simulation, ticket text)
sql/            the engines, run in order by ripple.pipeline
  00_schema     source systems (RIPPLE_RAW) and answer key (RIPPLE_GT)
  20_identity   normalise, block, score, Lua label propagation
  30_tickets    owner linking, intent UDF, product-matching UDF
  40_detector   signal fusion, self-calibration, HMM filter UDF, episodes
  50_causal     matched natural-experiment churn estimate
  60_ledger     receipts and the bill per episode
  70_recount    morning recount list by expected saving
  90_eval       scores every engine against RIPPLE_GT
ripple/         db connection, loader, pipeline runner, one-command build, web API
web/            single-page app (plain JS, hand-drawn SVG)
docs/           METHOD.md, RUN_GUIDE.md, BENCHMARK.md, DEMO_SCRIPT.md
```

## Data

All data is synthetic, generated by code in this repository. Brand, store and
customer names are invented. No employer or proprietary data is used.
Real-world figures quoted above come from the public sources linked beside
them.

## Team

Debi Prasad Samal, Naveen Kumar and Nekita Saras Dhanabal.

## Licence

[MIT](LICENSE)
