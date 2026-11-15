# Schoebcast

A lightweight PyTorch postprocessing model (neural MOS) that improves MeteoSwiss **ICON-CH1-EPS** weather forecasts (`0–33h` lead time, 11 ensemble members) for a specific location — currently aligned on **Zurich Kloten (`KLO`)**.

Every input feature is chosen so it can be fetched in real time from MeteoSwiss Open Government Data (`ch.meteoschweiz.ogd-forecasting-icon-ch1` + live 10-min SwissMetNet observations) to power the `meteoschoeb` frontend later.

## Structure

```text
schoebcast/
├── core/
│   ├── data.py          # PeakWeather KLO loader, 36h-gapped seasonal splits, FeatureScaler & DataLoaders
│   ├── live.py          # Live MeteoSwiss STAC (ICON-CH1 GRIB2 + SMN CSV) fetcher & inference pipeline
│   ├── model.py         # SchoebcastGRU residual network, masked Huber training, checkpoint save/load
│   └── utils.py         # Paths/constants, MAE/RMSE/Bias metrics, timeline & forecast plotting
├── data/                # Local PeakWeather & live JSON cache (gitignored)
├── models/              # Saved PyTorch checkpoints + scalers (production schoebcast_klo_gru.pt tracked)
├── infer_live.py        # CLI entrypoint producing live klo.json from MeteoSwiss OGD (~15s)
├── schoebcast.ipynb     # Main interactive workflow (data -> baseline -> train & evaluate)
├── testing.ipynb        # Scratchpad notebook
└── requirements.txt     # Python dependencies (.venv)
```

## Quickstart

Activate the workspace `.venv`, install dependencies from `requirements.txt`, and run `schoebcast.ipynb`:

```powershell
..\.venv\Scripts\pip.exe install -r requirements.txt
```

*(Note: `PeakWeatherDataset` automatically downloads required parquet/zarr files into `data/` on first run.)*

## Live Operational Inference (`infer_live.py`)

Fetch the latest complete 3-hourly **ICON-CH1-EPS** run (`T_2M`, `U_10M`, `V_10M` across 11 realizations and `+1h..+33h`, sliced in memory at KLO cell `idx=791189` via `eccodes`) + live **SwissMetNet** 24h `KLO` observations, run `SchoebcastGRU`, and emit a compact `~6 KB` `klo.json` payload for `meteoschoeb`:

```powershell
# Generate schoebcast/data/live/klo.json (~15s)
..\.venv\Scripts\python.exe infer_live.py

# Fast no-op check (~1s) used by scheduled CI when reftime is unchanged
..\.venv\Scripts\python.exe infer_live.py --check-existing data/live/klo.json --out data/live/klo.json
```

## Data & Split Design (v1 — KLO Temperature)

- **Archive**: PeakWeather (`2024-05-15` to `2025-10-13`, `4,094` valid 3-hourly ICON runs).
- **Inputs**:
  - **24h Lookback (`x_obs`)**: Hourly `KLO` observations (`temperature`, `wind_u`, `wind_v`).
  - **33h Forecast (`x_nwp`)**: ICON-CH1-EPS 11-member `mean` & `std` (`temperature`, `wind_u`, `wind_v`) + cyclical time (`sin`/`cos` of hour-of-day & day-of-year) + normalized lead hour.
- **Target**: Hourly `KLO` 2m air temperature (`+1h .. +33h`).
- **Leakage-Safe Seasonal Split**: Instead of PeakWeather's built-in `2024-10-01` split (which would train only on summer for ICON), runs are partitioned into **24-day cycles** (`348h` train / `60h` val / `60h` test) separated by **36h buffer gaps** in all directions (`2,510` train / `412` val / `420` test runs). Target windows never overlap, and every split covers all four seasons.

## Architecture (`SchoebcastGRU` v1)

A compact `18,017`-parameter residual Encoder–Decoder GRU (`y_hat = icon_temp_mean + ΔT`):
1. **`obs_encoder`**: 1-layer unidirectional GRU summarizing the past 24h `KLO` state at `t = 0`.
2. **`horizon_gru`**: 1-layer bidirectional GRU across the 33h ICON trajectory (all 33 forecast steps are known at `t = 0`), concatenated with the latest `t = 0` `KLO` observation.
3. **Residual Head**: Zero-initialized MLP predicting `ΔT`, trained with masked Huber (`SmoothL1`) loss (`~5s` on an RTX 4070 SUPER).

## KLO Benchmark Scoreboard (`+1h .. +33h` Temperature)

| Version | Split | MAE (°C) | RMSE (°C) | Bias (°C) | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **v0 — Raw ICON mean** | Val | `0.988` | `1.312` | `-0.260` | Raw 11-member ensemble mean |
| **v1 — `SchoebcastGRU`** | Val | **`0.812`** | **`1.134`** | `+0.082` | `temp` + `wind_u/v` + time (~18k params) |
| **v0 — Raw ICON mean** | Test | `0.931` | `1.199` | `-0.371` | Raw 11-member ensemble mean |
| **v1 — `SchoebcastGRU`** | Test | **`0.818`** | **`1.088`** | **`-0.013`** | **−12.1% MAE**, cold bias eliminated |

## Next Ideas / Roadmap

- **Extra real-time features**: Add `sunshine` & `humidity` (ICON + KLO obs), `LAE` (Lägern 845m) 24h temperature delta for live inversion strength, solar elevation angle, and ICON ensemble quantiles (`p10`/`p50`/`p90`).
- **Probabilistic & multi-variable outputs**: Predict uncertainty bands (`q10`/`q50`/`q90` or `μ, σ`) and expand targets to wind, precipitation, and sunshine.
- **Automated hosting**: Scheduled GitHub Actions workflow publishing `data/klo.json` to `gh-pages` alongside the `meteoschoeb` Flutter Web app.
