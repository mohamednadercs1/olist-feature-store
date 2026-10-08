"""Phase 2 - Data Understanding: structural audit, SQL EDA, and quality verification."""
import logging

from psycopg2 import sql

import config
from scripts.phase1 import ensure_metadata_table, log_metadata

log = logging.getLogger("phase2")
QUERIES = config.load_named_queries("audit_queries.sql")


def install_helpers(conn):
    with conn.cursor() as cur:
        cur.execute(QUERIES["helpers"])


def structural_audit(conn):
    """Document columns, datatypes, FKs and baseline row counts for every raw table."""
    with conn.cursor() as cur:
        cur.execute(QUERIES["table_columns"])
        columns = cur.fetchall()
        cur.execute(QUERIES["foreign_keys"])
        fks = cur.fetchall()

        tables = sorted({c[0] for c in columns})
        for t in tables:
            cols = [f"{c[2]}:{c[3]}" for c in columns if c[0] == t]
            log.info("TABLE %s (%d cols): %s", t, len(cols), ", ".join(cols))
        for t, col, rt, rc in fks:
            log.info("FK %s.%s -> %s.%s", t, col, rt, rc)
        if not fks:
            log.info("No foreign keys declared (messy DB) - joins rely on *_id columns.")

        for t in tables:
            cur.execute(sql.SQL("SELECT COUNT(*) FROM {}").format(sql.Identifier(t)))
            n = cur.fetchone()[0]
            log.info("Baseline row count %s = %d", t, n)
            log_metadata(conn, "phase2", f"baseline_rows:{t}", n)


def run():
    log.info("=== PHASE 2: Data Understanding ===")
    with config.transaction() as conn:
        ensure_metadata_table(conn)
        install_helpers(conn)
        structural_audit(conn)

        n = config.export_query_to_csv(conn, QUERIES["eda_summary"], config.OUTPUT_DIR / "phase2_eda_summary.csv")
        log.info("Wrote outputs/phase2_eda_summary.csv (%d rows)", n)

        n = config.export_query_to_csv(conn, QUERIES["quality_audit"], config.OUTPUT_DIR / "phase2_quality_audit.csv")
        log.info("Wrote outputs/phase2_quality_audit.csv (%d rows)", n)
    log.info("Phase 2 complete.")
