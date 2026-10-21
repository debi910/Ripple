// Ripple front end: plain JS and hand-drawn SVG. Every view is a live query against Exasol.
const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const num = (v, d = 0) => Number(v ?? 0).toLocaleString("en-IN", { maximumFractionDigits: d, minimumFractionDigits: d });
const inr = v => {
  const x = Number(v ?? 0);
  if (Math.abs(x) >= 1e7) return "₹" + num(x / 1e7, 2) + " Cr";
  if (Math.abs(x) >= 1e5) return "₹" + num(x / 1e5, 1) + " L";
  return "₹" + num(x);
};
const lakh = v => num(Number(v) / 1e5, 1) + " lakh";
const pct = (v, d = 0) => num(Number(v) * 100, d) + "%";
const day = s => new Date(s).toLocaleDateString("en-IN", { day: "numeric", month: "short" });
const addDays = (d, n) => new Date(d.getTime() + n * 864e5);
const iso = d => d.toISOString().slice(0, 10);
const shortStore = s => String(s ?? "").replace("Dark Store ", "");
const SIGNALS = [["llr_sales", "Sales silence"], ["llr_oms", "Short picks"], ["llr_pick", "Picker log"], ["llr_tickets", "Customers"]];

async function api(path) {
  const r = await fetch(path);
  if (!r.ok) throw new Error(await r.text());
  const j = await r.json();
  $("#ms").textContent = num(j.query_ms, 0);
  return j;
}
const head = (n, name, h, dek) =>
  `<p class="eyebrow"><b>${n}</b>${name}</p><h1 class="head">${h}</h1>${dek ? `<p class="dek">${dek}</p>` : ""}`;

// ---------------------------------------------------------------- navigation
const VIEWS = ["bill", "recount", "episode", "makegood", "proof"];
const state = { episode: null, asOf: null, store: "", loaded: {}, overview: null };
document.querySelectorAll("nav button").forEach(b => b.onclick = () => show(b.dataset.view));
function show(view) {
  document.querySelectorAll("nav button").forEach(b => b.classList.toggle("on", b.dataset.view === view));
  document.querySelectorAll(".view").forEach(v => v.classList.toggle("on", v.id === "view-" + view));
  ({ bill: renderBill, recount: renderRecount, episode: renderEpisode, makegood: renderMakegood, proof: renderProof })[view]();
  history.replaceState(null, "", "#" + view + (view === "episode" && state.episode ? "/" + state.episode : ""));
  window.scrollTo({ top: 0 });
}
function openEpisode(id) { state.episode = id; state.loaded.episode = false; closeDrawer(); show("episode"); }
function closeDrawer() { $("#drawer").classList.remove("on"); $("#scrim").classList.remove("on"); }
$("#drawer-close").onclick = closeDrawer;
$("#scrim").onclick = closeDrawer;
document.addEventListener("keydown", e => { if (e.key === "Escape") closeDrawer(); });
async function overview() { return state.overview ??= await api("/api/overview"); }

// ---------------------------------------------------------------- 01 the bill
async function renderBill() {
  const el = $("#view-bill");
  if (state.loaded.bill) return;
  el.innerHTML = '<p class="loading">Asking Exasol…</p>';
  const d = await overview();
  const t = d.totals[0], f = d.flow[0];
  const steps = [
    ["Lost sales", t.lost_sale, "what reports show"],
    ["Swapped items", t.substitution, "margin given up"],
    ["Returns", t.returns_inr, "substitutes sent back"],
    ["Tickets", t.tickets_inr, "agent time"],
    ["Shoppers lost", t.churn, "causal estimate"],
  ];
  el.innerHTML = head("01", "The bill",
      `${num(t.episodes)} silent stock-outs cost <em>₹${lakh(t.total)}</em>. <span class="quiet">The reports show ₹${lakh(t.lost_sale)}.</span>`,
      `The shelf was empty while the system said it was full. The lost sale is the part anyone sees; the rest lands in returns,
       the helpdesk and quietly churned customers: ${num(t.total / t.lost_sale, 1)}× the visible cost.`) + `
    <div class="panel">${waterfall(steps, t.total)}</div>
    <div class="split section">
      <div>
        <h2>One stock-out, five systems</h2>
        <p class="sub">Each ring is a different team’s data. Ripple follows the same people through all of them.</p>
        ${rings([[t.episodes, "phantom stock-outs"], [f.lines_hit, "paid order lines broken"], [f.returns_n, "substitutes returned"],
                 [f.tickets_n, "tickets written"], [f.customers_lost, "shoppers driven away", true]])}
      </div>
      <div>
        <h2>Costliest stock-outs</h2>
        <p class="sub">Open one to follow its ripple.</p>
        <div class="rows top5">${d.top.slice(0, 6).map(r => `
          <div class="row click" data-ep="${r.id}"><div><div class="t">${esc(r.sku)}</div>
            <div class="s">${esc(shortStore(r.store))} · empty ${r.days} days · ${num(r.customers)} shoppers</div></div>
            <div class="amt loss">${inr(r.total)}</div></div>`).join("")}</div>
      </div>
    </div>`;
  el.querySelectorAll("[data-ep]").forEach(r => r.onclick = () => openEpisode(+r.dataset.ep));
  state.loaded.bill = true;
}

