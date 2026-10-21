# How Ripple works

Ripple keeps all data and all heavy logic inside Exasol. Python outside the
database only generates the synthetic world, sends SQL, and serves the web
page. This note walks through each engine, the assumptions behind it, and how
it is scored.

```
 source systems (RIPPLE_RAW)            engines (RIPPLE)                       outputs
 ─────────────────────────────          ──────────────────────────────         ─────────────────
 inventory book, cycle counts ──┐
 POS daily sales ───────────────┤──►  1 phantom filter (Python SET UDF) ──┐
 orders, order lines, picks ────┤──►  2 identity graph (SQL + Lua) ──────┼──►  ripple ledger ──► bill, recount list
 support tickets ───────────────┤──►  3 ticket reader (Python UDFs) ─────┤        (receipts)
 returns ───────────────────────┘     4 causal churn (SQL) ──────────────┘
                                       5 evaluation vs RIPPLE_GT (SQL)
```

## The synthetic world (`generator/`)

No public dataset links a stock-out to the returns, tickets and churn that
follow it, so Ripple ships a seeded simulator that does. It runs a
quick-commerce retailer day by day:

* **Stores and catalogue.** Dark stores in five Indian cities. 43 product groups
  × several invented brands × pack sizes. Siblings in a group substitute for
  each other. All brand and customer names are invented.
* **Two inventories.** Each SKU-store has a *true* on-hand and a *book*
  (system) on-hand. Sales move both. With a small daily hazard, higher for
  theft-prone categories, true stock silently drops to zero while the book
  stays put. Replenishment follows the book, so the phantom persists until a
  cycle count (every 4–6 weeks) or a lucky delivery fixes it.
* **Shoppers.** Each person owns one to four accounts (app, web, loyalty card,
  WhatsApp) with messy names, Gmail dot and plus variants, phone formats,
  second SIMs and work emails. Some households share one phone. Each shopper
  has a list of regulars and orders at a personal rate.
* **The ripple.** A paid line that hits a phantom is either substituted with a
  sibling (55%) or refunded as missing. Substitutes come back 25% of the time
  under generic reason codes. By default 4% of shoppers with a missing item
  write a ticket within two days (fewer for a swap), often from an address no
  account carries. Every bad experience raises a decaying churn hazard, and
  shoppers order less before they leave.

### Simulator settings against published numbers

| Setting | Ripple's world | Published | Source |
|---|---|---|---|
| Stock records wrong | phantoms on ~0.1% of SKU-days, all "book > 0, shelf = 0" | ~65% of records off, mostly small errors | DeHoratius & Raman 2008; UK grocer 2025 |
| Complaint rate | 4% of shoppers with a missing item (`--ticket-rate`) | about 1 in 26 unhappy customers complains | TARP |
| Substitution on a short pick | 55% | 26% switch brand in store; quick commerce substitutes by default | Gruen, Corsten & Bharadwaj 2002 |
| Substitutes returned | 25% | 30–45% of online grocery shoppers dislike their substitutes | Hoang & Breugelmans 2023 |
| Churn effect of a stock-out | true lift ~12 points over eight weeks after a missing item | later spend down ~17% over 13 months | Anderson, Fitzsimons & Simester 2006 |

The stress sweep (`python -m ripple.sweep`) rebuilds the world at 2%, 4%, 10%
and 25% complaint rates. The Proof tab shows the detector does not depend on
customers writing in.

The simulator writes its answer key to `RIPPLE_GT`: true phantom intervals,
true account owners, ticket intents and products, exposures, churn dates and
the share of each churn the stock-outs caused. Ripple's engines never read it.

## 1. Phantom stock-out filter (`sql/40_detector.sql`)

A two-state hidden Markov filter (normal / phantom) runs forward through time
for every SKU in every store. It is a Python **SET UDF** called with `GROUP BY
store, sku` and `ORDER BY day`, so Exasol runs one filter per group in parallel.

Each day with the item visible in the app (book > 0), the posterior log-odds
of "phantom" are updated by four likelihood ratios:

| Signal (source system) | Normal state | Phantom state |
|---|---|---|
| Units sold (POS) | negative binomial around the learned demand × store traffic index | almost always zero |
| Short-picked order lines (OMS) | Poisson, low rate | Poisson, ~0.87 per unit of demand |
| Picker exception log (WMS) | Poisson, low rate | Poisson, ~0.30 per unit of demand |
| Stock-related tickets naming this SKU (helpdesk) | Poisson, very low | Poisson, ~0.17 per unit of demand |

**Self-calibration.** The emission rates and the onset hazard are not hand
tuned. `DETECTOR_CALIBRATION` learns them from the retailer's own history: a
past cycle count that found an empty shelf the book thought was stocked is a
labelled phantom, and the three days before it show how loudly each signal
speaks. Counts that matched the book give the normal rates.

