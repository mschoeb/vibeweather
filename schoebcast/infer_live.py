"""CLI entrypoint to generate live `klo.json` from MeteoSwiss OGD + SchoebcastGRU."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from core.live import (
    find_latest_complete_reftime,
    generate_klo_forecast_payload,
    read_existing_reftime,
)
from core.utils import MODELS_DIR, ROOT_DIR


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch live MeteoSwiss ICON-CH1-EPS + SMN data and run SchoebcastGRU."
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT_DIR / "data" / "live" / "klo.json",
        help="Output JSON file path (default: schoebcast/data/live/klo.json).",
    )
    parser.add_argument(
        "--check-existing",
        type=str,
        default=None,
        help="Optional local path or URL to an existing klo.json; exits early if reftime matches.",
    )
    parser.add_argument(
        "--reftime",
        type=str,
        default=None,
        help="Optional explicit ICON reference_datetime ISO string (e.g. 2026-11-15T12:00:00Z).",
    )
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=MODELS_DIR / "schoebcast_klo_gru.pt",
        help="Path to trained SchoebcastGRU checkpoint.",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=12,
        help="Parallel download workers for ICON-CH1-EPS GRIB2 slicing.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Run even if --check-existing already has the same reftime.",
    )
    args = parser.parse_args()

    latest_ref = args.reftime or find_latest_complete_reftime()
    if not args.force and args.check_existing:
        existing_ref = read_existing_reftime(args.check_existing)
        if existing_ref == latest_ref:
            print(f"Up to date: existing forecast already at reftime {latest_ref}. Skipping.")
            return 0

    payload = generate_klo_forecast_payload(
        reftime_iso=latest_ref,
        checkpoint_path=args.checkpoint,
        max_workers=args.workers,
        verbose=True,
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    size_kb = args.out.stat().st_size / 1024.0
    print(f"Wrote {args.out} ({size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
