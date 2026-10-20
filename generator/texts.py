"""Support-ticket text generator.

Tickets are written the way customers actually write: short, misspelt,
sometimes in Hinglish, often naming the product loosely ("milk", "the
nandi one"). The intent label is kept only in the ground-truth table so the
in-database classifier has to earn it.
"""

import random

OPENERS = ["", "", "Hi, ", "Hello team, ", "hi ", "Dear support, ", "Bhai ", "Hey, ", "Sir, "]
CLOSERS = ["", "", " Thanks.", " pls check", " Please help.", " very disappointed.",
           " plz resolve asap", " thx", " Regards."]

TEMPLATES = {
    "substitution_complaint": [
        "I ordered {product} but you sent {sub} instead. Nobody asked me.",
        "ordered {short} got {sub_short} instead?? why replace without asking",
        "you replaced my {short} with {sub_short}. i did not want this",
        "{product} was replaced with some other brand. not what I paid for",
        "maine {short} order kiya tha, {sub_short} bhej diya. ye kya hai",
        "Received {sub} in place of {product}. Want refund for this item.",
        "substitute item sent for {short}, quality is not same",
        "why do you keep swapping {short}? second time this happened",
    ],
    "missing_item": [
        "{product} was missing from my order {order}.",
        "order {order} came without the {short}. charged for it though",
        "item missing: {product}. please refund",
        "{short} nahi aaya order me, paise kat gaye",
        "my {short} was not in the bag. delivery guy said it was out of stock",
        "Missing {short} in todays delivery. Third time.",
        "you cancelled {short} from my order after I paid. app showed it available!",
    ],
    "availability_query": [
        "is {product} back in stock?",
        "when will {short} be available again",
        "{short} showing out of stock since days. when restock?",
        "app says {short} in stock but it never gets delivered. whats going on",
        "{short} kab aayega wapas?",
        "please notify me when {product} is available",
        "cant find {short} anymore. discontinued?",
    ],
    "late_delivery": [
        "order {order} is 40 minutes late. 10 minute delivery my foot",
        "delivery delayed again. order {order}",
        "Still waiting for my order {order}.",
        "rider not moving on map for 20 min",
    ],
    "quality_issue": [
        "{short} was expired. order {order}",
        "{short} packet was torn",
        "{product} was spoiled when it arrived",
        "received damaged {short}",
    ],
    "payment_issue": [
        "money debited twice for order {order}",
        "refund not received yet for {order}",
        "UPI payment failed but amount deducted",
        "coupon not applied on my order",
    ],
    "account_closure": [
        "please delete my account. done with this app",
        "I want to close my account. switching to another app",
        "unsubscribe me and delete my data",
        "deactivate my account, too many issues with my orders",
        "band karo mera account",
    ],
    "general": [
        "how do I change my delivery address",
        "can I schedule delivery for tomorrow morning",
        "app is crashing on checkout",
        "how to apply referral code",
        "do you deliver to {area}",
    ],
}


def _shorten(product_name: str, rng: random.Random) -> str:
    # Customers rarely type the full catalogue name.
    words = [w for w in product_name.split()
             if not any(c.isdigit() for c in w) and w not in ("pcs", "tabs", "sachets", "pack")]
    choice = rng.random()
    if choice < 0.35:
        return " ".join(words[-3:-1]).lower() if len(words) >= 3 else product_name.lower()
    if choice < 0.6:
        return words[-2].lower() if len(words) >= 2 else product_name.lower()
    if choice < 0.8:
        return " ".join(words[:2]).lower()
    return product_name


def _typo(text: str, rng: random.Random, rate: float = 0.025) -> str:
    out = []
    for ch in text:
        r = rng.random()
        if ch.isalpha() and r < rate / 3:
            continue  # dropped letter
        if ch.isalpha() and r < 2 * rate / 3:
            out.append(ch + ch)  # doubled letter
            continue
        out.append(ch)
    return "".join(out)


def make_ticket(intent: str, rng: random.Random, product: str = "", sub: str = "",
                order_ref: str = "", area: str = "") -> str:
    template = rng.choice(TEMPLATES[intent])
    if not order_ref:
        template = template.replace("order {order}", "my order").replace(" {order}", "")
    body = template.format(
        product=product, short=_shorten(product, rng) if product else "item",
        sub=sub, sub_short=_shorten(sub, rng) if sub else "something else",
        order=order_ref or "", area=area,
    ).replace("  ", " ").strip()
    body = rng.choice(OPENERS) + body + rng.choice(CLOSERS)
    if rng.random() < 0.3:
        body = body.lower()
    return _typo(body, rng)
