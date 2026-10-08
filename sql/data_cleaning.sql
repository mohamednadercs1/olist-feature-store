-- =====================================================================
-- Phase 3a: cleaning. Dedupe (ROW_NUMBER), impute (COALESCE / median),
-- cohort filter, and 99th-percentile winsorization. Raw tables are never mutated.
-- =====================================================================

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

-- CASCADE also drops the dependent feature_store materialized view.
DROP TABLE IF EXISTS clean_orders CASCADE;
DROP TABLE IF EXISTS clean_order_items CASCADE;
DROP TABLE IF EXISTS clean_payments CASCADE;
DROP TABLE IF EXISTS clean_customers CASCADE;
DROP TABLE IF EXISTS clean_sellers CASCADE;

-- ---------------------------------------------------------------------
-- Orders: dedupe + cohort (delivered orders with valid, ordered timestamps) + TARGET
-- ---------------------------------------------------------------------
CREATE TABLE clean_orders AS
WITH parsed AS (
    SELECT NULLIF(TRIM(order_id::text), '')          AS order_id,
           NULLIF(TRIM(customer_id::text), '')       AS customer_id,
           LOWER(NULLIF(TRIM(order_status::text), '')) AS order_status,
           safe_ts(order_purchase_timestamp::text)      AS purchase_ts,
           safe_ts(order_approved_at::text)             AS approved_ts,
           safe_ts(order_delivered_carrier_date::text)  AS carrier_ts,
           safe_ts(order_delivered_customer_date::text) AS delivered_ts,
           safe_ts(order_estimated_delivery_date::text) AS estimated_ts
    FROM olist_orders_dataset
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY order_id
               ORDER BY (delivered_ts IS NOT NULL) DESC, purchase_ts DESC NULLS LAST
           ) AS rn
    FROM parsed
    WHERE order_id ~ '^[a-f0-9]{32}$'
)
SELECT order_id, customer_id, order_status, purchase_ts,
       COALESCE(approved_ts, purchase_ts) AS approved_ts,   -- imputation
       carrier_ts, delivered_ts, estimated_ts,
       (delivered_ts > estimated_ts)::int AS is_late_delivery  -- TARGET
FROM ranked
WHERE rn = 1
  AND order_status = 'delivered'
  AND purchase_ts IS NOT NULL
  AND delivered_ts IS NOT NULL
  AND estimated_ts IS NOT NULL
  AND delivered_ts >= purchase_ts
  AND customer_id IS NOT NULL;

ALTER TABLE clean_orders ADD PRIMARY KEY (order_id);

-- ---------------------------------------------------------------------
-- Order items: dedupe, impute with medians, winsorize at p99
-- ---------------------------------------------------------------------
CREATE TABLE clean_order_items AS
WITH parsed AS (
    SELECT NULLIF(TRIM(order_id::text), '')   AS order_id,
           safe_numeric(order_item_id::text)::int AS order_item_id,
           NULLIF(TRIM(product_id::text), '') AS product_id,
           NULLIF(TRIM(seller_id::text), '')  AS seller_id,
           safe_numeric(price::text)          AS price,
           safe_numeric(freight_value::text)  AS freight_value
    FROM olist_order_items_dataset
),
dedup AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY order_id, order_item_id
                              ORDER BY price DESC NULLS LAST) AS rn
    FROM parsed
    WHERE order_id IS NOT NULL AND seller_id IS NOT NULL AND order_item_id IS NOT NULL
),
stats AS (
    SELECT PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY price)         FILTER (WHERE price > 0)          AS price_med,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY price)         FILTER (WHERE price > 0)          AS price_p99,
           PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY freight_value) FILTER (WHERE freight_value >= 0) AS freight_med,
           PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY freight_value) FILTER (WHERE freight_value >= 0) AS freight_p99
    FROM dedup WHERE rn = 1
)
SELECT d.order_id, d.order_item_id, d.product_id, d.seller_id,
       LEAST(COALESCE(CASE WHEN d.price > 0 THEN d.price END, s.price_med), s.price_p99)               AS price,
       LEAST(COALESCE(CASE WHEN d.freight_value >= 0 THEN d.freight_value END, s.freight_med), s.freight_p99) AS freight_value,
       (d.price > s.price_p99) AS price_was_capped
FROM dedup d CROSS JOIN stats s
WHERE d.rn = 1;

CREATE INDEX idx_clean_items_order ON clean_order_items (order_id);

-- ---------------------------------------------------------------------
-- Payments: dedupe, standardise type, impute installments, winsorize value
-- ---------------------------------------------------------------------
CREATE TABLE clean_payments AS
WITH parsed AS (
    SELECT NULLIF(TRIM(order_id::text), '') AS order_id,
           safe_numeric(payment_sequential::text)::int AS payment_sequential,
           COALESCE(LOWER(NULLIF(TRIM(payment_type::text), '')), 'unknown') AS payment_type,
           GREATEST(COALESCE(safe_numeric(payment_installments::text)::int, 1), 1) AS payment_installments,
           safe_numeric(payment_value::text) AS payment_value
    FROM olist_order_payments_dataset
),
dedup AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY order_id, payment_sequential
                                 ORDER BY payment_value DESC NULLS LAST) AS rn
    FROM parsed
    WHERE order_id IS NOT NULL AND payment_value >= 0
),
stats AS (
    SELECT PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY payment_value) AS p99 FROM dedup WHERE rn = 1
)
SELECT d.order_id, d.payment_sequential, d.payment_type, d.payment_installments,
       LEAST(d.payment_value, s.p99) AS payment_value
FROM dedup d CROSS JOIN stats s
WHERE d.rn = 1;

CREATE INDEX idx_clean_pay_order ON clean_payments (order_id);

-- ---------------------------------------------------------------------
-- Customers & sellers: dedupe + standardise state codes (impute 'UNK')
-- ---------------------------------------------------------------------
CREATE TABLE clean_customers AS
SELECT customer_id, customer_unique_id, customer_state
FROM (
    SELECT NULLIF(TRIM(customer_id::text), '')        AS customer_id,
           NULLIF(TRIM(customer_unique_id::text), '') AS customer_unique_id,
           CASE WHEN UPPER(TRIM(customer_state::text)) ~ '^[A-Z]{2}$'
                THEN UPPER(TRIM(customer_state::text)) ELSE 'UNK' END AS customer_state,
           ROW_NUMBER() OVER (PARTITION BY NULLIF(TRIM(customer_id::text), '')
                              ORDER BY customer_unique_id) AS rn
    FROM olist_customers_dataset
) t
WHERE rn = 1 AND customer_id IS NOT NULL AND customer_unique_id IS NOT NULL;

ALTER TABLE clean_customers ADD PRIMARY KEY (customer_id);

CREATE TABLE clean_sellers AS
SELECT seller_id, seller_state
FROM (
    SELECT NULLIF(TRIM(seller_id::text), '') AS seller_id,
           CASE WHEN UPPER(TRIM(seller_state::text)) ~ '^[A-Z]{2}$'
                THEN UPPER(TRIM(seller_state::text)) ELSE 'UNK' END AS seller_state,
           ROW_NUMBER() OVER (PARTITION BY NULLIF(TRIM(seller_id::text), '') ORDER BY seller_state) AS rn
    FROM olist_sellers_dataset
) t
WHERE rn = 1 AND seller_id IS NOT NULL;

ALTER TABLE clean_sellers ADD PRIMARY KEY (seller_id);
