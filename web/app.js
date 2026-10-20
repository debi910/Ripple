// Ripple front end: plain JS and hand-drawn SVG, every view a live query against Exasol.
const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const num = (v, d = 0) => Number(v ?? 0).toLocaleString("en-IN", { maximumFractionDigits: d, minimumFractionDigits: d });
const inr = v => {
  const x = Number(v ?? 0);
  if (Math.abs(x) >= 1e7) return "₹" + num(x / 1e7, 2) + " Cr";
  if (Math.abs(x) >= 1e5) return "₹" + num(x / 1e5, 1) + " L";
  return "₹" + num(x);
};
const pct = (v, d = 0) => num(Number(v) * 100, d) + "%";
const COLORS = { lost_sale: "var(--c1)", substitution: "var(--c2)", returns: "var(--c3)", tickets: "var(--c4)", churn: "var(--c5)" };
const SIGNALS = [["llr_sales", "Sales silence", "var(--accent)"], ["llr_oms", "Short picks", "var(--c3)"],
                 ["llr_pick", "Picker log", "var(--c2)"], ["llr_tickets", "Customer tickets", "var(--c4)"]];

async function api(path) {
  const r = await fetch(path);
  if (!r.ok) throw new Error(await r.text());
  const j = await r.json();
  $("#ms").textContent = num(j.query_ms, 0);
  return j;
}

// ---------------------------------------------------------------- navigation
const state = { episode: null, asOf: null, store: "", loaded: {} };
document.querySelectorAll("nav button").forEach(b => b.onclick = () => show(b.dataset.view));
function show(view) {
  document.querySelectorAll("nav button").forEach(b => b.classList.toggle("on", b.dataset.view === view));
  document.querySelectorAll(".view").forEach(v => v.classList.toggle("on", v.id === "view-" + view));
  ({ bill: renderBill, recount: renderRecount, episode: renderEpisode, proof: renderProof })[view]();
  history.replaceState(null, "", "#" + view + (view === "episode" && state.episode ? "/" + state.episode : ""));
}
function openEpisode(id) { state.episode = id; show("episode"); }
$("#drawer-close").onclick = () => $("#drawer").classList.remove("on");

