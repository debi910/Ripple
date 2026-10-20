# Demo video script (3 minutes)

Record at 1920×1080 with the app at `http://localhost:8765` in a full-screen
browser and a terminal next to it. Spoken lines are in quotes; *italics* are
actions. Numbers below are from the demo world, seed 42, so check them on the
Proof tab before recording.

---

### 0:00–0:25 · The problem (The bill tab)

*Open on The bill tab, cursor on the big number.*

"Every retailer can tell you what a stock-out cost in lost sales. On this
quick-commerce chain that's 4.4 lakh rupees. But a stock-out doesn't stop at
the shelf. The paid item gets swapped or refunded, the substitute comes back,
the customer writes in angry from a different email, and a few weeks later
they're gone. Each step lands in a different system. Ripple adds them up: 24.5
lakh, more than five times what anyone sees."

*Point along the five-step chain under the number.*

### 0:25–1:10 · Early warning (Recount list tab)

*Switch to Recount list. Drag the date slider back to a busy morning, then
forward again.*

"The worst stock-outs are phantoms: the system says in stock, the shelf is
empty, so nothing raises an alert. Ripple runs a Bayesian filter for every SKU
in every store, inside Exasol, reading four systems at once: sales, short
picks, picker logs and what customers write. Every morning each store gets
this list, ranked by money a recount saves before the next scheduled count."

*Click the top alert to expand it.*

"Here's why it flagged this one: sales stopped while the book still shows
stock, pickers can't find it, and customers are saying so, in Hinglish and with
typos, and the ticket reader still maps it to the exact SKU."

### 1:10–1:55 · The ripple (Stock-out ripple tab)

*Click "Follow this stock-out's ripple", or open the most expensive one from
The bill.*

"This one stock-out touched hundreds of shoppers. Each row is a person, not
an account: Ripple merged their app, web and WhatsApp accounts with an
identity graph that also runs in Exasol."

*Click a shopper with "2 accounts" and a return.*

"And every rupee is a receipt: the missing line, the returned substitute, the
ticket, and the churn risk, each pointing at its source row."

### 1:55–2:35 · Proof (Proof tab)

*Switch to Proof.*

"We built a seeded simulator so we could check ourselves against an answer
key Ripple never reads. With sales data alone, the filter catches 65% of
phantoms after eight days. Joining all four systems catches 88% in about a day
and a half, two weeks before the stock record would be fixed. Identity merges
are 98% correct. And because phantoms strike at random, we use them as a
natural experiment: a missing item makes a shopper five points more likely to
leave. That's below the true effect, so the bill doesn't overclaim."

### 2:35–3:00 · Exasol and openness (terminal)

*Show the terminal: `python -m ripple.build` output with stage timings, or the
large-scale timings from the README.*

"Everything heavy runs inside Exasol Personal: Python UDFs for the filter and
the ticket reader, a Lua script for the identity graph, and plain SQL for the
causal estimate and the ledger. At 5.7 million order lines the whole pipeline
runs on a laptop. One command rebuilds it, it's MIT licensed, and the data is
synthetic. A stock-out is not one lost sale. Ripple shows the whole bill."
