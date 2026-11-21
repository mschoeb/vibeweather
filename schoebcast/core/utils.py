"""Shared paths, constants, evaluation metrics, and plotting utilities."""

from pathlib import Path
from typing import Mapping, Optional, Sequence

import numpy as np
import pandas as pd

ROOT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT_DIR / "data"
MODELS_DIR = ROOT_DIR / "models"

STATION = "KLO"
FEATURES = ["temperature", "wind_u", "wind_v"]
TARGET = "temperature"
WINDOW_SIZE = 24
HORIZON_SIZE = 33


def compute_metrics(
    y_true: np.ndarray,
    y_pred: np.ndarray,
    mask: np.ndarray,
) -> dict[str, float | np.ndarray]:
    """Compute overall and per-lead-time MAE, RMSE, and Bias (°C) on valid entries.

    Args:
        y_true: Ground-truth array of shape (N, H).
        y_pred: Forecast array of shape (N, H).
        mask: Boolean validity mask of shape (N, H).
    """
    valid = mask.astype(bool) & np.isfinite(y_true) & np.isfinite(y_pred)
    err = np.where(valid, y_pred - y_true, np.nan)

    overall_err = (y_pred - y_true)[valid]
    mae = float(np.mean(np.abs(overall_err)))
    rmse = float(np.sqrt(np.mean(overall_err**2)))
    bias = float(np.mean(overall_err))

    mae_by_lead = np.nanmean(np.abs(err), axis=0)
    rmse_by_lead = np.sqrt(np.nanmean(err**2, axis=0))
    bias_by_lead = np.nanmean(err, axis=0)

    return {
        "mae": mae,
        "rmse": rmse,
        "bias": bias,
        "mae_by_lead": mae_by_lead,
        "rmse_by_lead": rmse_by_lead,
        "bias_by_lead": bias_by_lead,
        "n_valid_points": int(valid.sum()),
        "n_runs": int(y_true.shape[0]),
    }


def summarize_metrics_table(results: Mapping[str, dict]) -> pd.DataFrame:
    """Format a dictionary of {model_name: metrics_dict} as a tidy summary DataFrame."""
    rows = []
    for name, m in results.items():
        rows.append(
            {
                "model": name,
                "MAE (°C)": round(m["mae"], 3),
                "RMSE (°C)": round(m["rmse"], 3),
                "Bias (°C)": round(m["bias"], 3),
                "runs": m["n_runs"],
            }
        )
    return pd.DataFrame(rows).set_index("model")


def plot_split_timeline(
    reftime: pd.DatetimeIndex,
    y_temp: np.ndarray,
    splits: Mapping[str, np.ndarray],
) -> None:
    """Plot +1h KLO temperature across the full timeline colored by train/val/test."""
    import matplotlib.pyplot as plt

    fig, ax = plt.subplots(figsize=(13, 3.5))
    colors = {"train": "tab:blue", "val": "tab:orange", "test": "tab:green"}

    ax.plot(reftime, y_temp[:, 0], color="lightgray", lw=0.8, zorder=1, label="gap/all")
    for split_name, idx in splits.items():
        ax.scatter(
            reftime[idx],
            y_temp[idx, 0],
            s=6,
            color=colors.get(split_name, "black"),
            label=f"{split_name} ({len(idx)} runs)",
            zorder=2,
        )

    ax.set_title(f"{STATION} Temperature (+1h) — Contiguous Block Splits (36h buffer gaps)")
    ax.set_ylabel("Temperature (°C)")
    ax.legend(markerscale=2, loc="upper right")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.show()


def plot_lead_metrics(
    results: Mapping[str, dict],
    split_label: str = "Test",
) -> None:
    """Plot MAE, RMSE, and Bias by forecast lead hour (1..H) for one or more models."""
    import matplotlib.pyplot as plt

    first = next(iter(results.values()))
    leads = np.arange(1, len(first["mae_by_lead"]) + 1)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4), sharex=True)
    panels = [
        ("mae_by_lead", "MAE (°C)"),
        ("rmse_by_lead", "RMSE (°C)"),
        ("bias_by_lead", "Bias: Pred − Obs (°C)"),
    ]

    for ax, (key, ylabel) in zip(axes, panels):
        for name, m in results.items():
            ax.plot(leads, m[key], marker="o", ms=3, lw=1.8, label=name)
        if key == "bias_by_lead":
            ax.axhline(0.0, color="black", ls="--", lw=0.9, alpha=0.6)
        ax.set_xlabel("Lead time (hours)")
        ax.set_ylabel(ylabel)
        ax.set_title(f"{split_label} {ylabel.split(':')[0]}")
        ax.grid(True, alpha=0.3)
        ax.legend()

    plt.tight_layout()
    plt.show()