// ---------------------------------------------------------------- the bill
async function renderBill() {
  const el = $("#view-bill");
  if (state.loaded.bill) return;
  el.innerHTML = '<div class="empty">Asking Exasol…</div>';
  const d = await api("/api/overview");
  const t = d.totals[0], f = d.flow[0];
  const parts = [["lost_sale", "Lost sales", t.lost_sale], ["substitution", "Substitution margin", t.substitution],
                 ["returns", "Returned substitutes", t.returns_inr], ["tickets", "Support tickets", t.tickets_inr],
                 ["churn", "Customers driven away", t.churn]];
  const total = parts.reduce((a, p) => a + Math.max(0, p[2]), 0);
  el.innerHTML = `
    <div class="card hero">
      <div>
        <h1>What ${num(t.episodes)} silent stock-outs really cost, ${esc(t.first_day)} to ${esc(t.last_day)}</h1>
        <div class="big">${inr(t.total)}</div>
        <div class="vs">A lost-sales report shows <b>${inr(t.lost_sale)}</b>. The rest lands in three other systems
          (returns, helpdesk, CRM) where nobody connects it to the empty shelf.</div>
        <span class="mult">${num(t.total / t.lost_sale, 1)}× the cost you see</span>
      </div>
      <div>
        <div class="stack">${parts.map(p => `<div title="${p[1]}: ${inr(p[2])}" style="width:${Math.max(0, p[2]) / total * 100}%;background:${COLORS[p[0]]}"></div>`).join("")}</div>
        <div class="legend">${parts.map(p => `<div><span class="sw" style="background:${COLORS[p[0]]}"></span>${p[1]}<br><b>${inr(p[2])}</b></div>`).join("")}</div>
      </div>
    </div>

    <h2>One stock-out, five systems</h2>
    <div class="card chain">
      <div class="step"><div class="n">${num(t.episodes)}</div><div class="l">phantom stock-outs: the system said in stock, the shelf was empty</div></div>
      <div class="step"><div class="n">${num(f.lines_hit)}</div><div class="l">paid order lines broken: ${num(f.missing)} missing, ${num(f.substituted)} swapped</div></div>
      <div class="step"><div class="n">${num(f.returns_n)}</div><div class="l">substitutes sent back, logged under generic reason codes</div></div>
      <div class="step"><div class="n">${num(f.tickets_n)}</div><div class="l">angry tickets, many from a second email or phone</div></div>
      <div class="step"><div class="n">≈${num(f.customers_lost)}</div><div class="l">shoppers driven away, by causal estimate, of ${num(t.customers_hit)} hit</div></div>
    </div>

    <div class="grid g2" style="margin-top:16px">
      <div class="card">
        <h1>Where the hidden cost sits</h1>
        <p class="lede">True bill against the lost-sale view, by category.</p>
        <div class="bars">${d.by_category.map(c => `
          <div class="row"><div>${esc(c.category)}</div>
            <div class="track"><div class="fill" style="width:${c.total / d.by_category[0].total * 100}%"></div>
              <div class="fill alt" style="width:${c.lost_sale / d.by_category[0].total * 100}%"></div></div>
            <div class="val">${inr(c.total)}</div></div>`).join("")}</div>
        <div class="whykey"><span><i style="background:var(--c3)"></i>lost-sale view</span><span><i style="background:var(--accent)"></i>Ripple bill</span></div>
      </div>
      <div class="card">
        <h1>Most expensive stock-outs</h1>
        <p class="lede">Click one to follow its ripple.</p>
        <table><thead><tr><th>SKU · store</th><th class="r">Days</th><th class="r">Shoppers</th><th class="r">Lost-sale view</th><th class="r">Ripple bill</th></tr></thead>
        <tbody>${d.top.map(r => `<tr class="click" data-ep="${r.id}"><td>${esc(r.sku)}<br><span class="muted">${esc(r.store)}</span></td>
          <td class="r">${r.days}</td><td class="r">${num(r.customers)}</td><td class="r muted">${inr(r.lost_sale)}</td><td class="r"><b>${inr(r.total)}</b></td></tr>`).join("")}</tbody></table>
      </div>
    </div>`;
  el.querySelectorAll("[data-ep]").forEach(r => r.onclick = () => openEpisode(+r.dataset.ep));
  state.loaded.bill = true;
}

// ---------------------------------------------------------------- recount list
async function renderRecount() {
  const el = $("#view-recount");
  if (!state.loaded.recount) {
    const s = await api("/api/stores");
    const first = new Date(s.days[0].first_day), last = new Date(s.days[0].last_day);
    const span = Math.round((last - first) / 864e5);
    state.first = first; state.asOf = state.asOf ?? s.days[0].last_day;
    el.innerHTML = `
      <p class="lede">Each morning Ripple tells every dark store which shelves to count first, ranked by the money a
        recount saves before the next scheduled count, using only data available that morning. Drag the date to replay any day.</p>
      <div class="toolbar">
        <label>Morning of <input type="range" id="asof" min="20" max="${span}" value="${Math.round((new Date(state.asOf) - first) / 864e5)}"></label>
        <span class="asof" id="asof-label"></span>
        <label>Store <select id="store"><option value="">All stores</option>${s.stores.map(x => `<option value="${x.id}">${esc(x.name)}, ${esc(x.city)}</option>`).join("")}</select></label>
      </div>
      <div id="alerts"></div>`;
    const slider = $("#asof"), label = $("#asof-label");
    const setLabel = () => { state.asOf = iso(addDays(first, +slider.value)); label.textContent = state.asOf; };
    setLabel();
    let timer;
    slider.oninput = () => { setLabel(); clearTimeout(timer); timer = setTimeout(loadAlerts, 150); };
    $("#store").onchange = e => { state.store = e.target.value; loadAlerts(); };
    state.loaded.recount = true;
  }
  loadAlerts();
}

