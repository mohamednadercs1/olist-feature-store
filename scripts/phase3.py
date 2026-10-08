"""Phase 3 - Data Preparation: clean in SQL, build the Feature Store, export to CSV."""
import logging

from psycopg2 import sql

import config

log = logging.getLogger("phase3")


def run_sql_file(conn, filename):
    with conn.cursor() as cur:
        cur.execute(config.read_sql_file(filename))  # no params -> '%' and regex are safe


def volume_report(conn):
    """Compare raw vs cleaned volumes so join/filter effects are visible."""
    pairs = [
        ("olist_orders_dataset", "clean_orders"),
        ("olist_order_items_dataset", "clean_order_items"),
        ("olist_order_payments_dataset", "clean_payments"),
        ("olist_customers_dataset", "clean_customers"),
        ("olist_sellers_dataset", "clean_sellers"),
        (None, config.FEATURE_VIEW),
    ]
    with conn.cursor() as cur:
        for raw, clean in pairs:
            raw_n = None
            if raw:
                cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(raw)))
                raw_n = cur.fetchone()[0]
            cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(clean)))
            log.info("Volume %-24s raw=%s clean=%d", clean, raw_n, cur.fetchone()[0])


def validate_feature_store(conn):
    with conn.cursor() as cur:
        cur.execute(
            f"""SELECT COUNT(*),
                       COUNT(*) - COUNT(DISTINCT order_id),
                       COUNT(*) FILTER (WHERE {config.TARGET_NAME} IS NULL),
                       ROUND(100.0 * AVG({config.TARGET_NAME}), 2)
                FROM {config.FEATURE_VIEW}"""
        )
        total, dups, null_target, late_pct = cur.fetchone()
    log.info("Feature store rows=%d duplicates=%d null_targets=%d late_rate=%s%%",
             total, dups, null_target, late_pct)
    if dups or null_target:
        raise RuntimeError("Validation failed: duplicates or null targets in feature store.")


def export_feature_store(conn):
    out = config.OUTPUT_DIR / "feature_store_export.csv"
    n = config.export_query_to_csv(conn, f"SELECT * FROM {config.FEATURE_VIEW} ORDER BY purchase_ts, order_id", out)
    log.info("Wrote outputs/feature_store_export.csv (%d rows)", n)


def run():
    log.info("=== PHASE 3: Data Preparation ===")
    with config.transaction() as conn:
        log.info("Cleaning (dedupe, impute, cap outliers, cohort filter)...")
        run_sql_file(conn, "data_cleaning.sql")
        log.info("Building feature store materialized view...")
        run_sql_file(conn, "feature_store.sql")
        volume_report(conn)
        validate_feature_store(conn)
        export_feature_store(conn)
    log.info("Phase 3 complete.")
