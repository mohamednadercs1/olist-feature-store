"""CLI entry point.

Usage:
    python main.py --phase 2
    python main.py --all
    python main.py            (interactive menu)
"""
import argparse
import logging
import sys

import etl

MENU = """
=== DEPI SQL Capstone: Olist Feature Store ===
 1) Phase 1 - Business Understanding
 2) Phase 2 - Data Understanding
 3) Phase 3 - Data Preparation
 A) Run full pipeline
 Q) Quit
"""


def interactive():
    while True:
        print(MENU)
        choice = input("Select: ").strip().upper()
        if choice == "Q":
            return
        try:
            if choice == "A":
                etl.run_pipeline()
            elif choice in {"1", "2", "3"}:
                etl.run_pipeline([int(choice)])
            else:
                print("Invalid choice.")
        except Exception as exc:  # keep the menu alive on failure
            print(f"ERROR: {exc}")


def main():
    parser = argparse.ArgumentParser(description="PostgreSQL Feature Store pipeline (Olist)")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--phase", type=int, choices=[1, 2, 3], help="run a single CRISP-DM phase")
    group.add_argument("--all", action="store_true", help="run phases 1-3 in order")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.all:
        etl.run_pipeline()
    elif args.phase:
        etl.run_pipeline([args.phase])
    else:
        interactive()


if __name__ == "__main__":
    sys.exit(main())
