"""Operational MeteoSwiss OGD fetcher and live SchoebcastGRU inference for KLO."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import io
import json
from pathlib import Path
import threading
import time
from typing import Any, Optional

import eccodes
import numpy as np
import pandas as pd
import requests
from requests.adapters import HTTPAdapter
import torch
from urllib3.util.retry import Retry

from .data import _build_time_features
from .model import load_checkpoint
from .utils import HORIZON_SIZE, MODELS_DIR, STATION, WINDOW_SIZE

STAC_SEARCH_URL = "https://data.geo.admin.ch/api/stac/v1/search"
ICON_COLLECTION = "ch.meteoschweiz.ogd-forecasting-icon-ch1"

SMN_NOW_URL = "https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/klo/ogd-smn_klo_t_now.csv"
SMN_RECENT_URL = "https://data.geo.admin.ch/ch.meteoschweiz.ogd-smn/klo/ogd-smn_klo_t_recent.csv"

# Precomputed nearest ICON-CH1-EPS cell to Zurich Kloten (KLO: 47.479611, 8.535961, 426.3m)
# Cell center: lat=47.47910, lon=8.53295, h=425.7m (distance=233.4m) out of 1,147,980 cells.
ICON_NUM_CELLS = 1_147_980
KLO_ICON_CELL_IDX = 791_189

KLO_META = {
    "code": "KLO",
    "name": "Zürich / Kloten",
    "latitude": 47.479611,
    "longitude": 8.535961,
    "elevation_m": 426.3,
    "icon_cell_idx": KLO_ICON_CELL_IDX,
    "icon_cell_elevation_m": 425.7,
}

ICON_VARIABLES = ("T_2M", "U_10M", "V_10M")
_ECCODES_LOCK = threading.Lock()


def _make_session(pool_maxsize: int = 16) -> requests.Session:
    """Create an HTTP session with automatic retries and connection pooling."""
    session = requests.Session()
    retry = Retry(
        total=4,
        backoff_factor=0.6,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=("GET", "POST"),
    )
    adapter = HTTPAdapter(
        pool_connections=pool_maxsize,
        pool_maxsize=pool_maxsize,
        max_retries=retry,
    )
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def _lead_to_iso_horizon(lead_hours: int) -> str:
    """Format integer lead hour (1..33) as MeteoSwiss STAC ISO-8601 duration."""
    days, hours = divmod(lead_hours, 24)
    return f"P{days}DT{hours:02d}H00M00S"


def _iso_horizon_to_lead(horizon_str: str) -> int:
    """Parse 'P0DT03H00M00S' or 'P1DT09H00M00S' into integer hours."""
    td = pd.Timedelta(horizon_str)
    return int(round(td.total_seconds() / 3600.0))


def find_latest_complete_reftime(
    session: Optional[requests.Session] = None,
    horizon_size: int = HORIZON_SIZE,
) -> str:
    """Return the latest ICON-CH1-EPS reference_datetime (ISO UTC) where all variables
    have both control and perturbed GRIB2 assets published through +`horizon_size`h."""
    own_session = session is None
    session = session or _make_session(pool_maxsize=4)
    try:
        last_horizon = _lead_to_iso_horizon(horizon_size)
        complete_per_var: list[set[str]] = []

        for var in ICON_VARIABLES:
            resp = session.post(
                STAC_SEARCH_URL,
                json={
                    "collections": [ICON_COLLECTION],
                    "forecast:variable": var,
                    "forecast:horizon": last_horizon,
                    "limit": 100,
                },
                timeout=20,
            )
            resp.raise_for_status()
            features = resp.json().get("features", [])

            # Group by reference_datetime and require both perturbed=False and perturbed=True
            seen: dict[str, set[bool]] = {}
            for feat in features:
                props = feat["properties"]
                ref = props["forecast:reference_datetime"]
                pert = bool(props["forecast:perturbed"])
                seen.setdefault(ref, set()).add(pert)

            complete_refs = {ref for ref, flags in seen.items() if flags == {False, True}}
            complete_per_var.append(complete_refs)

        common_refs = sorted(set.intersection(*complete_per_var))
        if not common_refs:
            raise RuntimeError("No complete ICON-CH1-EPS runs found on MeteoSwiss STAC.")
        return common_refs[-1]
    finally:
        if own_session:
            session.close()


def read_existing_reftime(path_or_url: Optional[str]) -> Optional[str]:
    """Read `reftime` from an existing local JSON file or HTTP URL, or return None."""
    if not path_or_url:
        return None
    try:
        if path_or_url.startswith(("http://", "https://")):
            resp = requests.get(path_or_url, timeout=10)
            if not resp.ok:
                return None
            return resp.json().get("reftime")
        p = Path(path_or_url)
        if not p.exists():
            return None
        return json.loads(p.read_text(encoding="utf-8")).get("reftime")
    except Exception:
        return None


def fetch_klo_obs_window(
    reftime_iso: str,
    window_size: int = WINDOW_SIZE,
    session: Optional[requests.Session] = None,
) -> dict[str, Any]:
    """Fetch 10-min KLO SwissMetNet CSVs and aggregate the 24h hourly window ending at `reftime`.

    Matches PeakWeatherDataset preprocessing 1:1:
      - `tre200s0` (°C), `fkl010z0` (m/s), `dkl010z0` (deg)
      - 10-min `u = -speed * sin(dir_rad)`, `v = -speed * cos(dir_rad)`
      - Hourly resample with `closed="right", label="right"` mean + LOCF imputation.
    """
    own_session = session is None
    session = session or _make_session(pool_maxsize=4)
    try:
        reftime = pd.Timestamp(reftime_iso).tz_convert("UTC")
        start_needed = reftime - pd.Timedelta(hours=window_size + 2)

        r_now = session.get(SMN_NOW_URL, timeout=20)
        r_now.raise_for_status()
        df_now = pd.read_csv(io.StringIO(r_now.text), sep=";")

        dfs = [df_now]
        first_now_ts = pd.to_datetime(
            df_now["reference_timestamp"].iloc[0], format="%d.%m.%Y %H:%M", utc=True
        )
        if first_now_ts > start_needed:
            r_rec = session.get(SMN_RECENT_URL, timeout=30)
            r_rec.raise_for_status()
            df_rec = pd.read_csv(io.StringIO(r_rec.text), sep=";")
            dfs.insert(0, df_rec)

        df = pd.concat(dfs, ignore_index=True)
        df["ts"] = pd.to_datetime(df["reference_timestamp"], format="%d.%m.%Y %H:%M", utc=True)
        df = df.drop_duplicates(subset=["ts"], keep="last").sort_values("ts").set_index("ts")

        # Keep recent slice around window so resampling is fast
        df = df.loc[start_needed - pd.Timedelta(hours=6) : reftime]

        temp = pd.to_numeric(df["tre200s0"], errors="coerce")
        wspd = pd.to_numeric(df["fkl010z0"], errors="coerce")
        wdir = pd.to_numeric(df["dkl010z0"], errors="coerce")

        wdir_rad = np.deg2rad(wdir)
        wind_u = -wspd * np.sin(wdir_rad)
        wind_v = -wspd * np.cos(wdir_rad)

        ten_min = pd.DataFrame(
            {"temperature": temp, "wind_u": wind_u, "wind_v": wind_v, "wind_speed": wspd},
            index=df.index,
        )
        hourly = ten_min.resample("1h", closed="right", label="right").mean().ffill().bfill()

        target_index = pd.date_range(end=reftime, periods=window_size, freq="1h", tz="UTC")
        hourly = hourly.reindex(target_index).ffill().bfill()

        if hourly[["temperature", "wind_u", "wind_v"]].isna().any().any():
            raise RuntimeError(f"Missing KLO observations in 24h window ending {reftime_iso}")

        x_obs = hourly[["temperature", "wind_u", "wind_v"]].to_numpy(dtype=np.float32)

        # Derive meteorological direction from hourly mean (u, v)
        u_arr = hourly["wind_u"].to_numpy(dtype=np.float32)
        v_arr = hourly["wind_v"].to_numpy(dtype=np.float32)
        wdir_hourly = (np.rad2deg(np.arctan2(-u_arr, -v_arr)) + 360.0) % 360.0
        wspd_vec = np.hypot(u_arr, v_arr)

        return {
            "timestamps": [ts.strftime("%Y-%m-%dT%H:%M:%SZ") for ts in target_index],
            "x_obs": x_obs,  # (24, 3): [temperature, wind_u, wind_v]
            "wind_speed_ms": wspd_vec,
            "wind_dir_deg": wdir_hourly,
        }
    finally:
        if own_session:
            session.close()


def _extract_cell_from_grib_bytes(raw: bytes, cell_idx: int = KLO_ICON_CELL_IDX) -> list[float]:
    """Extract `cell_idx` across all GRIB2 messages in `raw` directly in RAM."""
    out: list[float] = []
    mv = memoryview(raw)
    pos = 0
    n = len(raw)

    while pos < n:
        ig = raw.find(b"GRIB", pos)
        if ig < 0:
            break
        msg_len = int.from_bytes(raw[ig + 8 : ig + 16], "big")
        gid = eccodes.codes_new_from_message(bytes(mv[ig : ig + msg_len]))
        try:
            vals = eccodes.codes_get_values(gid)
            if len(vals) != ICON_NUM_CELLS:
                raise RuntimeError(
                    f"Unexpected ICON grid size {len(vals)} (expected {ICON_NUM_CELLS})"
                )
            out.append(float(vals[cell_idx]))
        finally:
            eccodes.codes_release(gid)
        pos = ig + msg_len

    return out


def fetch_klo_icon_horizon(
    reftime_iso: str,
    horizon_size: int = HORIZON_SIZE,
    max_workers: int = 12,
    session: Optional[requests.Session] = None,
) -> np.ndarray:
    """Download and slice 11-member ICON-CH1-EPS forecasts for KLO over `+1h..+33h`.

    Returns:
        Float32 array of shape `(H, 11, 3)` ordered as `[temperature (°C), wind_u (m/s), wind_v (m/s)]`.
        Member 0 is control (`perturbed=False`), members 1..10 are perturbed (`perturbed=True`).
    """
    own_session = session is None
    session = session or _make_session(pool_maxsize=max(16, max_workers + 4))
    try:
        tasks: list[tuple[int, int, bool, str]] = []  # (var_idx, lead_idx, is_perturbed, href)

        for var_idx, var in enumerate(ICON_VARIABLES):
            resp = session.post(
                STAC_SEARCH_URL,
                json={
                    "collections": [ICON_COLLECTION],
                    "forecast:reference_datetime": reftime_iso,
                    "forecast:variable": var,
                    "limit": 100,
                },
                timeout=20,
            )
            resp.raise_for_status()
            features = resp.json().get("features", [])

            found_slots: set[tuple[int, bool]] = set()
            for feat in features:
                props = feat["properties"]
                lead_h = _iso_horizon_to_lead(props["forecast:horizon"])
                if not (1 <= lead_h <= horizon_size):
                    continue
                is_pert = bool(props["forecast:perturbed"])
                href = next(iter(feat["assets"].values()))["href"]
                tasks.append((var_idx, lead_h - 1, is_pert, href))
                found_slots.add((lead_h, is_pert))

            expected_slots = {(h, p) for h in range(1, horizon_size + 1) for p in (False, True)}
            missing = expected_slots - found_slots
            if missing:
                raise RuntimeError(
                    f"ICON variable {var} at {reftime_iso} missing {len(missing)} assets: {sorted(missing)[:5]}"
                )

        nwp_members = np.empty((horizon_size, 11, len(ICON_VARIABLES)), dtype=np.float32)

        def _download_and_slice(task: tuple[int, int, bool, str]) -> tuple[int, int, bool, list[float]]:
            var_idx, lead_idx, is_pert, href = task
            r = session.get(href, timeout=60)
            r.raise_for_status()
            raw = r.content
            with _ECCODES_LOCK:
                vals = _extract_cell_from_grib_bytes(raw, cell_idx=KLO_ICON_CELL_IDX)
            expected_len = 10 if is_pert else 1
            if len(vals) != expected_len:
                raise RuntimeError(
                    f"Expected {expected_len} realizations in {href}, got {len(vals)}"
                )
            return var_idx, lead_idx, is_pert, vals

        with ThreadPoolExecutor(max_workers=max_workers) as pool:
            futures = [pool.submit(_download_and_slice, t) for t in tasks]
            for fut in as_completed(futures):
                var_idx, lead_idx, is_pert, vals = fut.result()
                if is_pert:
                    nwp_members[lead_idx, 1:11, var_idx] = vals
                else:
                    nwp_members[lead_idx, 0, var_idx] = vals[0]

        # Convert T_2M from Kelvin to Celsius
        nwp_members[:, :, 0] -= 273.15
        return nwp_members
    finally:
        if own_session:
            session.close()


@torch.no_grad()
def generate_klo_forecast_payload(
    reftime_iso: Optional[str] = None,
    checkpoint_path: Path | str = MODELS_DIR / "schoebcast_klo_gru.pt",
    max_workers: int = 12,
    verbose: bool = True,
) -> dict[str, Any]:
    """Run the full live pipeline (STAC -> SMN + ICON -> SchoebcastGRU) and return JSON dict."""
    t0 = time.perf_counter()
    session = _make_session(pool_maxsize=max(16, max_workers + 4))
    try:
        if reftime_iso is None:
            reftime_iso = find_latest_complete_reftime(session=session)
        if verbose:
            print(f"[1/4] Latest complete ICON-CH1-EPS run: {reftime_iso}")

        obs_bundle = fetch_klo_obs_window(reftime_iso, session=session)
        if verbose:
            t_last = obs_bundle["x_obs"][-1, 0]
            print(f"[2/4] Loaded 24h KLO observations up to {reftime_iso} (t=0 temp: {t_last:.2f} °C)")

        t_dl = time.perf_counter()
        nwp_members = fetch_klo_icon_horizon(
            reftime_iso, max_workers=max_workers, session=session
        )  # (33, 11, 3)
        if verbose:
            print(
                f"[3/4] Sliced 11-member ICON-CH1-EPS (T_2M, U_10M, V_10M x 33h) "
                f"in {time.perf_counter() - t_dl:.1f}s"
            )

        net, scaler = load_checkpoint(checkpoint_path, device="cpu")

        reftime_ts = pd.Timestamp(reftime_iso).tz_convert("UTC")
        lead_index = pd.date_range(
            start=reftime_ts + pd.Timedelta(hours=1),
            periods=HORIZON_SIZE,
            freq="1h",
            tz="UTC",
        )
        index_y = lead_index.tz_convert("UTC").tz_localize(None).to_numpy()[None, :]  # (1, 33)

        x_obs_raw = obs_bundle["x_obs"][None, :, :]  # (1, 24, 3)
        nwp_mean = nwp_members.mean(axis=1)[None, :, :]  # (1, 33, 3)
        nwp_std = nwp_members.std(axis=1)[None, :, :]  # (1, 33, 3)
        time_feat = _build_time_features(index_y)  # (1, 33, 5)

        x_obs_scaled = scaler.transform_obs(x_obs_raw)
        nwp_scaled = scaler.transform_nwp(np.concatenate([nwp_mean, nwp_std], axis=-1))
        x_nwp = np.concatenate([nwp_scaled, time_feat], axis=-1)
        icon_temp_mean = nwp_mean[:, :, 0]  # (1, 33)

        pred_temp = (
            net(
                torch.from_numpy(x_obs_scaled),
                torch.from_numpy(x_nwp),
                torch.from_numpy(icon_temp_mean),
            )
            .squeeze(0)
            .cpu()
            .numpy()
        )  # (33,)

        temp_members = nwp_members[:, :, 0]  # (33, 11)
        u_members = nwp_members[:, :, 1]  # (33, 11)
        v_members = nwp_members[:, :, 2]  # (33, 11)
        wspd_members = np.hypot(u_members, v_members)  # (33, 11)

        u_mean = u_members.mean(axis=1)
        v_mean = v_members.mean(axis=1)
        wdir_mean = (np.rad2deg(np.arctan2(-u_mean, -v_mean)) + 360.0) % 360.0

        def _r(arr: np.ndarray, decimals: int = 2) -> list:
            return np.round(arr.astype(np.float64), decimals).tolist()

        payload = {
            "schema_version": 1,
            "station": KLO_META,
            "model": "schoebcast_klo_gru_v1",
            "reftime": reftime_ts.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "attribution": "Source: MeteoSwiss",
            "lookback_hourly": {
                "timestamps": obs_bundle["timestamps"],
                "temperature_c": _r(obs_bundle["x_obs"][:, 0], 2),
                "wind_speed_ms": _r(obs_bundle["wind_speed_ms"], 2),
                "wind_dir_deg": _r(obs_bundle["wind_dir_deg"], 1),
            },
            "forecast_hourly": {
                "timestamps": [ts.strftime("%Y-%m-%dT%H:%M:%SZ") for ts in lead_index],
                "schoebcast_temp_c": _r(pred_temp, 2),
                "icon_temp_mean_c": _r(temp_members.mean(axis=1), 2),
                "icon_temp_std_c": _r(temp_members.std(axis=1), 2),
                "icon_temp_min_c": _r(temp_members.min(axis=1), 2),
                "icon_temp_max_c": _r(temp_members.max(axis=1), 2),
                "icon_temp_p10_c": _r(np.percentile(temp_members, 10, axis=1), 2),
                "icon_temp_p90_c": _r(np.percentile(temp_members, 90, axis=1), 2),
                "icon_temp_members_c": _r(temp_members, 2),
                "icon_wind_speed_mean_ms": _r(wspd_members.mean(axis=1), 2),
                "icon_wind_speed_min_ms": _r(wspd_members.min(axis=1), 2),
                "icon_wind_speed_max_ms": _r(wspd_members.max(axis=1), 2),
                "icon_wind_dir_deg": _r(wdir_mean, 1),
            },
        }

        if verbose:
            dt = time.perf_counter() - t0
            mean_delta = float(np.mean(pred_temp - icon_temp_mean[0]))
            print(
                f"[4/4] SchoebcastGRU inference complete in {dt:.1f}s total "
                f"(mean ΔT vs ICON: {mean_delta:+.2f} °C)"
            )
        return payload
    finally:
        session.close()
