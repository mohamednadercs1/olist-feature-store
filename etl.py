"""Master orchestrator: runs Phase 1 -> 2 -> 3 in strict order."""
import logging
import time

from scripts import phase1, phase2, phase3

log = logging.getLogger("etl")
PHASES = {1: phase1.run, 2: phase2.run, 3: phase3.run}


def run_pipeline(phases=(1, 2, 3)):
    for p in sorted(phases):
        start = time.perf_counter()
        PHASES[p]()
        log.info("Phase %d finished in %.2fs", p, time.perf_counter() - start)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    run_pipeline()
