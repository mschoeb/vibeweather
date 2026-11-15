"""Encoder-Decoder GRU residual postprocessor and training/inference helpers."""

from copy import deepcopy
from pathlib import Path
from typing import Literal, Optional

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader

from .data import FeatureScaler
from .utils import MODELS_DIR


class SchoebcastGRU(nn.Module):
    """Small Encoder-Decoder GRU predicting local temperature residuals over ICON.

    Architecture:
      1. `obs_encoder`: 1-layer unidirectional GRU over past 24h KLO observations (B, W, obs_dim)
         producing context state `h_obs` at forecast reference time t=0.
      2. `horizon_gru`: 1-layer bidirectional GRU over the 33h ICON forecast trajectory
         concatenated with the latest t=0 KLO observation, seeded by `h_obs`.
      3. `head`: Zero-initialized MLP predicting `delta_T` so `y_hat = icon_mean + delta_T`.
    """

    def __init__(
        self,
        obs_dim: int = 3,
        nwp_dim: int = 11,
        enc_hidden: int = 32,
        dec_hidden: int = 32,
        dropout: float = 0.15,
    ):
        super().__init__()
        self.config = {
            "obs_dim": obs_dim,
            "nwp_dim": nwp_dim,
            "enc_hidden": enc_hidden,
            "dec_hidden": dec_hidden,
            "dropout": dropout,
        }

        self.obs_encoder = nn.GRU(
            input_size=obs_dim,
            hidden_size=enc_hidden,
            num_layers=1,
            batch_first=True,
        )
        self.init_dec_state = nn.Linear(enc_hidden, 2 * dec_hidden)

        self.horizon_gru = nn.GRU(
            input_size=nwp_dim + obs_dim,
            hidden_size=dec_hidden,
            num_layers=1,
            bidirectional=True,
            batch_first=True,
        )

        self.head = nn.Sequential(
            nn.Dropout(dropout),
            nn.Linear(2 * dec_hidden + enc_hidden, dec_hidden),
            nn.GELU(),
            nn.Linear(dec_hidden, 1),
        )
        # Zero-init final residual layer so epoch 0 starts exactly at raw ICON mean
        nn.init.zeros_(self.head[-1].weight)
        nn.init.zeros_(self.head[-1].bias)

    def forward(
        self,
        x_obs: torch.Tensor,
        x_nwp: torch.Tensor,
        icon_mean: torch.Tensor,
    ) -> torch.Tensor:
        """Predict postprocessed temperature (B, H) in °C."""
        _, h_n = self.obs_encoder(x_obs)  # h_n: (1, B, enc_hidden)
        ctx = h_n.squeeze(0)  # (B, enc_hidden)

        # Seed forward and backward initial hidden states of horizon GRU
        B, H, _ = x_nwp.shape
        h0_dec = torch.tanh(self.init_dec_state(ctx))  # (B, 2 * dec_hidden)
        h0_dec = h0_dec.view(B, 2, -1).permute(1, 0, 2).contiguous()  # (2, B, dec_hidden)

        # Concatenate latest t=0 observation (B, 1, obs_dim) at every forecast step
        obs_last = x_obs[:, -1:, :].expand(-1, H, -1)
        dec_in = torch.cat([x_nwp, obs_last], dim=-1)  # (B, H, nwp_dim + obs_dim)

        dec_out, _ = self.horizon_gru(dec_in, h0_dec)  # (B, H, 2 * dec_hidden)
        ctx_seq = ctx.unsqueeze(1).expand(-1, H, -1)
        delta_t = self.head(torch.cat([dec_out, ctx_seq], dim=-1)).squeeze(-1)  # (B, H)

        return icon_mean + delta_t


def count_parameters(net: nn.Module) -> int:
    """Count trainable parameters."""
    return sum(p.numel() for p in net.parameters() if p.requires_grad)


def masked_loss(
    y_pred: torch.Tensor,
    y_true: torch.Tensor,
    mask: torch.Tensor,
    loss_type: Literal["huber", "mae", "mse"] = "huber",
) -> torch.Tensor:
    """Compute masked loss over valid target entries."""
    valid = mask.bool()
    pred_v = y_pred[valid]
    true_v = y_true[valid]

    if loss_type == "huber":
        return F.smooth_l1_loss(pred_v, true_v, beta=0.5)
    if loss_type == "mae":
        return F.l1_loss(pred_v, true_v)
    if loss_type == "mse":
        return F.mse_loss(pred_v, true_v)
    raise ValueError(f"Unknown loss_type: {loss_type}")


@torch.no_grad()
def evaluate_loader(
    net: nn.Module,
    loader: DataLoader,
    device: torch.device,
    loss_type: Literal["huber", "mae", "mse"] = "huber",
) -> tuple[float, float]:
    """Return (mean_loss, mae_degC) over a DataLoader."""
    net.eval()
    total_loss = 0.0
    total_abs_err = 0.0
    total_count = 0

    for batch in loader:
        x_obs = batch["x_obs"].to(device)
        x_nwp = batch["x_nwp"].to(device)
        icon_mean = batch["icon_mean"].to(device)
        y = batch["y"].to(device)
        mask = batch["mask"].to(device).bool()

        pred = net(x_obs, x_nwp, icon_mean)
        n_valid = int(mask.sum().item())
        if n_valid == 0:
            continue

        loss = masked_loss(pred, y, mask, loss_type=loss_type)
        total_loss += float(loss.item()) * n_valid
        total_abs_err += float((pred[mask] - y[mask]).abs().sum().item())
        total_count += n_valid

    return total_loss / total_count, total_abs_err / total_count


