"""PeakWeather loading for KLO, blocked seasonal splitting, scaling, and PyTorch DataLoaders."""

from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import numpy as np
import pandas as pd
import torch
from torch.utils.data import DataLoader, Dataset

from .utils import DATA_DIR, FEATURES, HORIZON_SIZE, STATION, TARGET, WINDOW_SIZE


def _build_time_features(index_y: np.ndarray) -> np.ndarray:
    """Build cyclical hour-of-day, day-of-year, and normalized lead-time features.

    Args:
        index_y: Timestamp array of shape (N, H) in UTC.

    Returns:
        Float32 array of shape (N, H, 5): [hour_sin, hour_cos, doy_sin, doy_cos, lead_norm].
    """
    N, H = index_y.shape
    flat_ts = pd.DatetimeIndex(index_y.reshape(-1))

    hours = flat_ts.hour.to_numpy(dtype=np.float32)
    doy = flat_ts.dayofyear.to_numpy(dtype=np.float32)

    hour_rad = 2.0 * np.pi * hours / 24.0
    doy_rad = 2.0 * np.pi * doy / 365.25

    hour_sin = np.sin(hour_rad).reshape(N, H)
    hour_cos = np.cos(hour_rad).reshape(N, H)
    doy_sin = np.sin(doy_rad).reshape(N, H)
    doy_cos = np.cos(doy_rad).reshape(N, H)

    lead_norm = np.broadcast_to(
        np.linspace(1.0 / H, 1.0, H, dtype=np.float32)[None, :], (N, H)
    )

    return np.stack([hour_sin, hour_cos, doy_sin, doy_cos, lead_norm], axis=-1).astype(
        np.float32
    )


def load_klo_data(
    data_dir: Path | str = DATA_DIR,
    station: str = STATION,
    window_size: int = WINDOW_SIZE,
    horizon_size: int = HORIZON_SIZE,
    features: Sequence[str] = FEATURES,
    target: str = TARGET,
    years: Sequence[int] = (2024, 2025),
) -> dict:
    """Load KLO observations aligned with ICON-CH1-EPS forecasts directly via PeakWeather."""
    from peakweather import PeakWeatherDataset

    features = list(features)
    raw_obs_params = [p for p in features if p not in ("wind_u", "wind_v")]
    need_uv = "wind_u" in features or "wind_v" in features
    if need_uv:
        raw_obs_params.extend(["wind_speed", "wind_direction"])

    pw = PeakWeatherDataset(
        root=str(data_dir),
        years=list(years),
        parameters=raw_obs_params,
        extended_nwp_pars=features,
        freq="h",
        compute_uv=need_uv,
        imputation_method="locf",
        aggregation_methods={"temperature": "mean", "wind_gust": "max"},
    )

    win = pw.get_windows(
        window_size=window_size,
        horizon_size=horizon_size,
        stations=[station],
        parameters=features,
        nwp_parameters=features,
        drop_extra_y_pars=False,
        as_xarray=True,
    )

    reftime = pd.DatetimeIndex(win.x["reftime"].values, tz="UTC")

    # Observation lookback: (N, W, F)
    x_obs = np.stack(
        [win.x[f].sel(nat_abbr=station).transpose("reftime", "lag").values for f in features],
        axis=-1,
    ).astype(np.float32)
    mask_x = np.stack(
        [
            win.mask_x[f].sel(nat_abbr=station).transpose("reftime", "lag").values
            for f in features
        ],
        axis=-1,
    ).astype(bool)

    # ICON ensemble members: (N, H, R, F)
    nwp_members = np.stack(
        [
            win.nwp[f]
            .sel(nat_abbr=station)
            .transpose("reftime", "lead", "realization")
            .values
            for f in features
        ],
        axis=-1,
    ).astype(np.float32)

    # Drop any forecast runs where ICON itself has missing realizations across the horizon
    valid_runs = np.isfinite(nwp_members).all(axis=(1, 2, 3)) & np.isfinite(x_obs).all(
        axis=(1, 2)
    )

    reftime = reftime[valid_runs]
    index_y = win.index_y[valid_runs]
    x_obs = x_obs[valid_runs]
    mask_x = mask_x[valid_runs]
    nwp_members = nwp_members[valid_runs]

    nwp_mean = nwp_members.mean(axis=2)  # (N, H, F)
    nwp_std = nwp_members.std(axis=2)  # (N, H, F)
    time_feat = _build_time_features(index_y)  # (N, H, 5)

    target_idx = features.index(target)
    icon_temp_members = nwp_members[:, :, :, target_idx]  # (N, H, 11)
    icon_temp_mean = nwp_mean[:, :, target_idx]  # (N, H)

    y_temp = (
        win.y[target]
        .sel(nat_abbr=station)
        .transpose("reftime", "lead")
        .values[valid_runs]
        .astype(np.float32)
    )
    mask_y = (
        win.mask_y[target]
        .sel(nat_abbr=station)
        .transpose("reftime", "lead")
        .values[valid_runs]
        .astype(bool)
    )

    return {
        "station": station,
        "features": features,
        "target": target,
        "reftime": reftime,
        "index_y": index_y,
        "x_obs": x_obs,
        "mask_x": mask_x,
        "nwp_mean": nwp_mean,
        "nwp_std": nwp_std,
        "time_feat": time_feat,
        "icon_temp_members": icon_temp_members,
        "icon_temp_mean": icon_temp_mean,
        "y_temp": y_temp,
        "mask_y": mask_y,
    }