**Guards.** Short picks on a shelf that genuinely sold out that day carry no
evidence. A delivery or a count resets the state. The demand estimate only
learns on days the filter believes are normal, so a phantom cannot teach it
that demand is zero.

**Ablation.** The UDF runs three variants in one pass: POS only, POS plus
tickets, and all four systems. The gap between them is the value of joining the
silos.

## 2. Identity graph (`sql/20_identity.sql`)

1. Normalise contact points in SQL: lower-case names with punctuation removed,
   Gmail dots and `+tags` stripped, phones reduced to their last ten digits.
2. **Block** candidate pairs on shared email, shared phone, or same pincode +
   `SOUNDEX(surname)` + first initial.
3. **Behavioural fingerprint.** TF-IDF weighted cosine similarity (sharing a niche SKU counts more than both buying the bestseller) of the two accounts' SKU
   purchase vectors, computed only for candidate pairs.
4. **Score** each pair with log-odds style weights: email agreement +10, phone
   +6 (+4 if the phone is shared across several first names), phone and pincode
   together +3, TF-IDF basket similarity up to +3, name agreement from +3 (exact or
   swapped) down to −4 (different person). `EDIT_DISTANCE` handles typos.
5. **Close the graph** with a Lua script (`RESOLVE_CLUSTERS`) that runs
   label propagation inside Exasol until no label changes.

## 3. Ticket reader (`sql/30_tickets.sql`)

* **Owner.** Order reference first, then normalised email, then phone, against
  every contact point of every resolved person.
* **Intent.** A Python scalar UDF scores eight intents with weighted patterns.
  Repeated letters are squashed on both sides, so `expiird` matches `expired`,
  and common Hinglish phrasings (`nahi aaya`, `bhej diya`, `kab aayega`) are
  covered.
* **Product.** "The milk" only becomes a SKU once we know who wrote. Candidates
  are the lines this person ordered in the three days before writing. Lines that
  were missing or substituted get a bonus. For availability questions the
  candidates are the whole catalogue of the shopper's usual store, with items the
  book showed as out of stock that day flagged. A second UDF does fuzzy token
  matching with one-letter tolerance.

## 4. Causal churn (`sql/50_causal.sql`)

Phantom stock-outs strike at random, which makes them a natural experiment.
For every cohort week, a **treated** shopper ordered that week and had their
first missing or substituted line. A **control** shopper ordered the same week,
got everything, and stays clean through follow-up. The two are matched on
store × prior four-week order count × basket size that week. The outcome is
"no order at all from week 2 to week 8". The stacked difference, weighted by
treated counts, is the average effect on the treated, with a 95% interval.

The estimate is deliberately conservative. Ripple only sees orders, so it
cannot tell a shopper who left late in the window from one who is pausing. The
proof page re-runs the same design with the true churn date and shows the gap.
The ledger therefore understates churn cost.

## 5. The ledger (`sql/60_ledger.sql`) and recount list (`sql/70_recount.sql`)

Each detected episode collects the order lines it broke and the resolved
people behind them. Every cost is written as one receipt row pointing at its
source: margin on missing lines, margin given up on substitutes, returned
substitutes (margin reversed, handling, perishable write-off), stock tickets
within three days (one ticket is billed once), and causal churn risk × the
shopper's 26-week margin value. Handling costs live in `COST_ASSUMPTIONS` so a
retailer can swap in their own.

The recount list ranks open alerts by **expected saving**: P(phantom) × daily
demand × cost per broken line in that category × days until the next scheduled
count. The app can replay it for any past morning using only data up to then.

## 6. Make-good list (`sql/80_makegood.sql`)

Most shoppers a phantom hits never write in. Ripple ranks the silent ones by
expected margin recovered minus the credit offered, and drafts one message
each. The policy follows field evidence:

* a small credit, never a bare apology: in Uber's 1.5-million-rider experiment
  a $5 coupon lifted spending and an apology alone did nothing, while repeated
  apologies backfired (Halperin, Ho, List & Muir);
* one offer per shopper, however many stock-outs hit them;
* a second hit within four weeks is weighted 1.5×, because a repeat failure is
  the worst case (Knox & van Oest 2014);
* no blanket discounts, which hurt long-run demand (Anderson, Fitzsimons &
  Simester 2006);
* the message names a substitute the shopper has bought before, which is far
  more likely to be accepted (Hoang & Breugelmans 2023).

Credits, the repeat weight and the assumed recovery rate (35%) live in
`RIPPLE.MAKEGOOD_POLICY`.

## 7. Evaluation (`sql/90_eval.sql`, `sql/95_baselines.sql`)