// ---------------------------------------------------------------- 02 recount list
async function renderRecount() {
  const el = $("#view-recount");
  if (!state.loaded.recount) {
    const s = await api("/api/stores");
    state.first = new Date(s.days[0].first_day);
    state.last = new Date(s.days[0].last_day);
    state.asOf ??= s.days[0].last_day;
    const span = Math.round((state.last - state.first) / 864e5);
    el.innerHTML = `<div id="rc-head"></div>
      <div class="controls">
        <div class="stepper"><button id="prev" aria-label="Previous day">‹</button><span id="asof-label"></span><button id="next" aria-label="Next day">›</button></div>
        <input type="range" id="asof" min="20" max="${span}" aria-label="Morning">
        <select id="store" aria-label="Store"><option value="">All stores</option>${s.stores.map(x => `<option value="${x.id}">${esc(shortStore(x.name))}</option>`).join("")}</select>
      </div>
      <div class="legend"><span>Evidence, left to right:</span>${SIGNALS.map(([, l]) => `<span><span class="sig"><i class="on"></i></span>${l}</span>`).join("")}</div>
      <div id="alerts"></div>`;
    const slider = $("#asof");
    const set = v => {
      slider.value = Math.max(+slider.min, Math.min(+slider.max, v));
      state.asOf = iso(addDays(state.first, +slider.value));
      $("#asof-label").textContent = day(state.asOf);
    };
    set(Math.round((new Date(state.asOf) - state.first) / 864e5));
    let timer;
    slider.oninput = () => { set(+slider.value); clearTimeout(timer); timer = setTimeout(() => loadAlerts(), 140); };
    $("#prev").onclick = () => { set(+slider.value - 1); loadAlerts(); };
    $("#next").onclick = () => { set(+slider.value + 1); loadAlerts(); };
    $("#store").onchange = e => { state.store = e.target.value; loadAlerts(); };
    state.loaded.recount = true;
  }
  loadAlerts();
}

async function loadAlerts(showAll = false) {
  const d = await api(`/api/recount?as_of=${state.asOf}${state.store ? "&store_id=" + state.store : ""}`);
  const total = d.items.reduce((a, r) => a + (r.saving || 0), 0);
  $("#rc-head").innerHTML = head("02", "Recount list",
    d.items.length ? `Count these shelves first on ${day(state.asOf)}. <span class="quiet">${inr(total)} at stake.</span>`
                   : `Nothing to recount on ${day(state.asOf)}.`,
    "Ranked by the money a recount saves before the next scheduled count, using only what was known that morning.");
  const box = $("#alerts");
  if (!d.items.length) { box.innerHTML = ""; return; }
  const max = Math.max(...d.items.map(r => r.saving || 0));
  const items = showAll ? d.items : d.items.slice(0, 8);
  box.innerHTML = `<div class="rows alerts">${items.map((a, i) => {
    const pos = SIGNALS.map(([k]) => Math.max(0, a[k] || 0)), top = Math.max(...pos, 1e-9);
    return `<div class="row click" data-i="${i}">
      <div class="rk">${i + 1}</div>
      <div><div class="t">${esc(a.sku)}</div><div class="s">${esc(shortStore(a.store))} · ~${num(a.demand, 1)} a day · next count in ${a.days_to_count} days</div></div>
      <div class="sig" title="${SIGNALS.map(([, l], j) => `${l}: ${pos[j] > 0 ? "evidence" : "none"}`).join(" · ")}">${pos.map(p => `<i class="${p >= top * .35 ? "on" : p > 0 ? "half" : ""}"></i>`).join("")}</div>
      <div class="conf">${a.p > .99 ? ">99%" : pct(a.p)} sure</div>
      <div><div class="amt loss">${inr(a.saving)}</div><div class="bar"><b style="width:${(a.saving || 0) / max * 100}%"></b></div></div>
      <div class="detail"></div></div>`;
  }).join("")}</div>${!showAll && d.items.length > 8 ? `<button class="more" id="all">Show all ${d.items.length}</button>` : ""}`;
  $("#all")?.addEventListener("click", () => loadAlerts(true));
  box.querySelectorAll(".row").forEach(row => row.onclick = async e => {
    if (e.target.closest("a")) return;
    const a = items[+row.dataset.i];
    row.classList.toggle("open");
    const det = $(".detail", row);
    if (!row.classList.contains("open") || det.dataset.done) return;
    const s = await api(`/api/series?store_id=${a.store_id}&sku_id=${a.sku_id}&start=${iso(addDays(new Date(state.asOf), -27))}&end=${state.asOf}`);
    det.innerHTML = seriesChart(s.days) +
      (s.quotes.slice(0, 2).map(q => `<p class="quote">“${esc(q.body)}”<small>${day(q.d)} · ${esc(q.intent.replace(/_/g, " "))}</small></p>`).join("")
        || '<p class="quiet-note">No customer has written in. Sales silence and short picks carry this alert.</p>') +
      (a.episode_id ? `<p><a class="more" href="#" data-ep="${a.episode_id}">Follow this stock-out’s ripple →</a></p>` : "");
    det.dataset.done = 1;
    $("[data-ep]", det)?.addEventListener("click", ev => { ev.preventDefault(); ev.stopPropagation(); openEpisode(+ev.target.dataset.ep); });
  });
}