def train_model(
    net: nn.Module,
    loaders: dict[str, DataLoader],
    epochs: int = 40,
    lr: float = 1.5e-3,
    weight_decay: float = 1e-3,
    loss_type: Literal["huber", "mae", "mse"] = "huber",
    patience: int = 10,
    device: Optional[torch.device | str] = None,
    verbose: bool = True,
) -> dict[str, list[float]]:
    """Train `net`, restore best validation-MAE weights, and return epoch history."""
    if device is None:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    else:
        device = torch.device(device)

    net.to(device)
    optimizer = torch.optim.AdamW(net.parameters(), lr=lr, weight_decay=weight_decay)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs, eta_min=1e-5)

    history: dict[str, list[float]] = {
        "train_loss": [],
        "val_loss": [],
        "val_mae": [],
    }

    best_val_mae = float("inf")
    best_state = deepcopy(net.state_dict())
    best_epoch = 0
    epochs_no_improve = 0

    for epoch in range(1, epochs + 1):
        net.train()
        running_loss = 0.0
        running_count = 0

        for batch in loaders["train"]:
            x_obs = batch["x_obs"].to(device)
            x_nwp = batch["x_nwp"].to(device)
            icon_mean = batch["icon_mean"].to(device)
            y = batch["y"].to(device)
            mask = batch["mask"].to(device).bool()

            n_valid = int(mask.sum().item())
            if n_valid == 0:
                continue

            optimizer.zero_grad()
            pred = net(x_obs, x_nwp, icon_mean)
            loss = masked_loss(pred, y, mask, loss_type=loss_type)
            loss.backward()
            nn.utils.clip_grad_norm_(net.parameters(), max_norm=1.0)
            optimizer.step()

            running_loss += float(loss.item()) * n_valid
            running_count += n_valid

        scheduler.step()

        train_loss = running_loss / running_count
        val_loss, val_mae = evaluate_loader(net, loaders["val"], device, loss_type=loss_type)

        history["train_loss"].append(train_loss)
        history["val_loss"].append(val_loss)
        history["val_mae"].append(val_mae)

        if val_mae < best_val_mae - 1e-4:
            best_val_mae = val_mae
            best_state = deepcopy(net.state_dict())
            best_epoch = epoch
            epochs_no_improve = 0
        else:
            epochs_no_improve += 1

        if verbose and (epoch == 1 or epoch % 5 == 0 or epoch == epochs):
            print(
                f"Epoch {epoch:02d}/{epochs} | "
                f"train_loss: {train_loss:.4f} | val_loss: {val_loss:.4f} | "
                f"val_MAE: {val_mae:.3f} °C"
            )

        if epochs_no_improve >= patience:
            if verbose:
                print(f"Early stopping at epoch {epoch} (best epoch {best_epoch}: {best_val_mae:.3f} °C)")
            break

    net.load_state_dict(best_state)
    if verbose:
        print(f"Restored best model from epoch {best_epoch} (val MAE = {best_val_mae:.3f} °C)")
    return history


@torch.no_grad()
def predict(
    net: nn.Module,
    loader: DataLoader,
    device: Optional[torch.device | str] = None,
) -> np.ndarray:
    """Run inference over `loader` (unshuffled) and return (N, H) predictions in °C."""
    if device is None:
        device = next(net.parameters()).device
    else:
        device = torch.device(device)

    net.eval()
    preds = []
    for batch in loader:
        pred = net(
            batch["x_obs"].to(device),
            batch["x_nwp"].to(device),
            batch["icon_mean"].to(device),
        )
        preds.append(pred.cpu().numpy())
    return np.concatenate(preds, axis=0)


def save_checkpoint(
    net: SchoebcastGRU,
    scaler: FeatureScaler,
    filename: str = "schoebcast_klo_gru.pt",
    models_dir: Path | str = MODELS_DIR,
) -> Path:
    """Save model weights, architecture config, and FeatureScaler to `models/`."""
    models_dir = Path(models_dir)
    models_dir.mkdir(parents=True, exist_ok=True)
    out_path = models_dir / filename

    torch.save(
        {
            "model_config": net.config,
            "state_dict": net.state_dict(),
            "scaler": {
                "obs_mean": scaler.obs_mean,
                "obs_std": scaler.obs_std,
                "nwp_mean": scaler.nwp_mean,
                "nwp_std": scaler.nwp_std,
            },
        },
        out_path,
    )
    return out_path


def load_checkpoint(
    path: Path | str,
    device: Optional[torch.device | str] = None,
) -> tuple[SchoebcastGRU, FeatureScaler]:
    """Reload a saved `SchoebcastGRU` and its `FeatureScaler`."""
    ckpt = torch.load(path, map_location=device or "cpu", weights_only=False)
    net = SchoebcastGRU(**ckpt["model_config"])
    net.load_state_dict(ckpt["state_dict"])
    if device is not None:
        net.to(device)
    net.eval()
    scaler = FeatureScaler(**ckpt["scaler"])
    return net, scaler
