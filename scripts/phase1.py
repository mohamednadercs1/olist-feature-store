"""Phase 1 - Business Understanding: objectives, resource audit, target, ROI metrics."""
import logging

import config

log = logging.getLogger("phase1")

OBJECTIVES = {
    "business_goal": "Reduce late deliveries and improve customer satisfaction in Olist e-commerce logistics.",
    "ml_objective": "Predict, at order-placement time, whether an order will arrive after its estimated date.",
    "data_objective": "Build a leak-aware, deduplicated, outlier-capped Feature Store entirely in PostgreSQL.",
}

TARGET_DEFINITION = (
    "is_late_delivery = 1 if order_delivered_customer_date > order_estimated_delivery_date, else 0 "
    "(cohort: delivered orders with valid timestamps)"
)

ROI_METRICS = {
    "duplicate_records": "0% duplicate order_ids in feature_store",
    "clean_throughput": "100% of feature_store rows have a non-null target and valid timestamps",
    "processing_location": "100% of transformations executed inside PostgreSQL (no Pandas/Polars)",
    "reproducibility": "Full pipeline re-runs from scratch with one command (python main.py --all)",
    "latency": "End-to-end pipeline runtime logged per phase",
}

PIPELINE_SCHEDULE = [
    "Phase 1: define objectives, target, metrics",
    "Phase 2: structural audit, EDA summary CSV, quality audit CSV",
    "Phase 3: clean_* tables -> feature_store materialized view -> CSV export",
]


def ensure_metadata_table(conn):
    with conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS pipeline_metadata (
                   id SERIAL PRIMARY KEY, phase TEXT, key TEXT, value TEXT,
                   logged_at TIMESTAMP DEFAULT NOW())"""
        )


def log_metadata(conn, phase, key, value):
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO pipeline_metadata (phase, key, value) VALUES (%s, %s, %s)",
            (phase, key, str(value)),
        )


def resource_audit(conn):
    """Check that the expected raw tables exist and report their constraints."""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_schema = 'public' AND table_type = 'BASE TABLE'"
        )
        existing = {r[0] for r in cur.fetchall()}
        missing = [t for t in config.RAW_TABLES if t not in existing]
        cur.execute(
            "SELECT table_name, constraint_type, COUNT(*) FROM information_schema.table_constraints "
            "WHERE table_schema = 'public' GROUP BY 1, 2 ORDER BY 1, 2"
        )
        constraints = cur.fetchall()
    return existing, missing, constraints


def run():
    log.info("=== PHASE 1: Business Understanding ===")
    with config.transaction() as conn:
        ensure_metadata_table(conn)
        for k, v in OBJECTIVES.items():
            log.info("%s: %s", k, v)
            log_metadata(conn, "phase1", k, v)
        log.info("Target: %s", TARGET_DEFINITION)
        log_metadata(conn, "phase1", "target", TARGET_DEFINITION)
        for k, v in ROI_METRICS.items():
            log.info("ROI %s: %s", k, v)
            log_metadata(conn, "phase1", f"roi_{k}", v)
        for step in PIPELINE_SCHEDULE:
            log.info("Schedule: %s", step)

        existing, missing, constraints = resource_audit(conn)
        log.info("Tables found: %d", len(existing))
        for t, ctype, n in constraints:
            log.info("Constraint: %s | %s x%d", t, ctype, n)
        if missing:
            raise RuntimeError(f"Missing expected raw tables: {missing}. Edit RAW_TABLES in config.py.")
        log_metadata(conn, "phase1", "resource_audit", "all expected raw tables present")
    log.info("Phase 1 complete.")