// ---------------------------------------------------------------- 03 one stock-out's ripple
async function renderEpisode() {
  const el = $("#view-episode");
  if (state.loaded.episode) return;
  el.innerHTML = '<p class="loading">Following the ripple…</p>';
  const o = await overview();
  state.episode ??= o.top[0].id;
  const d = await api(`/api/episode/${state.episode}`);
  const e = d.episode[0];
  const s = await api(`/api/series?store_id=${e.store_id}&sku_id=${e.sku_id}&start=${iso(addDays(new Date(e.onset_date), -10))}&end=${iso(addDays(new Date(e.last_date), 7))}`);
  const choices = o.top.some(r => r.id === e.episode_id) ? o.top : [{ id: e.episode_id, sku: e.sku_name, store: e.store_name }, ...o.top];
  el.innerHTML = head("03", "Ripple",
      `${esc(e.sku_name)}, ${esc(shortStore(e.store_name))}: empty for ${e.days_open} days, <em>${inr(e.total_inr)}</em>.`,
      `The shelf emptied on ${day(e.onset_date)} while the book still showed stock. Ripple raised the alert on ${day(e.alert_date)}.
       ${num(e.customers_hit)} shoppers paid for it in one way or another.`) + `
    <div class="ep-picker"><select id="ep" aria-label="Stock-out">${choices.map(r => `<option value="${r.id}" ${r.id === e.episode_id ? "selected" : ""}>${esc(r.sku)} · ${esc(shortStore(r.store))}</option>`).join("")}</select></div>
    <div class="panel">${seriesChart(s.days, e.onset_date, e.last_date)}
      <div class="chips">
        <div>Lost sales<b>${inr(e.lost_sale_inr)}</b></div><div>Swaps<b>${inr(e.substitution_inr)}</b></div>
        <div>Returns<b>${inr(e.returns_inr)}</b></div><div>Tickets<b>${inr(e.tickets_inr)}</b></div>
        <div>Churn risk<b>${inr(e.churn_inr)}</b></div><div class="total">Full bill<b>${inr(e.total_inr)}</b></div>
      </div></div>
    <div class="section"><h2>The shoppers it touched</h2>
      <p class="sub">One row per person, merged across their accounts. Open one for the receipt.</p>
      <div class="rows people" id="people"></div></div>`;
  const people = all => {
    $("#people").innerHTML = (all ? d.people : d.people.slice(0, 10)).map(p => `
      <div class="row click" data-p="${p.person_id}"><div><div class="t">${esc(p.name)}</div>
        <div class="acc">${p.accounts > 1 ? `${p.accounts} accounts · ` : ""}${esc(p.channels)}</div></div>
        <div class="s">${[p.returns_n ? `${p.returns_n} return` : "", p.tickets_n ? `${p.tickets_n} ticket` : ""].filter(Boolean).join(" · ") || "—"}</div>
        <div>${p.gone_quiet ? '<span class="tag loss">gone quiet</span>' : '<span class="tag">still buying</span>'}</div>
        <div class="amt">${inr(p.inr)}</div></div>`).join("") +
      (!all && d.people.length > 10 ? `<button class="more" id="more-people">Show ${d.people.length - 10} more</button>` : "");
    $("#more-people")?.addEventListener("click", () => people(true));
    el.querySelectorAll("[data-p]").forEach(r => r.onclick = () => openPerson(+r.dataset.p, state.episode));
  };
  people(false);
  $("#ep").onchange = ev => openEpisode(+ev.target.value);
  state.loaded.episode = true;
}