def plot_sample_forecast(
    raw_data: Mapping[str, np.ndarray | pd.DatetimeIndex],
    run_idx: int,
    extra_preds: Optional[Mapping[str, np.ndarray]] = None,
) -> None:
    """Plot one KLO forecast run: 24h lookback obs, 11 ICON members, ICON mean, and truth."""
    import matplotlib.pyplot as plt

    reftime = raw_data["reftime"][run_idx]
    W = raw_data["x_obs"].shape[1]
    H = raw_data["y_temp"].shape[1]

    lag_times = pd.date_range(end=reftime, periods=W, freq="h")
    lead_times = pd.to_datetime(raw_data["index_y"][run_idx])

    fig, ax = plt.subplots(figsize=(11, 4))
    ax.plot(lag_times, raw_data["x_obs"][run_idx, :, 0], color="black", lw=1.8, label="Past 24h KLO obs")

    members = raw_data["icon_temp_members"][run_idx]  # (H, 11)
    for m in range(members.shape[1]):
        ax.plot(
            lead_times,
            members[:, m],
            color="tab:blue",
            alpha=0.18,
            lw=1.0,
            label="ICON members (11)" if m == 0 else None,
        )

    ax.plot(lead_times, raw_data["icon_temp_mean"][run_idx], color="tab:blue", lw=2.0, label="ICON mean")
    ax.plot(lead_times, raw_data["y_temp"][run_idx], color="black", ls="--", lw=2.0, label="Actual KLO obs")

    if extra_preds:
        extra_colors = ["tab:green", "tab:red", "tab:purple", "tab:orange"]
        for i, (name, pred_arr) in enumerate(extra_preds.items()):
            curve = pred_arr if pred_arr.ndim == 1 else pred_arr[run_idx]
            ax.plot(
                lead_times,
                curve,
                color=extra_colors[i % len(extra_colors)],
                lw=2.0,
                label=name,
            )

    ax.axvline(reftime, color="gray", ls=":", lw=1.2)
    ax.set_title(f"{STATION} Forecast from {reftime.strftime('%Y-%m-%d %H:%M UTC')}")
    ax.set_ylabel("Temperature (°C)")
    ax.legend(loc="best")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.show()


def plot_training_history(
    history: Mapping[str, Sequence[float]],
    baseline_val_mae: Optional[float] = None,
) -> None:
    """Plot training/validation loss and validation MAE curves across epochs."""
    import matplotlib.pyplot as plt

    epochs = np.arange(1, len(history["train_loss"]) + 1)
    fig, axes = plt.subplots(1, 2, figsize=(11, 3.8))

    axes[0].plot(epochs, history["train_loss"], label="Train loss")
    axes[0].plot(epochs, history["val_loss"], label="Val loss")
    axes[0].set_xlabel("Epoch")
    axes[0].set_ylabel("Huber loss")
    axes[0].set_title("Loss Curves")
    axes[0].legend()
    axes[0].grid(True, alpha=0.3)

    axes[1].plot(epochs, history["val_mae"], color="tab:orange", lw=2.0, label="Schoebcast Val MAE")
    if baseline_val_mae is not None:
        axes[1].axhline(
            baseline_val_mae,
            color="tab:blue",
            ls="--",
            lw=1.5,
            label=f"Raw ICON Val MAE ({baseline_val_mae:.3f} °C)",
        )
    axes[1].set_xlabel("Epoch")
    axes[1].set_ylabel("MAE (°C)")
    axes[1].set_title("Validation MAE vs Raw ICON")
    axes[1].legend()
    axes[1].grid(True, alpha=0.3)

    plt.tight_layout()
    plt.show()