async function loadAlerts() {
  const box = $("#alerts");
  const d = await api(`/api/recount?as_of=${state.asOf}${state.store ? "&store_id=" + state.store : ""}`);
  if (!d.items.length) { box.innerHTML = '<div class="empty">No suspected phantom stock-outs that morning.</div>'; return; }
  box.innerHTML = d.items.map((a, i) => {
    const pos = SIGNALS.map(s => Math.max(0, a[s[0]] || 0)), sum = pos.reduce((x, y) => x + y, 0) || 1;
    return `<div class="alert" data-i="${i}">
      <div class="rank">${i + 1}</div>
      <div>
        <div class="what">Count ${esc(a.sku)}</div>
        <div class="where">${esc(a.store)} · ${a.p > 0.99 ? "over 99%" : pct(a.p)} sure the shelf is empty · ~${num(a.demand, 1)} units a day · next scheduled count in ${a.days_to_count} days</div>
        <div class="why">${SIGNALS.map((s, j) => `<div style="width:${pos[j] / sum * 100}%;background:${s[2]}"></div>`).join("")}</div>
        <div class="whykey">${SIGNALS.map((s, j) => pos[j] > 0 ? `<span><i style="background:${s[2]}"></i>${s[1]} ${pct(pos[j] / sum)}</span>` : "").join("")}</div>
      </div>
      <div class="money"><b>${inr(a.saving)}</b><span>expected saving</span></div>
      <div class="detail"></div>
    </div>`;
  }).join("");
  box.querySelectorAll(".alert").forEach(card => card.onclick = async e => {
    if (e.target.closest("a")) return;
    const a = d.items[+card.dataset.i];
    card.classList.toggle("open");
    const det = $(".detail", card);
    if (!card.classList.contains("open") || det.dataset.done) return;
    const s = await api(`/api/series?store_id=${a.store_id}&sku_id=${a.sku_id}&start=${iso(addDays(new Date(state.asOf), -27))}&end=${state.asOf}`);
    det.innerHTML = seriesChart(s.days) +
      (s.quotes.length ? s.quotes.map(q => `<div class="quote">${esc(q.body)}<small>${esc(q.d)} · ${esc(q.intent.replace("_", " "))} · linked by ${esc(q.linked_by)}</small></div>`).join("")
                       : '<div class="note">No customer has written in yet. The alert rests on sales silence and short picks.</div>') +
      (a.episode_id ? `<p><a href="#" data-ep="${a.episode_id}">Follow this stock-out's ripple →</a></p>` : "");
    det.dataset.done = 1;
    const link = $("[data-ep]", det);
    if (link) link.onclick = ev => { ev.preventDefault(); openEpisode(+link.dataset.ep); };
  });
}

// ---------------------------------------------------------------- one stock-out's ripple
async function renderEpisode() {
  const el = $("#view-episode");
  if (!state.episode) {
    const d = await api("/api/overview");
    state.episode = d.top[0].id;
  }
  el.innerHTML = '<div class="empty">Following the ripple…</div>';
  const d = await api(`/api/episode/${state.episode}`);
  const e = d.episode[0];
  const lc = Object.fromEntries(Object.entries(e).map(([k, v]) => [k.toLowerCase(), v]));
  const s = await api(`/api/series?store_id=${lc.store_id}&sku_id=${lc.sku_id}&start=${iso(addDays(new Date(lc.onset_date), -10))}&end=${iso(addDays(new Date(lc.last_date), 7))}`);
  const parts = [["lost_sale", "Lost sales", lc.lost_sale_inr], ["substitution", "Substitution", lc.substitution_inr],
                 ["returns", "Returns", lc.returns_inr], ["tickets", "Tickets", lc.tickets_inr], ["churn", "Churn risk", lc.churn_inr]];
  el.innerHTML = `
    <div class="card">
      <h1>${esc(lc.sku_name)} · ${esc(lc.store_name)}</h1>
      <p class="lede">Shelf empty from ${esc(lc.onset_date)} while the system still showed stock. Ripple raised the alert on
        ${esc(lc.alert_date)}; the phantom ran ${lc.days_open} days. ${num(lc.customers_hit)} shoppers were hit.</p>
      <div class="grid g4">${parts.map(p => `<div class="tile"><div class="k"><span class="sw" style="display:inline-block;width:9px;height:9px;border-radius:2px;background:${COLORS[p[0]]}"></span> ${p[1]}</div><div class="v">${inr(p[2])}</div></div>`).join("")}
        <div class="tile"><div class="k">Full bill</div><div class="v">${inr(lc.total_inr)}</div><div class="s">${num(lc.total_inr / Math.max(1, lc.lost_sale_inr), 1)}× the lost sale</div></div></div>
      ${seriesChart(s.days, lc.onset_date, lc.last_date)}
    </div>
    <h2>The shoppers it touched</h2>
    <div class="card"><p class="lede">Each row is one person, merged across their accounts. Click a shopper to see every receipt.</p>
      <table><thead><tr><th>Shopper</th><th>Accounts merged</th><th class="r">Returns</th><th class="r">Tickets</th><th>Since</th><th class="r">Cost</th></tr></thead>
      <tbody>${d.people.map(p => `<tr class="click" data-p="${p.person_id}"><td>${esc(p.name)}</td>
        <td>${p.accounts > 1 ? `<span class="pill acc">${p.accounts} accounts</span> ` : ""}<span class="muted">${esc(p.channels)}</span></td>
        <td class="r">${p.returns_n || ""}</td><td class="r">${p.tickets_n || ""}</td>
        <td>${p.gone_quiet ? '<span class="pill bad">gone quiet</span>' : '<span class="muted">still ordering</span>'}</td>
        <td class="r"><b>${inr(p.inr)}</b></td></tr>`).join("")}</tbody></table></div>`;
  el.querySelectorAll("[data-p]").forEach(r => r.onclick = () => openPerson(+r.dataset.p, state.episode));
}

