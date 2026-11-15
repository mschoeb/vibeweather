# VibeWeather

A personal weather forecast system combining **MeteoSwiss Open Government Data**, a custom neural postprocessing model (**Schoebcast**), and a **Flutter** frontend (**MeteoSchoeb**).

## Monorepo Structure

- **`schoebcast/`** — PyTorch Encoder–Decoder GRU (`SchoebcastGRU`) trained on PeakWeather to postprocess and remove local bias from MeteoSwiss **ICON-CH1-EPS** 11-member ensemble forecasts (`0–33h`) for Zurich Kloten (`KLO`), plus `infer_live.py` for real-time STAC GRIB2 + SwissMetNet inference (`-> klo.json`).
- **`meteoschoeb/`** — Flutter Web / PWA (and Android-ready) frontend displaying postprocessed `schoebcast` forecasts alongside raw ICON ensemble spread and live 10-minute `KLO` observations.

## Hosting Architecture (100% GitHub)

- **`main` branch**: Source code (`schoebcast/`, `meteoschoeb/`, `.github/workflows/`) and the compact (`~78 KB`) production checkpoint `schoebcast/models/schoebcast_klo_gru.pt`.
- **`gh-pages` branch (GitHub Pages)**: Single-commit static deployment serving both the compiled `meteoschoeb` Flutter Web app and `./data/klo.json` (refreshed automatically via scheduled GitHub Actions whenever a new 3-hourly ICON-CH1-EPS run is published on `data.geo.admin.ch`), while live 10-minute `KLO` station readings are fetched directly from `ch.meteoschweiz.ogd-smn`.
