# Benchmark

Measured on a Windows 11 laptop (8 GB RAM, 8 logical cores) running Exasol Personal 2026.2 as a single node in WSL 2 with about 4 GB of memory. Seed 42, complaint rate 4% (the default). Re-run with `python -m ripple.build --scale large`; timings vary by a minute or so with whatever else the machine is doing.

## Large world: 30 stores, 356 SKUs, 200,000 shoppers, 180 days

Generation 63 s; load 32 s; whole build 403 s.

| Area | Metric | Variant | Value |
|---|---|---|---|
| causal | att_lost_rate | missing | 0.0558 |
| causal | att_lost_rate | substituted | 0.0224 |
| causal | att_true_churn | missing | 0.1134 |
| causal | att_true_churn | substituted | 0.0796 |
| causal | ci95 | missing | 0.0050 |
| causal | ci95 | substituted | 0.0047 |
| detector | days_early_vs_book | all | 14.5498 |
| detector | days_early_vs_book | pos_only | 12.2162 |
| detector | days_early_vs_book | pos_tickets | 12.3005 |
| detector | days_onset_to_alert | all | 1.3392 |
| detector | days_onset_to_alert | pos_only | 6.5889 |
| detector | days_onset_to_alert | pos_tickets | 6.4564 |
| detector | precision | all | 0.8984 |
| detector | precision | pos_only | 0.9227 |
| detector | precision | pos_tickets | 0.9293 |
| detector | recall | all | 0.9204 |
| detector | recall | pos_only | 0.7274 |
| detector | recall | pos_tickets | 0.7301 |
| identity | accounts |  | 349,594.0000 |
| identity | pair_precision |  | 0.9981 |
| identity | pair_recall |  | 0.8343 |
| identity | resolved_people |  | 221,941.0000 |
| identity | true_people |  | 200,000.0000 |
| ledger | exposure_precision |  | 0.9697 |
| ledger | exposure_recall |  | 0.9873 |
| ledger | lost_sale_only_inr |  | 2,501,537.9000 |
| ledger | total_bill_inr |  | 14,553,292.2516 |
| tickets | intent_accuracy |  | 0.9671 |
| tickets | owner_accuracy |  | 0.9889 |
| tickets | owner_linked_share |  | 0.8615 |
| tickets | sku_accuracy |  | 0.8585 |

| Stage | Seconds |
|---|---|
| 20_identity.sql | 14.5 |
| 30_tickets.sql | 10.6 |
| 40_detector.sql | 255.0 |
| 50_causal.sql | 7.3 |
| 60_ledger.sql | 2.0 |
| 70_recount.sql | 2.1 |
| 80_makegood.sql | 3.6 |
| 90_eval.sql | 1.3 |
| 95_baselines.sql | 5.6 |

| Table | Rows |
|---|---|
| INVENTORY_BOOK | 1,922,400 |
| SALES_DAILY | 1,289,721 |
| ACCOUNTS | 349,594 |
| ORDERS | 1,819,270 |
| ORDER_LINES | 5,763,509 |
| TICKETS | 48,680 |
| PRODUCT_RETURNS | 101,284 |

## Demo world: 12 stores, 267 SKUs, 40,000 shoppers, 120 days

| Area | Metric | Variant | Value |
|---|---|---|---|
| causal | att_lost_rate | missing | 0.0461 |
| causal | att_lost_rate | substituted | 0.0017 |
| causal | att_true_churn | missing | 0.1219 |
| causal | att_true_churn | substituted | 0.0779 |
| causal | ci95 | missing | 0.0145 |
| causal | ci95 | substituted | 0.0138 |
| detector | days_early_vs_book | all | 14.1926 |
| detector | days_early_vs_book | pos_only | 11.4970 |
| detector | days_early_vs_book | pos_tickets | 11.6314 |
| detector | days_onset_to_alert | all | 1.5733 |
| detector | days_onset_to_alert | pos_only | 8.0152 |
| detector | days_onset_to_alert | pos_tickets | 7.8127 |
| detector | precision | all | 0.8616 |
| detector | precision | pos_only | 0.8777 |
| detector | precision | pos_tickets | 0.8803 |
| detector | recall | all | 0.9067 |
| detector | recall | pos_only | 0.6548 |
| detector | recall | pos_tickets | 0.6567 |
| identity | accounts |  | 70,107.0000 |
| identity | pair_precision |  | 0.9989 |
| identity | pair_recall |  | 0.8303 |
| identity | resolved_people |  | 44,541.0000 |
| identity | true_people |  | 40,000.0000 |
| ledger | exposure_precision |  | 0.9855 |
| ledger | exposure_recall |  | 0.9873 |
| ledger | lost_sale_only_inr |  | 494,739.0600 |
| ledger | total_bill_inr |  | 2,102,762.6663 |
| tickets | intent_accuracy |  | 0.9626 |
| tickets | owner_accuracy |  | 0.9898 |
| tickets | owner_linked_share |  | 0.8687 |
| tickets | sku_accuracy |  | 0.8478 |

| Stage | Seconds |
|---|---|
| 20_identity.sql | 4.8 |
| 30_tickets.sql | 2.8 |
| 40_detector.sql | 47.5 |
| 50_causal.sql | 1.3 |
| 60_ledger.sql | 0.9 |
| 70_recount.sql | 0.6 |
| 80_makegood.sql | 1.0 |
| 90_eval.sql | 0.7 |
| 95_baselines.sql | 1.7 |

| Table | Rows |
|---|---|
| INVENTORY_BOOK | 384,480 |
| SALES_DAILY | 228,965 |
| ACCOUNTS | 70,107 |
| ORDERS | 262,878 |
| ORDER_LINES | 834,128 |
| TICKETS | 6,982 |
| PRODUCT_RETURNS | 15,047 |

## Complaint-rate stress test (demo world)

Run with `python -m ripple.sweep`. Each rate is a freshly generated world with the same seed.

| Shoppers who write in | 2% | 4% | 10% | 25% |
|---|---|---|---|---|
| Phantoms caught, all systems | 86.8% | 90.7% | 91.1% | 86.7% |
| Precision, all systems | 85.4% | 86.2% | 88.4% | 84.1% |
| Days to alert | 1.7 | 1.6 | 1.9 | 1.8 |
| Phantoms caught, sales only | 60.9% | 65.5% | 66.3% | 59.7% |
