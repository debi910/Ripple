"""Ripple synthetic world generator.

Simulates a quick-commerce retailer day by day: dark stores, a catalogue with
substitute groups, customers who own several messy accounts, true vs. system
(book) inventory, phantom stock-outs, substitutions, returns, support tickets
and churn. Each effect is caused by the one before it, so the downstream cost
of a stock-out is real inside the simulation and can be checked against the
ground-truth tables (prefixed gt_), which Ripple itself never reads.

    python -m generator.generate --scale demo --seed 42 --out data/demo
"""

import argparse
import csv
import datetime as dt
import random
import time
from pathlib import Path

import numpy as np

from generator import catalog, texts

SCALES = {
    # stores, persons, days, brands per group
    "tiny": dict(stores=4, persons=4_000, days=60, brands=2),
    "demo": dict(stores=12, persons=40_000, days=120, brands=3),
    "large": dict(stores=30, persons=200_000, days=180, brands=4),
}

START_DATE = dt.date(2026, 3, 1)
FESTIVAL_DAYS = range(70, 75)          # a festival demand spike, like Raksha Bandhan
PHANTOM_HAZARD = 0.0012                # chance per SKU-store-day that true stock silently hits zero
HIGH_SHRINK = {"Personal Care", "Baby Care", "Pharma"}
CHURN_BASE = 1 / 500                   # baseline daily churn hazard
CHURN_BETA = 2.5                       # hazard multiplier per unit of bad-experience stock
EXPOSURE_DECAY = np.exp(-1 / 28)       # bad experiences fade over about four weeks
# Share of shoppers with a missing item who write in. TARP's research puts complainers at
# about 1 in 26 unhappy customers; swapped items and availability questions are rarer still.
TICKET_RATE = 0.04
SEVERITY = {"missing": 1.0, "substituted": 0.6, "returned": 0.4}


# --------------------------------------------------------------------------- world

def build_skus(rng: random.Random, brands_per_group: int):
    skus = []
    for category, group, base, sizes, (lo, hi), perishable in catalog.PRODUCT_GROUPS:
        for brand in rng.sample(catalog.BRANDS, brands_per_group):
            for i, size in enumerate(sizes):
                frac = i / max(1, len(sizes) - 1)
                price = round((lo + (hi - lo) * frac) * rng.uniform(0.9, 1.15))
                margin = rng.uniform(0.14, 0.34)
                skus.append(dict(
                    sku_id=len(skus) + 1, name=f"{brand} {base} {size}", brand=brand,
                    category=category, substitute_group=group, pack_size=size,
                    price=price, unit_cost=round(price * (1 - margin), 2),
                    perishable=perishable,
                ))
    return skus


def build_stores(rng: random.Random, n: int):
    stores, slots = [], [(c, a, p) for c, areas, p in catalog.CITIES for a in areas]
    rng.shuffle(slots)
    for i in range(n):
        city, area, pin = slots[i % len(slots)]
        stores.append(dict(store_id=i + 1, name=f"Dark Store {area}", city=city, area=area,
                           pincode_prefix=pin, opened=str(START_DATE - dt.timedelta(days=rng.randint(200, 900)))))
    return stores


def phone_number(rng):
    return str(rng.choice("6789")) + "".join(rng.choice("0123456789") for _ in range(9))


def phone_variant(p, rng):
    return rng.choice([p, p, f"+91 {p[:5]} {p[5:]}", f"+91{p}", f"0{p[:5]} {p[5:]}", f"{p[:5]}-{p[5:]}"])


def email_local(first, last, rng):
    f, l, n = first.lower(), last.lower().replace("'", ""), rng.randint(1, 99)
    return rng.choice([f"{f}.{l}", f"{f}{l}", f"{f}_{l}", f"{f[0]}{l}", f"{f}.{l}{n}", f"{f}{n}", f"{l}.{f}"])


def email_variant(local, domain, rng):
    if domain == "gmail.com":
        r = rng.random()
        if r < 0.25:
            local = local.replace(".", "")          # gmail ignores dots
        elif r < 0.4 and "." not in local and len(local) > 4:
            local = local[:3] + "." + local[3:]
        elif r < 0.5:
            local = local + "+" + rng.choice(["qc", "shop", "grocery", "offers"])
    if rng.random() < 0.15:
        local = local.upper() if rng.random() < 0.3 else local.capitalize()
    return f"{local}@{domain}"


