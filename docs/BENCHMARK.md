# Benchmark

Measured on a Windows 11 laptop (8 GB RAM, 8 logical cores) running Exasol Personal 2026.2 as a single node in WSL 2 with about 4 GB of memory. Seed 42. Re-run with `python -m ripple.build --scale large`; timings vary by a minute or so with whatever else the machine is doing.

## Large world: 30 stores, 356 SKUs, 200,000 shoppers, 180 days

Generation 45 s; load 28 s.

| Area | Metric | Variant | Value |
|---|---|---|---|
| causal | att_lost_rate | missing | 0.0552 |
| causal | att_lost_rate | substituted | 0.0206 |
| causal | att_true_churn | missing | 0.1151 |
| causal | att_true_churn | substituted | 0.0732 |
| causal | ci95 | missing | 0.0049 |
| causal | ci95 | substituted | 0.0047 |
| detector | days_early_vs_book | all | 14.5810 |
| detector | days_early_vs_book | pos_only | 12.5437 |
| detector | days_early_vs_book | pos_tickets | 13.3543 |
| detector | days_onset_to_alert | all | 1.3153 |
| detector | days_onset_to_alert | pos_only | 6.6900 |
| detector | days_onset_to_alert | pos_tickets | 4.8148 |
| detector | precision | all | 0.8612 |
| detector | precision | pos_only | 0.9347 |
| detector | precision | pos_tickets | 0.9260 |
| detector | recall | all | 0.9078 |
| detector | recall | pos_only | 0.6982 |
| detector | recall | pos_tickets | 0.7572 |
| identity | accounts |  | 349,594.0000 |
| identity | pair_precision |  | 0.9979 |
| identity | pair_recall |  | 0.8351 |
| identity | resolved_people |  | 221,808.0000 |
| identity | true_people |  | 200,000.0000 |
| ledger | exposure_precision |  | 0.9615 |
| ledger | exposure_recall |  | 0.9887 |
| ledger | lost_sale_only_inr |  | 2,643,589.8000 |
| ledger | total_bill_inr |  | 16,317,688.0915 |
| tickets | intent_accuracy |  | 0.9642 |
| tickets | owner_accuracy |  | 0.9912 |
| tickets | owner_linked_share |  | 0.8842 |
| tickets | sku_accuracy |  | 0.8555 |

| Stage | Seconds |
|---|---|
| 20_identity.sql | 13.1 |
| 30_tickets.sql | 33.1 |
| 40_detector.sql | 298.7 |
| 50_causal.sql | 9.3 |
| 60_ledger.sql | 2.6 |
| 70_recount.sql | 3.8 |
| 90_eval.sql | 1.8 |

| Table | Rows |
|---|---|
| INVENTORY_BOOK | 1,922,400 |
| SALES_DAILY | 1,285,886 |
| ACCOUNTS | 349,594 |
| ORDERS | 1,807,931 |
| ORDER_LINES | 5,724,529 |
| TICKETS | 81,868 |
| PRODUCT_RETURNS | 102,060 |

## Demo world: 12 stores, 267 SKUs, 40,000 shoppers, 120 days

| Area | Metric | Variant | Value |
|---|---|---|---|
| causal | att_lost_rate | missing | 0.0556 |
| causal | att_lost_rate | substituted | 0.0139 |
| causal | att_true_churn | missing | 0.1207 |
| causal | att_true_churn | substituted | 0.0652 |
| causal | ci95 | missing | 0.0146 |
| causal | ci95 | substituted | 0.0139 |
| detector | days_early_vs_book | all | 14.5770 |
| detector | days_early_vs_book | pos_only | 11.6041 |
| detector | days_early_vs_book | pos_tickets | 13.0191 |
| detector | days_onset_to_alert | all | 1.5748 |
| detector | days_onset_to_alert | pos_only | 8.1202 |
| detector | days_onset_to_alert | pos_tickets | 5.8142 |
| detector | precision | all | 0.8369 |
| detector | precision | pos_only | 0.8880 |
| detector | precision | pos_tickets | 0.9062 |
| detector | recall | all | 0.8764 |
| detector | recall | pos_only | 0.6483 |
| detector | recall | pos_tickets | 0.6958 |
| identity | accounts |  | 70,107.0000 |
| identity | pair_precision |  | 0.9991 |
| identity | pair_recall |  | 0.8301 |
| identity | resolved_people |  | 44,540.0000 |
| identity | true_people |  | 40,000.0000 |
| ledger | exposure_precision |  | 0.9574 |
| ledger | exposure_recall |  | 0.9850 |
| ledger | lost_sale_only_inr |  | 439,538.3700 |
| ledger | total_bill_inr |  | 2,507,045.6791 |
| tickets | intent_accuracy |  | 0.9637 |
| tickets | owner_accuracy |  | 0.9925 |
| tickets | owner_linked_share |  | 0.8835 |
| tickets | sku_accuracy |  | 0.8530 |

| Stage | Seconds |
|---|---|
| 20_identity.sql | 7.4 |
| 30_tickets.sql | 10.6 |
| 40_detector.sql | 72.2 |
| 50_causal.sql | 1.8 |
| 60_ledger.sql | 1.9 |
| 70_recount.sql | 1.1 |
| 90_eval.sql | 1.1 |

| Table | Rows |
|---|---|
| INVENTORY_BOOK | 384,480 |
| SALES_DAILY | 229,563 |
| ACCOUNTS | 70,107 |
| ORDERS | 265,786 |
| ORDER_LINES | 840,823 |
| TICKETS | 11,695 |
| PRODUCT_RETURNS | 14,680 |