async function openPerson(pid, ep) {
  const d = await api(`/api/person/${pid}?episode_id=${ep}`);
  const total = d.receipts.reduce((a, r) => a + r.inr, 0);
  const label = { lost_sale: "Missing item", substitution_margin: "Swapped item", return: "Returned substitute", ticket: "Support ticket", churn_risk: "Churn risk" };
  const why = l => [l.email_eq ? "same mailbox" : "", l.phone_eq ? "same phone" : "", l.name_agree !== "differ" ? l.name_agree.replace("_", " ") + " name" : "",
                    l.basket_cos >= 0.3 ? "similar baskets" : ""].filter(Boolean).join(", ");
  $("#drawer-body").innerHTML = `
    <div class="receipt">
      <h3>${esc(d.accounts[0]?.name)}</h3>
      <div class="who">${d.accounts.length} account${d.accounts.length > 1 ? "s" : ""} · one shopper</div>
      ${d.receipts.map(r => `<div class="line"><span class="what">${label[r.entry] || esc(r.entry)}</span><span>${inr(r.inr)}</span>
        <span class="src">${esc(r.note)}<br>${esc(r.src)} #${esc(r.src_ref)} · ${day(r.d)}</span></div>`).join("")}
      <div class="total"><span>Total</span><span>${inr(total)}</span></div>
    </div>
    <div class="accounts"><h2>Accounts merged inside Exasol</h2>
      ${d.accounts.map(a => `<div class="a"><b>${esc(a.channel)}</b>${esc(a.email || "no email")} · ${esc(a.phone || "no phone")}</div>`).join("")}
      ${d.links.length ? `<p class="quiet-note">Linked by ${[...new Set(d.links.map(why))].join("; ")}.</p>` : ""}
    </div>
    <div class="section"><h2>Orders per week</h2>${weekBars(d.orders)}</div>`;
  $("#drawer").classList.add("on");
  $("#scrim").classList.add("on");
}

// ---------------------------------------------------------------- 04 make good
async function renderMakegood() {
  const el = $("#view-makegood");
  if (state.loaded.makegood) return;
  el.innerHTML = '<p class="loading">Finding the quiet ones…</p>';
  const d = await api("/api/makegood");
  const sm = d.summary[0];
  const pol = Object.fromEntries(d.policy.map(p => [p.item, p.val]));
  const cards = all => (all ? d.items : d.items.slice(0, 6)).map(r => `
    <div class="offer" data-p="${r.person_id}" data-ep="${r.episode_id}">
      <div class="meta"><span>${esc(shortStore(r.store))} · ${day(r.hit_date)}</span>${r.repeat_hit ? '<span class="tag loss">second hit</span>' : ""}</div>
      <div class="bubble">${esc(r.message)}</div>
      <div class="foot"><span>at risk <b>${inr(r.at_risk)}</b></span><span>credit <b>${inr(r.credit)}</b></span><span>net <b>${inr(r.net)}</b></span>
        ${r.bought_before ? '<span class="tag signal">trusted substitute</span>' : ""}</div>
    </div>`).join("");
  el.innerHTML = head("04", "Make good",
      `${num(sm.silent)} shoppers were let down and <em>never said a word</em>.`,
      "Only about 1 in 26 unhappy customers complains, so the helpdesk never hears from the people most likely to leave. Ripple picks the ones worth reaching and writes the message.") + `
    <p class="ledger-line">Offer <span class="num">${inr(sm.credit)}</span> in credit to <span class="num">${num(sm.shoppers)}</span> of them,
      expect <span class="num up">${inr(sm.recovered)}</span> back.</p>
    <div class="offers" id="offers">${cards(false)}</div>
    <button class="more" id="more-offers">Show all ${num(d.items.length)} offers</button>
    <details><summary>How the offer is chosen</summary>
      <p class="quiet-note">A small credit, never a bare apology (Halperin, Ho, List &amp; Muir); one offer per shopper; repeat hits weighted
      ${pol.repeat_multiplier}× (Knox &amp; van Oest); no blanket discounts (Anderson, Fitzsimons &amp; Simester); a substitute the shopper already
      trusts (Hoang &amp; Breugelmans). Assumed recovery rate ${pct(pol.recovery_rate)}. Every value lives in <span class="mono">RIPPLE.MAKEGOOD_POLICY</span>.</p>
    </details>`;
  const bind = () => el.querySelectorAll(".offer").forEach(c => c.onclick = () => openPerson(+c.dataset.p, +c.dataset.ep));
  bind();
  $("#more-offers").onclick = ev => { $("#offers").innerHTML = cards(true); bind(); ev.target.remove(); };
  state.loaded.makegood = true;
}

// ---------------------------------------------------------------- 05 proof
async function renderProof() {
  const el = $("#view-proof");
  if (state.loaded.proof) return;
  el.innerHTML = '<p class="loading">Scoring against the answer key…</p>';
  const d = await api("/api/proof");
  const m = (a, k, v = null) => d.metrics.find(x => x.area === a && x.metric === k && (v === null || x.variant === v))?.val;
  const b = (a, k, v) => d.baselines.find(x => x.area === a && x.metric === k && x.approach === v)?.val;
  const ce = Object.fromEntries(d.causal.map(c => [c.kind, c]));
  const pair = (label, val, max, fmt, us) => `<div class="pair ${us ? "us" : ""}"><span>${label}</span><span class="track"><b style="width:${Math.max(2, val / max * 100)}%"></b></span><span class="v">${fmt(val)}</span></div>`;
  const daysMax = Math.max(b("detector", "days_onset_to_alert", "zero_sales_rule") || 1, m("detector", "days_onset_to_alert", "pos_only") || 1);
  const saveMax = b("recount", "inr_saved", "ripple");
  const sc = d.scale[0];
  el.innerHTML = head("05", "Proof",
      `Every number here is checked against an answer key <em>Ripple never sees</em>.`,
      "The simulator writes down the truth: which shelves were really empty, who owns which account, who really left. Here is how Ripple and the textbook methods score on it.") + `
    <div class="vs">
      <div class="panel"><h2>Phantoms caught</h2>
        ${pair("Ripple", m("detector", "recall", "all"), 1, v => pct(v), true)}
        ${pair("Zero-sales rule", b("detector", "recall", "zero_sales_rule"), 1, v => pct(v))}
        ${pair("Sales data only", m("detector", "recall", "pos_only"), 1, v => pct(v))}
      </div>
      <div class="panel"><h2>Days from empty shelf to alert <span class="quiet-note">(fewer is better)</span></h2>
        ${pair("Ripple", m("detector", "days_onset_to_alert", "all"), daysMax, v => num(v, 1), true)}
        ${pair("Zero-sales rule", b("detector", "days_onset_to_alert", "zero_sales_rule"), daysMax, v => num(v, 1))}
        ${pair("Sales data only", m("detector", "days_onset_to_alert", "pos_only"), daysMax, v => num(v, 1))}
      </div>
      <div class="panel"><h2>Saved by 3 recounts a store a day</h2>
        ${pair("Ripple list", saveMax, saveMax, inr, true)}
        ${pair("Longest silence", b("recount", "inr_saved", "zero_sales_walk"), saveMax, inr)}
        ${pair("Random", b("recount", "inr_saved", "random"), saveMax, inr)}
      </div>
    </div>
    <p class="quiet-note">Zero-sales rule: Kang &amp; Gershwin’s N quiet days, with the best N (${num(b("detector", "best_n", "zero_sales_rule"))}) chosen in hindsight.
      Day-level AUC: Ripple ${num(b("detector", "auc_day_level", "ripple"), 3)}, rule ${num(b("detector", "auc_day_level", "zero_sales_rule"), 3)}.</p>

    <div class="split section">
      <div><h2>It doesn’t need customers to complain</h2>
        <p class="sub">The same world rebuilt at different complaint rates. Research puts it near 4%.</p>
        ${sweepChart(d.sweep)}</div>
      <div><h2>A missing item’s effect on churn</h2>
        <p class="sub">Matched natural experiment: same store, same habits, same week.</p>
        ${causalChart(ce.missing?.att_lost_rate, ce.missing?.ci95, m("causal", "att_true_churn", "missing"))}
        <p class="quiet-note">Ripple only sees orders, so it errs low: the bill understates churn rather than inflating it.</p></div>
    </div>

    <div class="stats section">
      <div class="stat"><div class="v">${pct(m("detector", "precision", "all"))}</div><div class="k">of alerts are real phantoms</div><div class="s">${num(m("detector", "days_early_vs_book", "all"), 1)} days before the record is fixed</div></div>
      <div class="stat"><div class="v">${pct(m("identity", "pair_precision"), 1)}</div><div class="k">of account merges correct</div><div class="s">${num(m("identity", "accounts"))} accounts → ${num(m("identity", "resolved_people"))} people</div></div>
      <div class="stat"><div class="v">${pct(m("tickets", "intent_accuracy"))}</div><div class="k">ticket intent accuracy</div><div class="s">Hinglish and typos included</div></div>
      <div class="stat"><div class="v">${pct(m("ledger", "exposure_recall"))}</div><div class="k">of real damage on the bill</div><div class="s">${pct(m("ledger", "exposure_precision"))} of billed lines are real</div></div>
    </div>

    <details><summary>Under the hood</summary>
      <table><thead><tr><th>Calibrated from past counts</th><th class="r">Sold</th><th class="r">Short picks</th><th class="r">Picker log</th><th class="r">Tickets</th></tr></thead><tbody>
      ${d.calibration.map(c => `<tr><td>${c.label === "phantom" ? "Shelf found empty" : "Shelf as booked"}</td><td class="r mono">${num(c.sales_rate, 3)}</td><td class="r mono">${num(c.short_rate, 3)}</td><td class="r mono">${num(c.pick_rate, 3)}</td><td class="r mono">${num(c.ticket_rate, 4)}</td></tr>`).join("")}</tbody></table>
      <table><thead><tr><th>Stage inside Exasol</th><th class="r">Seconds</th></tr></thead><tbody>
      ${d.timings.map(t => `<tr><td class="mono">${esc(t.stage)}</td><td class="r mono">${num(t.seconds, 1)}</td></tr>`).join("")}</tbody></table>
      <p class="quiet-note">${num(sc.order_lines)} order lines · ${num(sc.sku_days)} SKU-store-days · ${num(sc.tickets)} tickets · ${num(sc.accounts)} accounts.
        Python UDFs run the per-SKU filter and read tickets; a Lua script closes the identity graph; the rest is SQL.</p>
    </details>`;
  state.loaded.proof = true;
}

// ---------------------------------------------------------------- charts
function waterfall(steps, total) {
  const W = 1000, H = 300, L = 8, B = 46, T = 34, n = steps.length + 1, gap = 26;
  const bw = (W - L * 2 - gap * (n - 1)) / n, y = v => H - B - v / total * (H - B - T);
  const biggest = Math.max(...steps.slice(1).map(z => z[1]));
  let acc = 0, s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Waterfall from lost sales to the full bill">`;
  [0.25, 0.5, 0.75, 1].forEach(f => s += `<line class="grid" x1="0" x2="${W}" y1="${y(total * f)}" y2="${y(total * f)}" stroke-dasharray="2 4"/>`);
  steps.forEach(([label, v, note], i) => {
    const x = L + i * (bw + gap), y0 = y(acc), y1 = y(acc + v);
    const op = i === 0 ? .5 : Math.max(.35, .25 + .75 * v / biggest);
    s += `<rect x="${x}" y="${y1}" width="${bw}" height="${Math.max(2, y0 - y1)}" rx="3" fill="${i === 0 ? "var(--muted)" : "var(--loss)"}" opacity="${op}"/>`;
    s += `<line x1="${x + bw}" x2="${x + bw + gap}" y1="${y1}" y2="${y1}" stroke="var(--ink)" stroke-dasharray="2 3" opacity=".45"/>`;
    s += `<text class="val ${i ? "loss" : ""}" x="${x + bw / 2}" y="${y1 - 10}" text-anchor="middle">${i ? "+" : ""}${inr(v)}</text>`;
    s += `<text class="lbl" x="${x + bw / 2}" y="${H - B + 20}" text-anchor="middle">${label}</text><text x="${x + bw / 2}" y="${H - B + 36}" text-anchor="middle">${note}</text>`;
    acc += v;
  });
  const x = L + steps.length * (bw + gap);
  s += `<rect x="${x}" y="${y(total)}" width="${bw}" height="${y(0) - y(total)}" rx="3" fill="var(--ink)"/>`;
  s += `<text class="val" x="${x + bw / 2}" y="${y(total) - 10}" text-anchor="middle">${inr(total)}</text>`;
  s += `<text class="lbl" x="${x + bw / 2}" y="${H - B + 20}" text-anchor="middle" font-weight="600">The real bill</text>`;
  s += `<line class="base" x1="0" x2="${W}" y1="${H - B}" y2="${H - B}"/></svg>`;
  return s;
}

