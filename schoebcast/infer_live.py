"""CLI entrypoint to generate live `klo.json` and rolling run history from MeteoSwiss OGD."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from core.live import (
    backfill_and_write_history,
    find_all_complete_reftimes,
    find_latest_complete_reftime,
    generate_klo_forecast_payload,
    read_existing_reftime,
    reftime_to_slug,
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
        help="Output JSON file path when not using --archive-dir.",
    )
    parser.add_argument(
        "--archive-dir",
        type=Path,
        default=None,
        help=(
            "Data directory to maintain klo.json, history.json, and runs/<slug>.json "
            "(backfills actual KLO observations across all archived runs)."
        ),
    )
    parser.add_argument(
        "--max-runs",
        type=int,
        default=56,
        help="Maximum rolling runs kept in --archive-dir/runs (default: 56 = 7 days).",
    )
    parser.add_argument(
        "--seed-missing",
        action="store_true",
        help="When using --archive-dir, generate any missing runs available in STAC (24h window).",
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
        help="Optional explicit ICON reference_datetime ISO string (e.g. 2026-11-21T12:00:00Z).",
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

    # Archive mode: maintain data/runs/<slug>.json, data/history.json, and data/klo.json
    if args.archive_dir is not None:
        all_refs = [args.reftime] if args.reftime else find_all_complete_reftimes()
        latest_ref = all_refs[-1]

        runs_dir = args.archive_dir / "runs"
        runs_dir.mkdir(parents=True, exist_ok=True)

        if args.seed_missing:
            target_refs = [
                r for r in all_refs if args.force or not (runs_dir / f"{reftime_to_slug(r)}.json").exists()
            ]
        else:
            existing_ref = read_existing_reftime(args.check_existing) if args.check_existing else None
            if not args.force and existing_ref == latest_ref and (runs_dir / f"{reftime_to_slug(latest_ref)}.json").exists():
                print(f"Up to date: existing forecast already at reftime {latest_ref}. Skipping.")
                return 0
            target_refs = [latest_ref]

        if not target_refs and not args.force:
            print(f"Up to date: all available runs through {latest_ref} already archived. Skipping.")
            return 0

        for ref in target_refs:
            payload = generate_klo_forecast_payload(
                reftime_iso=ref,
                checkpoint_path=args.checkpoint,
                max_workers=args.workers,
                verbose=True,
            )
            run_path = runs_dir / f"{reftime_to_slug(ref)}.json"
            run_path.write_text(
                json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )
            print(f"Archived {run_path} ({run_path.stat().st_size / 1024.0:.1f} KB)")

        backfill_and_write_history(args.archive_dir, max_runs=args.max_runs, verbose=True)
        return 0

    # Single-file mode
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