async function openPerson(pid, ep) {
  const d = await api(`/api/person/${pid}?episode_id=${ep}`);
  const total = d.receipts.reduce((a, r) => a + r.inr, 0);
  const why = l => [l.email_eq ? "same mailbox" : "", l.phone_eq ? "same phone" : "", l.pin_eq ? "same pincode" : "",
                    l.name_agree !== "differ" ? l.name_agree.replace("_", " ") + " name" : "",
                    l.basket_cos >= 0.3 ? "similar baskets (" + l.basket_cos + ")" : ""].filter(Boolean).join(", ");
  $("#drawer-body").innerHTML = `
    <h1>${esc(d.accounts[0]?.name)}</h1>
    <p class="lede">${d.accounts.length} account${d.accounts.length > 1 ? "s" : ""} resolved to one shopper inside Exasol.</p>
    ${d.accounts.map(a => `<div class="acct"><b>${esc(a.channel)}</b> · ${esc(a.name)}<br><span class="mono">${esc(a.email || "no email")} · ${esc(a.phone || "no phone")} · ${esc(a.pincode)}</span></div>`).join("")}
    ${d.links.length ? `<div class="note">Linked because: ${d.links.map(l => `${l.a}↔${l.b}: ${why(l)} (score ${num(l.score, 1)})`).join("; ")}</div>` : ""}
    <h2>Receipts for this stock-out · ${inr(total)}</h2>
    ${d.receipts.map(r => `<div class="receipt"><div><div class="t">${esc(r.entry.replace("_", " "))}</div><div>${esc(r.note)}</div>
      <div class="src">${esc(r.src)} #${esc(r.src_ref)} · ${esc(r.d)}</div></div><div class="amt">${inr(r.inr)}</div></div>`).join("")}
    <h2>Orders per week</h2>${weekBars(d.orders)}`;
  $("#drawer").classList.add("on");
}

// ---------------------------------------------------------------- proof
async function renderProof() {
  const el = $("#view-proof");
  if (state.loaded.proof) return;
  const d = await api("/api/proof");
  const m = (a, k, v = null) => d.metrics.find(x => x.area === a && x.metric === k && (v === null || x.variant === v))?.val;
  const sc = d.scale[0];
  const variants = [["pos_only", "Sales data only"], ["pos_tickets", "+ customer tickets"], ["all", "+ order shorts and picker logs"]];
  const ce = Object.fromEntries(d.causal.map(c => [c.kind, c]));
  el.innerHTML = `
    <p class="lede">The synthetic world has an answer key that Ripple never reads. This page scores every engine
      against it, so each claim on the other pages can be checked.</p>
    <div class="grid g4">
      <div class="card tile"><div class="k">Phantom stock-outs caught</div><div class="v">${pct(m("detector", "recall", "all"))}</div><div class="s">precision ${pct(m("detector", "precision", "all"))}</div></div>
      <div class="card tile"><div class="k">Alert after the shelf empties</div><div class="v">${num(m("detector", "days_onset_to_alert", "all"), 1)} days</div><div class="s">${num(m("detector", "days_early_vs_book", "all"), 1)} days before the stock record is fixed</div></div>
      <div class="card tile"><div class="k">Identity merges correct</div><div class="v">${pct(m("identity", "pair_precision"), 1)}</div><div class="s">recall ${pct(m("identity", "pair_recall"))} · ${num(m("identity", "accounts"))} accounts → ${num(m("identity", "resolved_people"))} people</div></div>
      <div class="card tile"><div class="k">Ticket intent accuracy</div><div class="v">${pct(m("tickets", "intent_accuracy"))}</div><div class="s">exact SKU on complaints ${pct(m("tickets", "sku_accuracy"))}</div></div>
    </div>

    <div class="grid g2" style="margin-top:16px">
      <div class="card"><h1>Joining the silos is what makes it work</h1>
        <p class="lede">The same filter, fed fewer systems.</p>
        <div class="bars">${variants.map(([v, l]) => `<div class="row"><div>${l}</div><div class="track"><div class="fill" style="width:${m("detector", "recall", v) * 100}%"></div></div><div class="val">${pct(m("detector", "recall", v))}</div></div>`).join("")}</div>
        <div class="bars">${variants.map(([v, l]) => `<div class="row"><div class="muted">${l}: days to alert</div><div class="track"><div class="fill alt" style="width:${m("detector", "days_onset_to_alert", v) / 10 * 100}%"></div></div><div class="val">${num(m("detector", "days_onset_to_alert", v), 1)} d</div></div>`).join("")}</div>
      </div>
      <div class="card"><h1>How much churn a stock-out causes</h1>
        <p class="lede">Matched natural experiment: shoppers who hit a phantom against same-store, same-habit shoppers who did not, the same week.</p>
        <table><thead><tr><th>Exposure</th><th class="r">Ripple estimate</th><th class="r">±95%</th><th class="r">True effect</th></tr></thead><tbody>
        ${["missing", "substituted"].map(k => `<tr><td>Item ${k}</td><td class="r"><b>+${num(ce[k]?.att_lost_rate * 100, 1)} pts</b></td><td class="r muted">${num(ce[k]?.ci95 * 100, 1)}</td><td class="r">+${num(m("causal", "att_true_churn", k) * 100, 1)} pts</td></tr>`).join("")}</tbody></table>
        <div class="note">Ripple only sees orders, so it cannot tell a shopper who left from one who is pausing. The estimate comes in below the truth: the bill understates the churn cost rather than inflating it.</div>
      </div>
      <div class="card"><h1>Self-calibration from stock counts</h1>
        <p class="lede">Rates per unit of expected demand, learned from ${num(d.calibration.reduce((a, c) => a + c.days, 0))} days before past cycle counts.</p>
        <table><thead><tr><th>Shelf at count</th><th class="r">Sold</th><th class="r">Short picks</th><th class="r">Picker log</th><th class="r">Tickets</th></tr></thead><tbody>
        ${d.calibration.map(c => `<tr><td>${c.label}</td><td class="r">${num(c.sales_rate, 3)}</td><td class="r">${num(c.short_rate, 3)}</td><td class="r">${num(c.pick_rate, 3)}</td><td class="r">${num(c.ticket_rate, 4)}</td></tr>`).join("")}</tbody></table>
      </div>
      <div class="card"><h1>Everything runs inside Exasol</h1>
        <p class="lede">${num(sc.order_lines)} order lines, ${num(sc.sku_days)} SKU-store-days, ${num(sc.tickets)} tickets, ${num(sc.accounts)} accounts.</p>
        <table><thead><tr><th>Stage</th><th class="r">Seconds</th></tr></thead><tbody>
        ${d.timings.map(t => `<tr><td class="mono">${esc(t.stage)}</td><td class="r">${num(t.seconds, 1)}</td></tr>`).join("")}</tbody></table>
        <div class="note">Python UDFs score tickets and run the per-SKU filter in parallel groups; a Lua script closes the identity graph; the rest is SQL.</div>
      </div>
    </div>
    <p class="note">Ledger coverage: ${pct(m("ledger", "exposure_recall"))} of the order lines real phantoms broke are on the bill, and ${pct(m("ledger", "exposure_precision"))} of billed lines were broken by a real phantom.</p>`;
  state.loaded.proof = true;
}

// ---------------------------------------------------------------- charts
function seriesChart(days, from, to) {
  if (!days.length) return "";
  const W = 760, H = 190, L = 34, R = 34, T = 12, B = 22, n = days.length, bw = (W - L - R) / n;
  const maxU = Math.max(1, ...days.map(d => d.units + d.shorts)), maxB = Math.max(1, ...days.map(d => d.book));
  const x = i => L + i * bw, yU = v => H - B - v / maxU * (H - T - B), yB = v => H - B - v / maxB * (H - T - B), yP = v => H - B - v * (H - T - B);
  let s = `<svg class="chart" viewBox="0 0 ${W} ${H}" width="100%" role="img" aria-label="Daily sales, short picks, book stock and phantom probability">`;
  if (from) {
    const i0 = days.findIndex(d => d.d >= from), i1 = days.findLastIndex(d => d.d <= to);
    if (i0 >= 0) s += `<rect class="band" x="${x(i0)}" y="${T}" width="${(i1 - i0 + 1) * bw}" height="${H - T - B}"/>`;
  }
  days.forEach((d, i) => {
    s += `<rect class="units" x="${x(i) + 1}" y="${yU(d.units)}" width="${bw - 2}" height="${H - B - yU(d.units)}"><title>${d.d}: sold ${d.units}</title></rect>`;
    if (d.shorts) s += `<rect class="shorts" x="${x(i) + 1}" y="${yU(d.units + d.shorts)}" width="${bw - 2}" height="${yU(d.units) - yU(d.units + d.shorts)}"><title>${d.shorts} short picks</title></rect>`;
    if (d.counted) s += `<line class="count" x1="${x(i) + bw / 2}" x2="${x(i) + bw / 2}" y1="${T}" y2="${H - B}"><title>cycle count</title></line>`;
  });
  s += `<path class="book" d="${days.map((d, i) => (i ? "L" : "M") + (x(i) + bw / 2) + " " + yB(d.book)).join("")}"/>`;
  s += `<path class="pline" d="${days.map((d, i) => (i ? "L" : "M") + (x(i) + bw / 2) + " " + yP(d.p ?? 0)).join("")}"/>`;
  s += `<line class="axis" x1="${L}" x2="${W - R}" y1="${H - B}" y2="${H - B}"/>`;
  [0, Math.floor(n / 2), n - 1].forEach(i => s += `<text x="${x(i)}" y="${H - 6}">${days[i].d.slice(5)}</text>`);
  s += `<text x="2" y="${T + 8}">${maxU}</text><text x="${W - R + 4}" y="${T + 8}">100%</text></svg>`;
  return s + `<div class="whykey"><span><i style="background:var(--accent)"></i>units sold</span><span><i style="background:var(--c3)"></i>short picks</span>
    <span><i style="background:var(--c1)"></i>book stock (dashed, own scale)</span><span><i style="background:var(--bad)"></i>phantom probability</span>
    <span><i style="background:var(--c4)"></i>cycle count</span>${from ? '<span><i style="background:var(--warn-soft)"></i>phantom episode</span>' : ""}</div>`;
}

function weekBars(rows) {
  if (!rows.length) return "";
  const W = 480, H = 80, max = Math.max(...rows.map(r => r.n)), bw = W / rows.length;
  return `<svg class="chart" viewBox="0 0 ${W} ${H}" width="100%">${rows.map((r, i) =>
    `<rect class="units" x="${i * bw + 1}" y="${H - 14 - r.n / max * (H - 20)}" width="${bw - 2}" height="${r.n / max * (H - 20)}"><title>${r.wk}: ${r.n} orders</title></rect>`).join("")}
    <text x="0" y="${H - 2}">${rows[0].wk}</text><text x="${W - 60}" y="${H - 2}">${rows[rows.length - 1].wk}</text></svg>`;
}

const addDays = (d, n) => new Date(d.getTime() + n * 864e5);
const iso = d => d.toISOString().slice(0, 10);

// ---------------------------------------------------------------- boot
const [v, ep] = location.hash.slice(1).split("/");
if (ep) state.episode = +ep;
show(["bill", "recount", "episode", "proof"].includes(v) ? v : "bill");
window.addEventListener("hashchange", () => {
  const [hv, he] = location.hash.slice(1).split("/");
  if (he) state.episode = +he;
  if (["bill", "recount", "episode", "proof"].includes(hv)) show(hv);
});