function rings(items) {
  const W = 430, H = 290, cx = 140, cy = 145, r0 = 20, step = 25;
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="The ripple of one stock-out across five systems">`;
  for (let i = items.length - 1; i >= 0; i--) {
    const r = r0 + i * step, last = items[i][2];
    s += `<circle cx="${cx}" cy="${cy}" r="${r}" fill="${i === 0 ? "var(--loss)" : "none"}" stroke="${last ? "var(--loss)" : "var(--ink)"}" stroke-width="${last ? 1.6 : 1}" opacity="${i === 0 || last ? .95 : .75 - i * .1}"/>`;
  }
  items.forEach(([v, label, last], i) => {
    const r = r0 + i * step, yy = 46 + i * 52, a = -Math.PI / 2.6 + i * .32, xr = cx + r * Math.cos(a), yr = cy + r * Math.sin(a);
    s += `<circle cx="${xr}" cy="${yr}" r="3" fill="${last ? "var(--loss)" : "var(--ink)"}"/>`;
    s += `<path d="M${xr} ${yr} L282 ${yy - 5}" stroke="var(--rule)" fill="none"/>`;
    s += `<text class="val ${last ? "loss" : ""}" x="290" y="${yy}">${last ? "≈" : ""}${num(v)}</text><text class="lbl" x="290" y="${yy + 17}">${label}</text>`;
  });
  return s + "</svg>";
}

function seriesChart(days, from, to) {
  if (!days.length) return "";
  const W = 1000, H = 220, L = 34, R = 40, T = 16, B = 26, n = days.length, bw = (W - L - R) / n;
  const maxU = Math.max(1, ...days.map(d => d.units + d.shorts)), maxB = Math.max(1, ...days.map(d => d.book));
  const x = i => L + i * bw, yU = v => H - B - v / maxU * (H - T - B), yB = v => H - B - v / maxB * (H - T - B), yP = v => H - B - v * (H - T - B);
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Daily sales, short picks, book stock and phantom probability">`;
  if (from) {
    const i0 = days.findIndex(d => d.d >= from), i1 = days.findLastIndex(d => d.d <= to);
    if (i0 >= 0) s += `<rect x="${x(i0)}" y="${T - 6}" width="${(i1 - i0 + 1) * bw}" height="${H - T - B + 6}" fill="var(--loss-soft)" opacity=".7"/>
      <text x="${x(i0) + 6}" y="${T + 6}" fill="var(--loss)">shelf empty</text>`;
  }
  days.forEach((d, i) => {
    s += `<rect x="${x(i) + bw * .18}" y="${yU(d.units)}" width="${bw * .64}" height="${H - B - yU(d.units)}" fill="var(--ink)" opacity=".8"><title>${d.d}: sold ${d.units}</title></rect>`;
    if (d.shorts) s += `<rect x="${x(i) + bw * .18}" y="${yU(d.units + d.shorts)}" width="${bw * .64}" height="${yU(d.units) - yU(d.units + d.shorts)}" fill="var(--loss)"><title>${d.shorts} paid lines not picked</title></rect>`;
    if (d.counted) s += `<line x1="${x(i) + bw / 2}" x2="${x(i) + bw / 2}" y1="${T}" y2="${H - B}" stroke="var(--signal)" stroke-dasharray="3 3"><title>cycle count</title></line>`;
  });
  s += `<path d="${days.map((d, i) => (i ? "L" : "M") + (x(i) + bw / 2) + " " + yB(d.book)).join("")}" fill="none" stroke="var(--muted)" stroke-width="1.5" stroke-dasharray="4 3"/>`;
  s += `<path d="${days.map((d, i) => (i ? "L" : "M") + (x(i) + bw / 2) + " " + yP(d.p ?? 0)).join("")}" fill="none" stroke="var(--signal)" stroke-width="2.2"/>`;
  s += `<line class="base" x1="${L}" x2="${W - R}" y1="${H - B}" y2="${H - B}"/>`;
  [0, Math.floor(n / 2), n - 1].forEach(i => s += `<text x="${x(i)}" y="${H - 8}">${day(days[i].d)}</text>`);
  s += `<text x="${W - R + 6}" y="${T + 4}" fill="var(--signal)">100%</text></svg>`;
  return s + `<p class="legend" style="justify-content:flex-start;margin-top:10px">
    <span><span class="sig"><i class="on"></i></span>units sold</span><span><span class="sig"><i style="background:var(--loss)"></i></span>paid but not picked</span>
    <span>- - book stock</span><span style="color:var(--signal)">— Ripple’s confidence the shelf is empty</span></p>`;
}