def name_variant(first, last, rng):
    r = rng.random()
    if r < 0.45:
        return f"{first} {last}"
    if r < 0.6:
        return f"{first.lower()} {last.lower()}"
    if r < 0.7:
        return f"{first[0]}. {last}"
    if r < 0.78:
        return f"{last} {first}"
    if r < 0.86:
        return first
    if r < 0.93:  # typo
        i = rng.randrange(1, len(first))
        return f"{first[:i]}{first[i - 1]}{first[i:]} {last}"
    return f"{first} {last[:-1]}{last[-1] * 2}"


def build_people(rng: random.Random, n_persons: int, stores):
    persons, accounts = [], []
    shared_phone_pool = []
    used_mailboxes = set()
    for pid in range(1, n_persons + 1):
        first, last = rng.choice(catalog.FIRST_NAMES), rng.choice(catalog.LAST_NAMES)
        store = rng.randrange(len(stores))
        # Household members sometimes share one phone: a hard negative for identity matching.
        if shared_phone_pool and rng.random() < 0.03:
            phone = rng.choice(shared_phone_pool)
        else:
            phone = phone_number(rng)
            if rng.random() < 0.05:
                shared_phone_pool.append(phone)
        domain = rng.choice(catalog.EMAIL_DOMAINS)
        # Mailboxes are unique, so a common name gets digits appended, as real providers force.
        local = email_local(first, last, rng)
        while (local.replace(".", "") if domain == "gmail.com" else local, domain) in used_mailboxes:
            local = f"{local}{rng.randint(1, 999)}"
        used_mailboxes.add((local.replace(".", "") if domain == "gmail.com" else local, domain))
        work_email = f"{first.lower()}.{last.lower().replace(chr(39), '')}"
        work_domain = rng.choice(catalog.WORK_DOMAINS)
        while (work_email, work_domain) in used_mailboxes:
            work_email = f"{work_email}{rng.randint(1, 99)}"
        used_mailboxes.add((work_email, work_domain))
        work_email = f"{work_email}@{work_domain}"
        persons.append(dict(person_id=pid, first=first, last=last, home_store=store, phone=phone,
                            local=local, domain=domain, work_email=work_email))
        n_acc = 1 + sum(rng.random() < 0.25 for _ in range(3))
        pin = stores[store]["pincode_prefix"] + f"{rng.randint(1, 99):02d}"
        for a in range(n_acc):
            channel = "app" if a == 0 else rng.choice(catalog.CHANNELS)
            email = email_variant(local, domain, rng)
            if a > 0 and rng.random() < 0.25:
                email = work_email
            if channel == "whatsapp" or (a > 0 and rng.random() < 0.15):
                email = ""
            ph = phone_variant(phone, rng)
            if a > 0 and rng.random() < 0.2:
                ph = phone_variant(phone_number(rng), rng)      # a second SIM
            if channel != "whatsapp" and rng.random() < 0.1:
                ph = ""
            accounts.append(dict(
                account_id=len(accounts) + 100001, person_id=pid, channel=channel,
                display_name=name_variant(first, last, rng), email=email, phone=ph,
                pincode=pin if rng.random() < 0.9 else stores[store]["pincode_prefix"] + f"{rng.randint(1, 99):02d}",
                created_on=str(START_DATE - dt.timedelta(days=rng.randint(1, 700))),
            ))
    return persons, accounts


# --------------------------------------------------------------------------- simulation

