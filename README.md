# DEPI SQL Capstone: Olist Late-Delivery Feature Store

A PostgreSQL-native feature store for predicting **`is_late_delivery`** on the Olist e-commerce dataset (CRISP-DM phases 1-3).
**No Pandas/Polars**: all cleaning and feature engineering runs in SQL; Python (`psycopg2` + built-in `csv`) only orchestrates.

## Setup
```bash
python -m venv venv && source venv/bin/activate      # Windows: venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env                                  # fill in DB credentials
python main.py --all                                  # or: python main.py --phase 2 | interactive: python main.py
```
Expected raw tables in the `_messy` database: `olist_orders_dataset`, `olist_order_items_dataset`,
`olist_order_payments_dataset`, `olist_customers_dataset`, `olist_sellers_dataset`
(edit `RAW_TABLES` in `config.py` and the SQL files if yours are named differently).

## Architecture
```
main.py (CLI) -> etl.py -> scripts/phase1.py -> pipeline_metadata table (objectives, ROI)
                        -> scripts/phase2.py -> sql/audit_queries.sql -> outputs/phase2_*.csv
                        -> scripts/phase3.py -> sql/data_cleaning.sql -> clean_* tables
                                             -> sql/feature_store.sql -> MATERIALIZED VIEW feature_store
                                             -> outputs/feature_store_export.csv
```
Raw tables are never modified. Helper SQL functions `safe_numeric()` / `safe_ts()` turn messy text into
NULL instead of failing on bad casts.

## Cleaning rules (all in SQL)
| Step | Technique |
|---|---|
| Deduplication | `ROW_NUMBER() OVER (PARTITION BY key ORDER BY ...)` on orders, items, payments, customers, sellers |
| Cohort | Delivered orders with valid, correctly ordered timestamps |
| Imputation | `COALESCE` / median for price and freight, `approved_ts` <- purchase time, state -> `'UNK'`, installments -> 1 |
| Outliers | Winsorization at the 99th percentile (`PERCENTILE_CONT(0.99)` + `LEAST`) for price, freight, payment value |

## Data Dictionary: `feature_store` (one row per order)
| Column | Type | Description / transformation |
|---|---|---|
| order_id | text | Primary key (validated 32-hex, deduplicated) |
| customer_unique_id | text | Real customer identity, used for frequency features |
| purchase_ts | timestamp | Parsed purchase time (use for time-based train/test split) |
| purchase_hour / purchase_dow / purchase_month | int | `EXTRACT` from purchase_ts (DOW is ISO 1-7) |
| is_weekend | int | 1 if ISO day-of-week >= 6 |
| approval_delay_hours | numeric | Hours from purchase to approval (floored at 0, imputed approval = purchase) |
| estimated_delivery_days | numeric | Days promised between purchase and estimated delivery date |
| n_items / n_distinct_products / n_distinct_sellers | int | Item aggregates per order |
| order_items_value | numeric | Sum of capped item prices |
| order_freight_value | numeric | Sum of capped freight |
| freight_ratio | numeric | freight / items value |
| avg_item_price / max_item_price | numeric | Item price stats |
| any_item_price_capped | int | 1 if any item was winsorized at p99 |
| order_value_tier | text | `CASE WHEN` bucket: low (<50), medium (<150), high |
| customer_region / seller_region | text | 27 state codes bucketed to SP, SE_other, South, Other, UNK (seller = alphabetically first seller state) |
| is_cross_state | int | 1 if any seller state differs from customer state |
| total_payment_value | numeric | Sum of capped payments (falls back to items + freight) |
| max_installments | int | Max installments across payments |
| n_payment_methods | int | Distinct payment types |
| primary_payment_type | text | Type with largest payment: credit_card, boleto, voucher, debit_card, other, unknown |
| prior_order_count | bigint | Orders by the customer strictly before this one (`COUNT() OVER` frame ending 1 PRECEDING) |
| is_first_order | int | 1 if prior_order_count = 0 |
| days_since_prev_order | numeric | Recency via `LAG(purchase_ts)`; NULL for first orders |
| prior_cumulative_spend | numeric | Running past spend (`SUM() OVER`) |
| rolling_avg_spend_last3 | numeric | Avg spend of the previous 3 orders |
| leak_actual_delivery_days | numeric | **Leakage**: purchase to delivery (analysis only) |
| leak_delivery_vs_estimate_days | numeric | **Leakage**: delivery minus estimate (defines the target) |
| leak_purchase_to_carrier_days | numeric | **Leakage**: purchase to carrier handoff |
| **is_late_delivery** | int | **TARGET**: 1 if delivered date > estimated date, else 0 |

> Drop all `leak_*` columns (and `purchase_ts`, IDs) before model training.

## Outputs
`outputs/phase2_eda_summary.csv`, `outputs/phase2_quality_audit.csv`, `outputs/feature_store_export.csv`.