function sweepChart(rows) {
  if (!rows.length) return '<p class="quiet-note">Run <span class="mono">python -m ripple.sweep</span> to add this test.</p>';
  const rates = [...new Set(rows.map(r => r.rate))].sort((a, c) => a - c);
  const get = (rate, v) => rows.find(r => r.rate === rate && r.variant === v && r.metric === "recall")?.val ?? 0;
  const W = 480, H = 220, L = 40, R = 16, T = 16, B = 34;
  const x = i => L + i * (W - L - R) / Math.max(1, rates.length - 1), y = v => H - B - v * (H - T - B);
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Detection across complaint rates">`;
  [0, .5, 1].forEach(v => s += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(v)}" y2="${y(v)}"/><text x="0" y="${y(v) + 4}">${pct(v)}</text>`);
  [["all", "var(--ink)", "Ripple"], ["pos_only", "var(--muted)", "sales only"]].forEach(([v, c, l]) => {
    s += `<path d="${rates.map((r, i) => (i ? "L" : "M") + x(i) + " " + y(get(r, v))).join("")}" fill="none" stroke="${c}" stroke-width="2"/>`;
    rates.forEach((r, i) => s += `<circle cx="${x(i)}" cy="${y(get(r, v))}" r="4" fill="var(--card)" stroke="${c}" stroke-width="2"/>`);
    s += `<text class="lbl" x="${W - R}" y="${y(get(rates.at(-1), v)) - 10}" text-anchor="end">${l} ${pct(get(rates.at(-1), v))}</text>`;
  });
  rates.forEach((r, i) => s += `<text x="${x(i)}" y="${H - 10}" text-anchor="middle">${pct(r)} complain</text>`);
  return s + "</svg>";
}