The only stage that reads `RIPPLE_GT`. It writes `RIPPLE.EVAL_METRICS`:
identity pair precision and recall; ticket owner, intent and SKU accuracy;
detector event recall, precision, days from onset to alert and days before the
book would be corrected, per variant; causal estimate vs. true effect; ledger
exposure precision and recall.

A detector alert counts as correct if it fires between a true phantom's first
day and the day after it ends. Recall counts true phantoms with at least one
such alert.

`95_baselines.sql` scores the methods from the literature on the same answer
key:

* **Zero-sales rule** (Kang & Gershwin 2005): alert after N zero-sales days on
  a stocked item, with the best N picked in hindsight, which flatters it.
* **Day-level AUC** for Ripple's posterior and for the zero-run length, to sit
  beside the 0.67 that Farias, Li & Peng report for pooled matrix completion on
  real data with injected anomalies.
* **Recount policies** with the same budget of 3 counts per store per day:
  Ripple's list, longest silence first, and random counts. Each is credited
  with the empty shelf-days it ends early, times the shelf's expected daily
  loss.
* **Make-good targeting**: the true churn rate of listed silent shoppers
  against unlisted ones.

## Related work

| Work | What it shows | How Ripple relates |
|---|---|---|
| DeHoratius & Raman 2008, *Management Science* | ~65% of 370k SKU-store records wrong; category matters more than store | Theft-prone categories get a higher phantom hazard |
| UK grocer study 2025, arXiv 2506.05357 | 64.7% of counts off; a targeted audit lifted sales 11.2% (32% on overstated items) | Supports the recount list; partial errors are a known limit |
| Kang & Gershwin 2005, *IIE Transactions* | 1% silent stock loss can lose 17% of demand as replenishment freezes; reset after N zero days | Our replenishment follows the book, so it freezes; their rule is our baseline |
| DeHoratius, Mersereau & Schrage 2008, *MSOM* | Keep a distribution over true stock and audit by it | Ripple's filter is the two-state version; the recount list is an audit policy |
| Mersereau 2015, *MSOM* | Ignoring record errors biases demand estimates down | Demand only learns on days the filter believes are normal |
| Kök & Shang 2007, *MSOM* | When to inspect; cycle counting is near optimal | Ripple ranks counts by value; a picker-hours budget is a known limit |
| Farias, Li & Peng 2024, *MSOM* | Phantoms cost up to 4% of revenue; pooled matrix completion, AUC 0.67, injected anomalies | We report AUC on the same kind of test; pooling across stores is future work |
| Gruen, Corsten & Bharadwaj 2002, GMA | 8.3% of items out of stock; shopper responses | Substitution, refund and exit paths in the ledger |
| Anderson, Fitzsimons & Simester 2006, *Management Science* | Stock-outs cut later spend as much as the lost sale; frequent buyers hit most | The reason for the matched causal design |
| Hoang & Breugelmans 2023, *Journal of Retailing* | 30–45% dislike substitutes; familiar ones are accepted | Returned substitutes billed; make-good names a familiar one |
| Knox & van Oest 2014, *Journal of Marketing* | Complaints raise churn; a repeat failure is worst | Repeat hits weigh more on the make-good list |
| Halperin, Ho, List & Muir, NBER | Coupons recover spend; bare apologies don't | Make-good offers a credit, once |
| TARP 1999 | About 1 in 26 unhappy customers complains | Default complaint rate and the stress sweep |
| Fellegi–Sunter, as in Splink (UK MoJ) | Log-odds match weights, learned by EM | Same form; our weights are set by hand (a known limit) |
| Petersen & Kumar 2009, *Journal of Marketing* | Returns are not all bad | Only returns of phantom-caused substitutes are billed |
| Bernstein, Oct 2026 | Quick-commerce in-stock 82.5–94.4% | Our target customer, today |

## Known limits

* The world is synthetic. Effect sizes (churn hazard, ticket rates) are
  plausible but set by us. The method, not the exact rupee figures, is the claim.
* The causal design needs at least six weeks of follow-up, so the last weeks of
  data inform the ledger only through effects estimated on earlier cohorts.
* Identity resolution misses accounts that share nothing but a common name and
  pincode (recall about 83%). We chose precision over recall, because a false
  merge would bill one shopper's churn to another. Match weights are set by
  hand; learning them by EM, as Splink does, is a natural next step.
* Only full phantoms are modelled ("book > 0, shelf = 0"). The UK grocer study
  shows most real errors are small (±10 units) and a quarter are understated.
* The causal outcome is order silence. A BG/NBD "probability still active"
  model (Fader, Hardie & Lee 2005) would narrow the gap to the true effect.
* Counting is treated as free; a daily picker-hours budget (Kök & Shang 2007)
  is only used in the baseline comparison.