def make_block_splits(
    reftime: pd.DatetimeIndex,
    train_hours: float = 348.0,
    val_hours: float = 60.0,
    test_hours: float = 60.0,
    gap_hours: float = 36.0,
) -> dict[str, np.ndarray]:
    """Partition forecast runs into contiguous seasonal blocks separated by 36h buffer gaps.

    Each 24-day (576h) cycle is structured as:
        [Train (348h)] -> [Gap (36h)] -> [Val (60h)] -> [Gap (36h)] -> [Test (60h)] -> [Gap (36h)]
    Because gap_hours (36h) > horizon_size (33h), target windows never overlap across splits.
    """
    cycle_hours = train_hours + val_hours + test_hours + 3.0 * gap_hours
    elapsed_hours = (reftime - reftime[0]).total_seconds().to_numpy() / 3600.0
    pos = np.mod(elapsed_hours, cycle_hours)

    t_end = train_hours
    v_start = t_end + gap_hours
    v_end = v_start + val_hours
    te_start = v_end + gap_hours
    te_end = te_start + test_hours

    train_idx = np.flatnonzero(pos < t_end)
    val_idx = np.flatnonzero((pos >= v_start) & (pos < v_end))
    test_idx = np.flatnonzero((pos >= te_start) & (pos < te_end))

    return {"train": train_idx, "val": val_idx, "test": test_idx}


@dataclass
class FeatureScaler:
    """Standardizer fitted strictly on training split observations and NWP features."""

    obs_mean: np.ndarray
    obs_std: np.ndarray
    nwp_mean: np.ndarray
    nwp_std: np.ndarray

    @classmethod
    def fit(cls, x_obs: np.ndarray, x_nwp_raw: np.ndarray, train_idx: np.ndarray) -> "FeatureScaler":
        obs_tr = x_obs[train_idx].reshape(-1, x_obs.shape[-1])
        nwp_tr = x_nwp_raw[train_idx].reshape(-1, x_nwp_raw.shape[-1])
        return cls(
            obs_mean=obs_tr.mean(axis=0),
            obs_std=np.maximum(obs_tr.std(axis=0), 1e-6),
            nwp_mean=nwp_tr.mean(axis=0),
            nwp_std=np.maximum(nwp_tr.std(axis=0), 1e-6),
        )

    def transform_obs(self, x_obs: np.ndarray) -> np.ndarray:
        return ((x_obs - self.obs_mean) / self.obs_std).astype(np.float32)

    def transform_nwp(self, x_nwp_raw: np.ndarray) -> np.ndarray:
        return ((x_nwp_raw - self.nwp_mean) / self.nwp_std).astype(np.float32)


class KLODataset(Dataset):
    """PyTorch Dataset yielding normalized KLO lookback + ICON/time horizon inputs."""

    def __init__(
        self,
        raw_data: dict,
        indices: np.ndarray,
        scaler: FeatureScaler,
    ):
        x_obs = scaler.transform_obs(raw_data["x_obs"][indices])
        nwp_raw = np.concatenate(
            [raw_data["nwp_mean"][indices], raw_data["nwp_std"][indices]], axis=-1
        )
        nwp_scaled = scaler.transform_nwp(nwp_raw)
        x_nwp = np.concatenate([nwp_scaled, raw_data["time_feat"][indices]], axis=-1)

        self.x_obs = torch.from_numpy(x_obs)  # (M, 24, 3)
        self.x_nwp = torch.from_numpy(x_nwp)  # (M, 33, 11)
        self.icon_mean = torch.from_numpy(raw_data["icon_temp_mean"][indices])  # (M, 33)
        self.y = torch.from_numpy(raw_data["y_temp"][indices])  # (M, 33)
        self.mask = torch.from_numpy(raw_data["mask_y"][indices])  # (M, 33)

    def __len__(self) -> int:
        return len(self.y)

    def __getitem__(self, idx: int) -> dict[str, torch.Tensor]:
        return {
            "x_obs": self.x_obs[idx],
            "x_nwp": self.x_nwp[idx],
            "icon_mean": self.icon_mean[idx],
            "y": self.y[idx],
            "mask": self.mask[idx],
        }


def build_dataloaders(
    raw_data: dict,
    splits: dict[str, np.ndarray],
    batch_size: int = 64,
) -> tuple[dict[str, DataLoader], FeatureScaler]:
    """Fit FeatureScaler on train split and return train/val/test PyTorch DataLoaders."""
    nwp_raw_all = np.concatenate([raw_data["nwp_mean"], raw_data["nwp_std"]], axis=-1)
    scaler = FeatureScaler.fit(raw_data["x_obs"], nwp_raw_all, splits["train"])

    loaders = {}
    for name, idx in splits.items():
        ds = KLODataset(raw_data, idx, scaler)
        loaders[name] = DataLoader(
            ds,
            batch_size=batch_size,
            shuffle=(name == "train"),
            drop_last=False,
        )
    return loaders, scaler