function causalChart(est, ci, truth) {
  if (est == null || truth == null) return "";
  const W = 480, H = 130, L = 10, R = 20, max = Math.max(truth, est + ci) * 1.15, x = v => L + Math.max(0, v) / max * (W - L - R);
  return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Estimated against true churn effect">
    <line class="base" x1="${L}" x2="${W - R}" y1="92" y2="92"/>
    <line x1="${x(est - ci)}" x2="${x(est + ci)}" y1="62" y2="62" stroke="var(--ink)" stroke-width="2"/>
    <line x1="${x(est - ci)}" x2="${x(est - ci)}" y1="56" y2="68" stroke="var(--ink)"/><line x1="${x(est + ci)}" x2="${x(est + ci)}" y1="56" y2="68" stroke="var(--ink)"/>
    <circle cx="${x(est)}" cy="62" r="6" fill="var(--ink)"/>
    <text class="val" x="${x(est)}" y="40" text-anchor="middle">Ripple +${num(est * 100, 1)} pts</text>
    <line x1="${x(truth)}" x2="${x(truth)}" y1="50" y2="92" stroke="var(--loss)" stroke-width="2" stroke-dasharray="3 3"/>
    <text class="val loss" x="${x(truth)}" y="40" text-anchor="middle">truth +${num(truth * 100, 1)}</text>
    <text x="${L}" y="112">0</text><text x="${W - R}" y="112" text-anchor="end">points likelier to leave within 8 weeks</text></svg>`;
}

function weekBars(rows) {
  if (!rows.length) return "";
  const W = 440, H = 90, max = Math.max(...rows.map(r => r.n)), bw = W / rows.length;
  return `<svg class="chart" viewBox="0 0 ${W} ${H}">${rows.map((r, i) =>
    `<rect x="${i * bw + 2}" y="${H - 18 - r.n / max * (H - 26)}" width="${bw - 4}" height="${r.n / max * (H - 26)}" rx="2" fill="var(--ink)" opacity=".75"><title>${r.wk}: ${r.n} orders</title></rect>`).join("")}
    <text x="0" y="${H - 2}">${day(rows[0].wk)}</text><text x="${W}" y="${H - 2}" text-anchor="end">${day(rows.at(-1).wk)}</text></svg>`;
}

// ---------------------------------------------------------------- boot
function route() {
  const [v, ep] = location.hash.slice(1).split("/");
  if (ep && +ep !== state.episode) { state.episode = +ep; state.loaded.episode = false; }
  show(VIEWS.includes(v) ? v : "bill");
}
window.addEventListener("hashchange", route);
route();
