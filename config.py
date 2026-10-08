"""Database configuration + tiny shared helpers (connection, SQL loading, CSV export).

Python is ONLY an orchestrator here: no Pandas/Polars anywhere in this project.
"""
import csv
import os
import re
from contextlib import contextmanager
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent
SQL_DIR = BASE_DIR / "sql"
OUTPUT_DIR = BASE_DIR / "outputs"
OUTPUT_DIR.mkdir(exist_ok=True)

DB_PARAMS = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": os.getenv("DB_PORT", "5432"),
    "dbname": os.getenv("DB_NAME", "olist_messy"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

# Raw Olist tables expected in the *_messy database (edit if yours differ).
RAW_TABLES = [
    "olist_orders_dataset",
    "olist_order_items_dataset",
    "olist_order_payments_dataset",
    "olist_customers_dataset",
    "olist_sellers_dataset",
]

TARGET_NAME = "is_late_delivery"
FEATURE_VIEW = "feature_store"


def get_connection():
    return psycopg2.connect(**DB_PARAMS)


@contextmanager
def transaction():
    """Open a connection; commit on success, rollback on any error."""
    conn = get_connection()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def read_sql_file(filename):
    return (SQL_DIR / filename).read_text(encoding="utf-8")


def load_named_queries(filename):
    """Split a .sql file into {name: query} using '-- name: xxx' marker lines."""
    text = read_sql_file(filename)
    parts = re.split(r"^-- name:\s*(\w+)\s*$", text, flags=re.MULTILINE)
    return {parts[i]: parts[i + 1].strip() for i in range(1, len(parts), 2)}


def export_query_to_csv(conn, query, out_path, batch=10000):
    """Stream a query's rows to CSV with the native csv module (server-side cursor)."""
    n = 0
    with conn.cursor(name="csv_export") as cur, open(out_path, "w", newline="", encoding="utf-8") as f:
        cur.itersize = batch
        cur.execute(query)
        writer = csv.writer(f)
        rows = cur.fetchmany(batch)
        writer.writerow([d[0] for d in cur.description])
        while rows:
            writer.writerows(rows)
            n += len(rows)
            rows = cur.fetchmany(batch)
    return n
