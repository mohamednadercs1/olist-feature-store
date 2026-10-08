-- =====================================================================
-- Phase 3b: Master Feature Store (MATERIALIZED VIEW), one row per order.
-- Columns prefixed leak_ are post-outcome and MUST NOT be used as model inputs.
-- =====================================================================
DROP MATERIALIZED VIEW IF EXISTS feature_store;

CREATE MATERIALIZED VIEW feature_store AS
WITH item_agg AS (
    SELECT i.order_id,
           COUNT(*)                          AS n_items,
           COUNT(DISTINCT i.product_id)      AS n_distinct_products,
           COUNT(DISTINCT i.seller_id)       AS n_distinct_sellers,
           SUM(i.price)::numeric AS order_items_value,
           SUM(i.freight_value)::numeric AS order_freight_value,
           AVG(i.price)::numeric AS avg_item_price,
           MAX(i.price)::numeric AS max_item_price,
           BOOL_OR(i.price_was_capped)::int  AS any_item_price_capped,
           MIN(s.seller_state)               AS seller_state,
           BOOL_OR(s.seller_state IS DISTINCT FROM c.customer_state)::int AS is_cross_state
    FROM clean_order_items i
    JOIN clean_orders o     ON o.order_id = i.order_id
    JOIN clean_customers c  ON c.customer_id = o.customer_id
    LEFT JOIN clean_sellers s ON s.seller_id = i.seller_id
    GROUP BY i.order_id
),
pay_agg AS (
    SELECT order_id,
           SUM(payment_value)::numeric AS total_payment_value,
           MAX(payment_installments)          AS max_installments,
           COUNT(DISTINCT payment_type)       AS n_payment_methods,
           (ARRAY_AGG(payment_type ORDER BY payment_value DESC))[1] AS primary_payment_type
    FROM clean_payments
    GROUP BY order_id
),
base AS (
    SELECT o.*, c.customer_unique_id, c.customer_state,
           ia.n_items, ia.n_distinct_products, ia.n_distinct_sellers,
           ia.order_items_value, ia.order_freight_value, ia.avg_item_price, ia.max_item_price,
           ia.any_item_price_capped, ia.seller_state, ia.is_cross_state,
           COALESCE(pa.total_payment_value, ia.order_items_value + ia.order_freight_value) AS total_payment_value,
           COALESCE(pa.max_installments, 1)           AS max_installments,
           COALESCE(pa.n_payment_methods, 0)          AS n_payment_methods,
           COALESCE(pa.primary_payment_type, 'unknown') AS primary_payment_type
    FROM clean_orders o
    JOIN clean_customers c ON c.customer_id = o.customer_id
    JOIN item_agg ia       ON ia.order_id = o.order_id
    LEFT JOIN pay_agg pa   ON pa.order_id = o.order_id
)
SELECT
    order_id,
    customer_unique_id,
    purchase_ts,
    -- date / time features
    EXTRACT(HOUR   FROM purchase_ts)::int                     AS purchase_hour,
    EXTRACT(ISODOW FROM purchase_ts)::int                     AS purchase_dow,
    EXTRACT(MONTH  FROM purchase_ts)::int                     AS purchase_month,
    (EXTRACT(ISODOW FROM purchase_ts) >= 6)::int              AS is_weekend,
    ROUND(GREATEST(EXTRACT(EPOCH FROM (approved_ts - purchase_ts)), 0) / 3600.0, 2) AS approval_delay_hours,
    ROUND(EXTRACT(EPOCH FROM (estimated_ts - purchase_ts)) / 86400.0, 2)           AS estimated_delivery_days,
    -- order composition / monetary
    n_items, n_distinct_products, n_distinct_sellers,
    ROUND(order_items_value, 2)   AS order_items_value,
    ROUND(order_freight_value, 2) AS order_freight_value,
    ROUND(order_freight_value / NULLIF(order_items_value, 0), 4) AS freight_ratio,
    ROUND(avg_item_price, 2)      AS avg_item_price,
    ROUND(max_item_price, 2)      AS max_item_price,
    any_item_price_capped,
    CASE WHEN order_items_value < 50 THEN 'low'
         WHEN order_items_value < 150 THEN 'medium'
         ELSE 'high' END          AS order_value_tier,
    -- geography (CASE WHEN bucketing of the 27 state codes)
    CASE WHEN customer_state = 'SP' THEN 'SP'
         WHEN customer_state IN ('RJ','MG','ES') THEN 'SE_other'
         WHEN customer_state IN ('PR','SC','RS') THEN 'South'
         WHEN customer_state = 'UNK' THEN 'UNK' ELSE 'Other' END AS customer_region,
    CASE WHEN seller_state = 'SP' THEN 'SP'
         WHEN seller_state IN ('RJ','MG','ES') THEN 'SE_other'
         WHEN seller_state IN ('PR','SC','RS') THEN 'South'
         WHEN seller_state = 'UNK' THEN 'UNK' ELSE 'Other' END AS seller_region,
    is_cross_state,
    -- payment
    ROUND(total_payment_value, 2) AS total_payment_value,
    max_installments,
    n_payment_methods,
    CASE WHEN primary_payment_type IN ('credit_card','boleto','voucher','debit_card')
         THEN primary_payment_type ELSE 'other' END AS primary_payment_type,
    -- customer frequency / recency (window functions, strictly past-looking)
    COUNT(*) OVER w_prior                                      AS prior_order_count,
    (COUNT(*) OVER w_prior = 0)::int                           AS is_first_order,
    ROUND(EXTRACT(EPOCH FROM (purchase_ts - LAG(purchase_ts) OVER w_cust)) / 86400.0, 2) AS days_since_prev_order,
    ROUND(COALESCE(SUM(order_items_value) OVER w_prior, 0), 2) AS prior_cumulative_spend,
    ROUND(AVG(order_items_value) OVER (w_cust ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 2) AS rolling_avg_spend_last3,
    -- leakage-prone delivery deltas (analysis only, not model inputs)
    ROUND(EXTRACT(EPOCH FROM (delivered_ts - purchase_ts))  / 86400.0, 2) AS leak_actual_delivery_days,
    ROUND(EXTRACT(EPOCH FROM (delivered_ts - estimated_ts)) / 86400.0, 2) AS leak_delivery_vs_estimate_days,
    ROUND(EXTRACT(EPOCH FROM (carrier_ts - purchase_ts))    / 86400.0, 2) AS leak_purchase_to_carrier_days,
    -- TARGET
    is_late_delivery
FROM base
WINDOW w_cust  AS (PARTITION BY customer_unique_id ORDER BY purchase_ts, order_id),
       w_prior AS (w_cust ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING);

CREATE UNIQUE INDEX idx_feature_store_order ON feature_store (order_id);