def simulate(cfg, seed, out: Path, ticket_rate: float = TICKET_RATE):
    cfg = {**cfg, "ticket_rate": ticket_rate}
    t0 = time.time()
    rng = random.Random(seed)
    npr = np.random.default_rng(seed)

    skus = build_skus(rng, cfg["brands"])
    stores = build_stores(rng, cfg["stores"])
    persons, accounts = build_people(rng, cfg["persons"], stores)
    S, K, P, D = len(stores), len(skus), len(persons), cfg["days"]
    print(f"world: {S} stores, {K} SKUs, {P} persons, {len(accounts)} accounts, {D} days")

    price = np.array([s["price"] for s in skus], dtype=float)
    cost = np.array([s["unit_cost"] for s in skus], dtype=float)
    sku_cat = [s["category"] for s in skus]
    group_of = np.array([hash(s["substitute_group"]) for s in skus])
    siblings = [np.array([j for j in range(K) if group_of[j] == group_of[i] and j != i]) for i in range(K)]

    # Demand: a Zipf-like popularity per SKU, perturbed per store.
    base_pop = 1.0 / np.arange(1, K + 1) ** 0.9
    npr.shuffle(base_pop)
    store_pop = base_pop[None, :] * npr.lognormal(0, 0.35, size=(S, K))
    store_pop /= store_pop.sum(axis=1, keepdims=True)

    home = np.array([p["home_store"] for p in persons])
    # People are creatures of habit: each shopper has a short list of regulars,
    # drawn from what their store sells well, and buys from it most of the time.
    FAV = 24
    favourites = np.empty((P, FAV), dtype=np.int32)
    for s in range(S):
        m = np.nonzero(home == s)[0]
        favourites[m] = npr.choice(K, size=(len(m), FAV), p=store_pop[s])
    activity = np.clip(npr.gamma(1.5, 0.06 / 1.5, size=P), 0.004, 0.45)
    acc_by_person = [[] for _ in range(P)]
    for a in accounts:
        acc_by_person[a["person_id"] - 1].append(a["account_id"])

    # Expected daily units per SKU-store sets the inventory policy.
    persons_per_store = np.bincount(home, minlength=S)
    lam = (persons_per_store * activity.mean() * 3.4 * 1.2)[:, None] * store_pop
    order_up_to = np.ceil(lam * npr.uniform(6, 12, size=(S, K))) + 4
    reorder_pt = np.ceil(lam * 2.5) + 1
    true_oh = order_up_to.copy()
    book_oh = order_up_to.copy()
    arrival_day = np.full((S, K), -1)
    arrival_qty = np.zeros((S, K))
    count_every = npr.integers(28, 43, size=(S, K))
    count_offset = npr.integers(0, 43, size=(S, K))
    shrink = np.array([2.0 if c in HIGH_SHRINK else 1.0 for c in sku_cat])

    alive = np.ones(P, dtype=bool)
    exposure = np.zeros(P)
    churn_day = np.full(P, -1)
    churn_attrib = np.zeros(P)

    sales = np.zeros((D, S, K), dtype=np.int32)
    book_hist = np.zeros((D, S, K), dtype=np.int32)
    phantom_hist = np.zeros((D, S, K), dtype=bool)

    order_rows, line_chunks, pick_rows, return_rows = [], [], [], []
    notify_rows, ticket_rows, gt_ticket_rows, exposure_rows, count_rows = [], [], [], [], []
    next_order = 5_000_001
    next_return = 1
    next_ticket = 900_001

    def add_ticket(day, pidx, intent, sku=-1, sub=-1, order_id=None):
        nonlocal next_ticket
        p = persons[pidx]
        acc_ids = acc_by_person[pidx]
        acc = accounts[rng.choice(acc_ids) - 100001]
        r = rng.random()
        if r < 0.15:
            email, phone = p["work_email"], ""          # an address no account carries
        elif acc["email"] and r < 0.75:
            email, phone = email_variant(p["local"], p["domain"], rng) if rng.random() < 0.5 else acc["email"], ""
        else:
            email, phone = "", phone_variant(p["phone"], rng) if not acc["phone"] else acc["phone"]
        ref = f"QC{order_id}" if order_id and rng.random() < 0.45 else ""
        body = texts.make_ticket(intent, rng, product=skus[sku]["name"] if sku >= 0 else "",
                                 sub=skus[sub]["name"] if sub >= 0 else "", order_ref=ref,
                                 area=stores[p["home_store"]]["area"])
        ts = dt.datetime.combine(START_DATE + dt.timedelta(days=day), dt.time()) + dt.timedelta(
            minutes=rng.randint(7 * 60, 23 * 60))
        ticket_rows.append(dict(ticket_id=next_ticket, created_at=str(ts),
                                channel="whatsapp" if phone else rng.choice(["email", "app_chat"]),
                                from_name=name_variant(p["first"], p["last"], rng) if rng.random() < 0.8 else "",
                                from_email=email, from_phone=phone, order_ref=ref, body=body))
        gt_ticket_rows.append(dict(ticket_id=next_ticket, person_id=p["person_id"], intent=intent,
                                   sku_id=skus[sku]["sku_id"] if sku >= 0 else "", ))
        next_ticket += 1

    pending_tickets = {}   # day -> list of ticket args (customers write a day or two later)
    pending_returns = {}

    for day in range(D):
        date = START_DATE + dt.timedelta(days=day)

        # Deliveries land, cycle counts correct the book, shrink silently empties shelves.
        arrived = arrival_day == day
        true_oh[arrived] += arrival_qty[arrived]
        book_oh[arrived] += arrival_qty[arrived]
        arrival_day[arrived] = -1
        counting = (day - count_offset) % count_every == 0
        cs, ck = np.nonzero(counting)
        for s, k in zip(cs, ck):
            count_rows.append((s + 1, skus[k]["sku_id"], str(date), int(book_oh[s, k]), int(true_oh[s, k])))
        book_oh[counting] = true_oh[counting]
        hit = (true_oh > 0) & (npr.random((S, K)) < PHANTOM_HAZARD * shrink[None, :])
        true_oh[hit] = 0

        phantom_hist[day] = (book_oh > 0) & (true_oh <= 0)

        # Who orders today.
        mult = (1.25 if date.weekday() >= 5 else 1.0) * (1.8 if day in FESTIVAL_DAYS else 1.0)
        p_order = activity * mult * (1 - 0.3 * np.minimum(exposure, 1.0))
        buyers = np.nonzero(alive & (npr.random(P) < p_order))[0]
        n_ord = len(buyers)
        if n_ord:
            n_lines = 1 + npr.poisson(2.2, n_ord)
            order_ids = np.arange(next_order, next_order + n_ord)
            next_order += n_ord
            l_person = np.repeat(buyers, n_lines)
            l_order = np.repeat(order_ids, n_lines)
            l_store = home[l_person]
            # 70% of lines come from the shopper's regulars, the rest from the store's range.
            l_sku = favourites[l_person, npr.integers(0, FAV, len(l_person))].astype(int)
            explore = npr.random(len(l_person)) < 0.3
            for s in range(S):
                m = explore & (l_store == s)
                l_sku[m] = npr.choice(K, size=m.sum(), p=store_pop[s])
            l_qty = npr.choice([1, 2, 3], size=len(l_person), p=[0.8, 0.15, 0.05])

            # Items the app shows as out of stock never make it into the basket.
            visible_oos = book_oh[l_store, l_sku] <= 0
            for i in np.nonzero(visible_oos)[0]:
                if rng.random() < 0.12:
                    acc = rng.choice(acc_by_person[l_person[i]])
                    notify_rows.append((acc, int(l_store[i]) + 1, skus[l_sku[i]]["sku_id"],
                                        str(dt.datetime.combine(date, dt.time()) + dt.timedelta(minutes=rng.randint(420, 1380)))))
                if rng.random() < 0.1 * ticket_rate:
                    pending_tickets.setdefault(day + rng.randint(0, 2), []).append(
                        (int(l_person[i]), "availability_query", int(l_sku[i]), -1, None))
            keep = ~visible_oos
            l_person, l_order, l_store, l_sku, l_qty = (a[keep] for a in (l_person, l_order, l_store, l_sku, l_qty))

            # Pick in random order; a line is filled only while true stock lasts.
            order_rand = npr.random(len(l_sku))
            idx = np.lexsort((order_rand, l_sku, l_store))
            key = l_store[idx] * K + l_sku[idx]
            cum = np.cumsum(l_qty[idx])
            starts = np.r_[0, np.nonzero(np.diff(key))[0] + 1]
            group_start_cum = np.repeat(cum[starts] - l_qty[idx][starts], np.diff(np.r_[starts, len(idx)]))
            within = cum - group_start_cum
            filled_sorted = within <= true_oh[l_store[idx], l_sku[idx]]
            filled = np.empty(len(idx), dtype=bool)
            filled[idx] = filled_sorted

            status = np.where(filled, "fulfilled", "missing").astype(object)
            fulfilled_sku = np.where(filled, l_sku, -1)
            short = np.nonzero(~filled)[0]
            for i in short:
                sib = siblings[l_sku[i]]
                if len(sib) and rng.random() < 0.55:
                    j = int(rng.choice(sib))
                    if true_oh[l_store[i], j] >= l_qty[i]:
                        status[i] = "substituted"
                        fulfilled_sku[i] = j
                        true_oh[l_store[i], j] -= l_qty[i]
                        book_oh[l_store[i], j] -= l_qty[i]
            np.add.at(true_oh, (l_store[filled], l_sku[filled]), -l_qty[filled])
            np.add.at(book_oh, (l_store[filled], l_sku[filled]), -l_qty[filled])
            ok = fulfilled_sku >= 0
            np.add.at(sales[day], (l_store[ok], fulfilled_sku[ok]), l_qty[ok])

            # Orders and lines.
            uniq, first_idx = np.unique(l_order, return_index=True)
            line_no = np.arange(len(l_order)) - np.repeat(first_idx, np.diff(np.r_[first_idx, len(l_order)]))
            for oid, fi in zip(uniq, first_idx):
                pidx = int(l_person[fi])
                accs = acc_by_person[pidx]
                acc = accs[0] if (len(accs) == 1 or rng.random() < 0.75) else rng.choice(accs[1:])
                ts = dt.datetime.combine(date, dt.time()) + dt.timedelta(minutes=rng.randint(360, 1420))
                order_rows.append((int(oid), acc, int(home[pidx]) + 1, str(ts)))
            line_chunks.append(dict(
                order_id=l_order, line_no=line_no + 1, sku=l_sku, qty=l_qty,
                fulfilled_sku=fulfilled_sku, status=status))

            # Silent failures ripple out to the customer.
            for i in np.nonzero(status != "fulfilled")[0]:
                pidx, kind = int(l_person[i]), status[i]
                exposure[pidx] += SEVERITY[kind]
                exposure_rows.append((persons[pidx]["person_id"], str(date), int(l_store[i]) + 1,
                                      skus[l_sku[i]]["sku_id"], int(l_order[i]), kind,
                                      bool(phantom_hist[day, l_store[i], l_sku[i]])))
                if rng.random() < 0.35:
                    pick_rows.append((int(l_store[i]) + 1, skus[l_sku[i]]["sku_id"], str(date), int(l_order[i]),
                                      "substituted" if kind == "substituted" else "not_found"))
                p_ticket = ticket_rate if kind == "missing" else 0.6 * ticket_rate
                if rng.random() < p_ticket:
                    intent = "missing_item" if kind == "missing" else "substitution_complaint"
                    pending_tickets.setdefault(day + rng.choice([0, 0, 1, 1, 2]), []).append(
                        (pidx, intent, int(l_sku[i]), int(fulfilled_sku[i]) if kind == "substituted" else -1, int(l_order[i])))
                if kind == "substituted" and rng.random() < 0.25:
                    pending_returns.setdefault(day + rng.randint(0, 3), []).append(
                        (int(l_order[i]), int(line_no[i]) + 1, int(fulfilled_sku[i]), int(l_qty[i]), pidx, True))
            # Ordinary returns happen too, unrelated to stock.
            normal = np.nonzero((status == "fulfilled") & (npr.random(len(status)) < 0.015))[0]
            for i in normal:
                pending_returns.setdefault(day + rng.randint(0, 3), []).append(
                    (int(l_order[i]), int(line_no[i]) + 1, int(l_sku[i]), int(l_qty[i]), int(l_person[i]), False))

        # Background tickets unrelated to stock.
        bg = np.nonzero(alive & (npr.random(P) < 0.0012))[0]
        for pidx in bg:
            intent = rng.choice(["late_delivery", "late_delivery", "quality_issue", "payment_issue", "general"])
            sku = rng.randrange(K) if intent == "quality_issue" else -1
            pending_tickets.setdefault(day, []).append((int(pidx), intent, sku, -1, None))

        for (oid, ln, k, q, pidx, was_sub) in pending_returns.pop(day, []):
            reason = (rng.choices(["not_as_expected", "wrong_item", "quality", "other"], [0.4, 0.25, 0.2, 0.15])[0]
                      if was_sub else rng.choices(["quality", "damaged", "not_as_expected", "other"], [0.4, 0.3, 0.2, 0.1])[0])
            return_rows.append((next_return, oid, ln, str(date), reason, round(price[k] * q, 2)))
            next_return += 1
            if was_sub:
                exposure[pidx] += SEVERITY["returned"]
        for args in pending_tickets.pop(day, []):
            if alive[args[0]] or args[1] == "account_closure":
                add_ticket(day, *args)

        # Churn: baseline hazard, raised by recent bad experiences.
        hazard = CHURN_BASE * (1 + CHURN_BETA * exposure)
        leaving = np.nonzero(alive & (npr.random(P) < hazard))[0]
        for pidx in leaving:
            alive[pidx] = False
            churn_day[pidx] = day
            churn_attrib[pidx] = CHURN_BETA * exposure[pidx] / (1 + CHURN_BETA * exposure[pidx])
            if rng.random() < 0.12:
                add_ticket(day, int(pidx), "account_closure")
        exposure *= EXPOSURE_DECAY

        # Replenishment follows the book, which is why phantoms persist.
        need = (book_oh <= reorder_pt) & (arrival_day < 0)
        lead = np.where(npr.random((S, K)) < 0.05, npr.integers(4, 9, (S, K)), npr.integers(1, 3, (S, K)))
        arrival_day[need] = day + lead[need]
        arrival_qty[need] = np.maximum(order_up_to[need] - book_oh[need], 1)
        book_hist[day] = np.maximum(book_oh, 0)
        if day % 20 == 0:
            print(f"  day {day:3d}  orders={n_ord:5d}  alive={alive.sum():6d}  phantoms={phantom_hist[day].sum():4d}  "
                  f"{time.time() - t0:5.1f}s")

    write_all(out, cfg, seed, stores, skus, accounts, persons, order_rows, line_chunks, pick_rows,
              return_rows, notify_rows, ticket_rows, gt_ticket_rows, exposure_rows, count_rows,
              sales, book_hist, phantom_hist, churn_day, churn_attrib, D, S, K)
    print(f"done in {time.time() - t0:.1f}s -> {out}")


