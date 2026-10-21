# Voiceover sheet (2 min 53 s)

Play `video/ripple_demo_silent.mp4` and read each block while its scene is on
screen. About 150 words a minute, calm pace. Each block is short enough to fit
its slot with a breath to spare.

**Two ways to record. Either works:**

1. **One take.** Play the video muted and talk over it, starting your
   recording at the same moment as the video. Send one audio file (m4a, mp3 or
   wav).
2. **Six clips (easier).** Record each block below as its own file, named
   `scene1` … `scene6` (any audio format). I place each clip at its start
   time, so small pauses don't matter.

Record somewhere quiet, phone about a hand's width from your mouth.

---

### Scene 1 · 0:00–0:25 · The bill

Every retailer can tell you what a stock-out cost in lost sales. On this
quick-commerce chain, that's four point nine lakh rupees. But the empty shelf
doesn't stop there. The order gets swapped or refunded, the substitute comes
back, and the customer quietly leaves. Ripple adds it all up: twenty-one lakh,
more than four times what anyone sees.

### Scene 2 · 0:25–1:05 · Recount list

The worst stock-outs are phantoms: the system says in stock, the shelf is
empty, so no alarm ever goes off. Ripple runs a Bayesian filter for every
product in every store, inside Exasol, reading sales, missed picks, picker logs
and what customers write. Each morning every store gets this list, ranked by
the money a recount saves. Open one, and you see why: sales stopped while the
book still shows stock, and the customer is telling us, typos and all.

### Scene 3 · 1:05–1:40 · One stock-out's ripple

This one empty shelf touched hundreds of shoppers. Each row is a person, not
an account. Ripple merged their app, web and WhatsApp accounts with an identity
graph that also runs in Exasol. And every rupee is a receipt: the missing item,
the returned substitute, the churn risk, each pointing at its source row.

### Scene 4 · 1:40–2:00 · Make good

Only about one in twenty-six unhappy customers ever complains. So Ripple finds
the silent ones, ranks them by what's at stake, and writes one small offer each,
with a substitute they already trust. A credit works. A bare apology doesn't.

### Scene 5 · 2:00–2:35 · Proof

We check every number against an answer key Ripple never sees. The classic
zero-sales rule catches half the phantoms, two weeks late. Ripple catches
ninety-one percent in a day and a half, and it holds even when almost nobody
complains. With the same counting budget, its list saves nearly three times as
much. And because phantoms strike at random, we measure the churn they cause,
and we err on the low side.

### Scene 6 · 2:35–2:53 · Exasol and close

Everything heavy runs inside Exasol Personal: Python UDFs, a Lua script and
plain SQL, on a laptop. One command rebuilds it, and it's open source. A
stock-out is not one lost sale. Ripple shows the whole bill.
