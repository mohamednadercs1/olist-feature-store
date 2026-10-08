-- =====================================================================
-- Phase 2 audit queries (Olist messy DB). All logic runs inside PostgreSQL.
-- Queries are separated by "-- name: <id>" markers and loaded by phase2.py.
-- =====================================================================

-- name: helpers
CREATE OR REPLACE FUNCTION safe_numeric(t text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN TRIM(t) ~ '^-?\d+(\.\d+)?$' THEN TRIM(t)::numeric END
$$;

CREATE OR REPLACE FUNCTION safe_ts(t text) RETURNS timestamp
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF TRIM(t) ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])' THEN
        RETURN LEFT(TRIM(t), 19)::timestamp;
    END IF;
    RETURN NULL;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- name: table_columns
SELECT table_name, ordinal_position, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name NOT LIKE 'clean\_%'
  AND table_name NOT LIKE 'pipeline\_%'
ORDER BY table_name, ordinal_position;

-- name: foreign_keys
SELECT tc.table_name, kcu.column_name,
       ccu.table_name AS references_table, ccu.column_name AS references_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
     ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
     ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
ORDER BY tc.table_name;

-- name: eda_summary
WITH long_vals AS (
    SELECT 'olist_order_items_dataset' AS table_name, 'price' AS column_name,
           safe_numeric(price::text) AS val FROM olist_order_items_dataset
    UNION ALL
    SELECT 'olist_order_items_dataset', 'freight_value',
           safe_numeric(freight_value::text) FROM olist_order_items_dataset
    UNION ALL
    SELECT 'olist_order_payments_dataset', 'payment_value',
           safe_numeric(payment_value::text) FROM olist_order_payments_dataset
    UNION ALL
    SELECT 'olist_order_payments_dataset', 'payment_installments',
           safe_numeric(payment_installments::text) FROM olist_order_payments_dataset
)
SELECT table_name, column_name,
       COUNT(*)                                        AS total_rows,
       COUNT(val)                                      AS non_null_count,
       MIN(val)                                        AS min_value,
       MAX(val)                                        AS max_value,
       ROUND(AVG(val), 2)                              AS avg_value,
       ROUND(STDDEV(val), 2)                           AS stddev_value,
       PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY val) AS median_value,
       PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY val) AS p99_value
FROM long_vals
GROUP BY table_name, column_name
ORDER BY table_name, column_name;

-- name: quality_audit
WITH checks AS (
    -- ---------- orders ----------
    SELECT 'olist_orders_dataset' AS table_name, 'order_id' AS column_name,
           'duplicate_keys' AS check_name,
           COUNT(*) - COUNT(DISTINCT order_id) AS defect_count, COUNT(*) AS total_rows
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_id', 'malformed_pattern',
           COUNT(*) FILTER (WHERE order_id::text !~ '^[a-f0-9]{32}$'), COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_status', 'null_or_empty',
           COUNT(*) FILTER (WHERE NULLIF(TRIM(order_status::text), '') IS NULL), COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_status', 'unknown_category',
           COUNT(*) FILTER (WHERE LOWER(TRIM(order_status::text)) NOT IN
               ('delivered','shipped','canceled','unavailable','invoiced','processing','created','approved')),
           COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_purchase_timestamp', 'unparseable_timestamp',
           COUNT(*) FILTER (WHERE safe_ts(order_purchase_timestamp::text) IS NULL), COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_delivered_customer_date', 'missing_but_status_delivered',
           COUNT(*) FILTER (WHERE LOWER(TRIM(order_status::text)) = 'delivered'
                             AND safe_ts(order_delivered_customer_date::text) IS NULL), COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_estimated_delivery_date', 'unparseable_timestamp',
           COUNT(*) FILTER (WHERE safe_ts(order_estimated_delivery_date::text) IS NULL), COUNT(*)
    FROM olist_orders_dataset
    UNION ALL
    SELECT 'olist_orders_dataset', 'order_delivered_customer_date', 'delivered_before_purchase',
           COUNT(*) FILTER (WHERE safe_ts(order_delivered_customer_date::text)
                                < safe_ts(order_purchase_timestamp::text)), COUNT(*)
    FROM olist_orders_dataset
    -- ---------- order items ----------
    UNION ALL
    SELECT 'olist_order_items_dataset', 'order_id+order_item_id', 'duplicate_keys',
           COUNT(*) - (SELECT COUNT(*) FROM (SELECT DISTINCT order_id, order_item_id
                                             FROM olist_order_items_dataset) d), COUNT(*)
    FROM olist_order_items_dataset
    UNION ALL
    SELECT 'olist_order_items_dataset', 'price', 'null_or_unparseable',
           COUNT(*) FILTER (WHERE safe_numeric(price::text) IS NULL), COUNT(*)
    FROM olist_order_items_dataset
    UNION ALL
    SELECT 'olist_order_items_dataset', 'price', 'non_positive',
           COUNT(*) FILTER (WHERE safe_numeric(price::text) <= 0), COUNT(*)
    FROM olist_order_items_dataset
    UNION ALL
    SELECT 'olist_order_items_dataset', 'price', 'outlier_above_p99',
           COUNT(*) FILTER (WHERE safe_numeric(price::text) > q.p99), COUNT(*)
    FROM olist_order_items_dataset,
         (SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY safe_numeric(price::text)) AS p99
          FROM olist_order_items_dataset) q
    UNION ALL
    SELECT 'olist_order_items_dataset', 'freight_value', 'null_or_unparseable',
           COUNT(*) FILTER (WHERE safe_numeric(freight_value::text) IS NULL), COUNT(*)
    FROM olist_order_items_dataset
    -- ---------- payments ----------
    UNION ALL
    SELECT 'olist_order_payments_dataset', 'payment_value', 'null_or_unparseable',
           COUNT(*) FILTER (WHERE safe_numeric(payment_value::text) IS NULL), COUNT(*)
    FROM olist_order_payments_dataset
    UNION ALL
    SELECT 'olist_order_payments_dataset', 'payment_value', 'negative',
           COUNT(*) FILTER (WHERE safe_numeric(payment_value::text) < 0), COUNT(*)
    FROM olist_order_payments_dataset
    -- ---------- customers / sellers ----------
    UNION ALL
    SELECT 'olist_customers_dataset', 'customer_id', 'duplicate_keys',
           COUNT(*) - COUNT(DISTINCT customer_id), COUNT(*)
    FROM olist_customers_dataset
    UNION ALL
    SELECT 'olist_customers_dataset', 'customer_state', 'malformed_pattern',
           COUNT(*) FILTER (WHERE customer_state::text !~ '^[A-Z]{2}$'), COUNT(*)
    FROM olist_customers_dataset
    UNION ALL
    SELECT 'olist_customers_dataset', 'customer_zip_code_prefix', 'malformed_pattern',
           COUNT(*) FILTER (WHERE customer_zip_code_prefix::text !~ '^\d{4,5}$'), COUNT(*)
    FROM olist_customers_dataset
    UNION ALL
    SELECT 'olist_sellers_dataset', 'seller_state', 'malformed_pattern',
           COUNT(*) FILTER (WHERE seller_state::text !~ '^[A-Z]{2}$'), COUNT(*)
    FROM olist_sellers_dataset
)
SELECT table_name, column_name, check_name, defect_count, total_rows,
       ROUND(100.0 * defect_count / NULLIF(total_rows, 0), 3) AS defect_pct
FROM checks
ORDER BY table_name, column_name, check_name;