# --------------------------------------------------------------------------- output

def write_csv(path: Path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)


def write_all(out, cfg, seed, stores, skus, accounts, persons, order_rows, line_chunks, pick_rows,
              return_rows, notify_rows, ticket_rows, gt_ticket_rows, exposure_rows, count_rows,
              sales, book_hist, phantom_hist, churn_day, churn_attrib, D, S, K):
    out.mkdir(parents=True, exist_ok=True)
    sku_ids = np.array([s["sku_id"] for s in skus])
    dates = [str(START_DATE + dt.timedelta(days=d)) for d in range(D)]

    write_csv(out / "stores.csv", list(stores[0]), [s.values() for s in stores])
    write_csv(out / "skus.csv", list(skus[0]), [s.values() for s in skus])
    acc_cols = ["account_id", "channel", "display_name", "email", "phone", "pincode", "created_on"]
    write_csv(out / "accounts.csv", acc_cols, [[a[c] for c in acc_cols] for a in accounts])
    write_csv(out / "orders.csv", ["order_id", "account_id", "store_id", "ordered_at"], order_rows)

    import pandas as pd
    price_by_idx = np.array([sk["price"] for sk in skus])
    n_lines = 0
    with open(out / "order_lines.csv", "w", newline="", encoding="utf-8") as f:
        f.write("order_id,line_no,sku_id,qty,fulfilled_sku_id,line_status,unit_price\r\n")
        for ch in line_chunks:
            got = ch["fulfilled_sku"] >= 0
            df = pd.DataFrame({
                "order_id": ch["order_id"], "line_no": ch["line_no"], "sku_id": sku_ids[ch["sku"]], "qty": ch["qty"],
                "fulfilled_sku_id": pd.array(np.where(got, sku_ids[np.maximum(ch["fulfilled_sku"], 0)], 0), dtype="Int64"),
                "line_status": ch["status"],
                "unit_price": price_by_idx[np.where(got, ch["fulfilled_sku"], ch["sku"])],
            })
            df.loc[~got, "fulfilled_sku_id"] = pd.NA
            df.to_csv(f, header=False, index=False, lineterminator="\r\n")
            n_lines += len(df)
    write_csv(out / "pick_exceptions.csv", ["store_id", "sku_id", "pick_date", "order_id", "reason"], pick_rows)
    write_csv(out / "returns.csv", ["return_id", "order_id", "line_no", "return_date", "reason_code", "refund_amount"],
              return_rows)
    write_csv(out / "notify_requests.csv", ["account_id", "store_id", "sku_id", "requested_at"], notify_rows)
    write_csv(out / "tickets.csv", list(ticket_rows[0]), [t.values() for t in ticket_rows])
    write_csv(out / "cycle_counts.csv", ["store_id", "sku_id", "count_date", "book_qty", "counted_qty"], count_rows)

    d_idx, s_idx, k_idx = np.nonzero(sales)
    write_csv(out / "sales_daily.csv", ["sale_date", "store_id", "sku_id", "units"],
              ((dates[d], s + 1, int(sku_ids[k]), int(sales[d, s, k])) for d, s, k in zip(d_idx, s_idx, k_idx)))
    write_csv(out / "inventory_book.csv", ["snapshot_date", "store_id", "sku_id", "book_qty"],
              ((dates[d], s + 1, int(sku_ids[k]), int(book_hist[d, s, k]))
               for d in range(D) for s in range(S) for k in range(K)))

    # Ground truth (never read by Ripple, only by the evaluation step).
    events = []
    for s in range(S):
        for k in range(K):
            run = phantom_hist[:, s, k]
            if not run.any():
                continue
            edges = np.diff(np.r_[0, run.astype(int), 0])
            for a, b in zip(np.nonzero(edges == 1)[0], np.nonzero(edges == -1)[0]):
                events.append((len(events) + 1, s + 1, int(sku_ids[k]), dates[a], dates[b - 1], int(b - a)))
    write_csv(out / "gt_phantom_events.csv", ["event_id", "store_id", "sku_id", "start_date", "end_date", "days"], events)
    write_csv(out / "gt_identity.csv", ["account_id", "person_id"], [(a["account_id"], a["person_id"]) for a in accounts])
    write_csv(out / "gt_tickets.csv", ["ticket_id", "person_id", "intent", "sku_id"], [t.values() for t in gt_ticket_rows])
    write_csv(out / "gt_exposures.csv", ["person_id", "exposure_date", "store_id", "sku_id", "order_id", "kind",
                                         "during_phantom"], exposure_rows)
    write_csv(out / "gt_churn.csv", ["person_id", "churn_date", "stockout_attributable_share"],
              [(i + 1, dates[c], round(float(churn_attrib[i]), 4)) for i, c in enumerate(churn_day) if c >= 0])
    with open(out / "MANIFEST.txt", "w") as f:
        f.write(f"seed={seed}\nconfig={cfg}\nstart_date={START_DATE}\n")
        f.write(f"phantom_events={len(events)} orders={len(order_rows)} lines={n_lines} tickets={len(ticket_rows)}\n")
    print(f"phantom events={len(events)} orders={len(order_rows)} lines={n_lines} tickets={len(ticket_rows)} "
          f"returns={len(return_rows)} churned={(churn_day >= 0).sum()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scale", choices=SCALES, default="demo")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--ticket-rate", type=float, default=TICKET_RATE,
                    help="share of shoppers with a missing item who raise a ticket (default %(default)s)")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    simulate(SCALES[args.scale], args.seed, args.out or Path("data") / args.scale, args.ticket_rate)


if __name__ == "__main__":
    main()
