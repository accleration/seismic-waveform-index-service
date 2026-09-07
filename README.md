# Seismic Waveform Index Service

Toolkit for building and incrementally maintaining a **file-level SQLite index** over large archives of **miniSEED** waveform files, and for serving online waveform extraction through the **FDSN `dataselect`** interface together with a small **Flask** web front end.

This is the supporting source code of the manuscript:

> *Design and Implementation of Large-Scale Seismic Waveform Data Extraction Software Based on an Index Database* (under review, *Earth Science Informatics*)

## Repository layout

| Path | Purpose |
| --- | --- |
| `auto.sh` | One-off full build. Creates per-province file lists, runs `mseedindex` for each province, merges the provincial indexes into per-year indexes, merges all yearly indexes into `All_Merged.sqlite`, updates the `fdsnws_dataselect` configuration and (re)starts the service. |
| `auto_daily_exp.sh` | Daily **dynamic (incremental) update**. Reads `MAX(endtime)` from the merged yearly index, detects newly added miniSEED files with `find -newer`, indexes only the new files, merges them into the yearly index, rebuilds the full index with a composite query index on `(network, station, location, channel, starttime, endtime)`, then updates the configuration and restarts the service. |
| `get_subfolder_names_mseed.py` | Helper that lists the valid sub-folders of the data root for a given year and emits the per-folder `find` commands used to build the `inputfile_list_*` files. |
| `mseed_web/` | Flask web front end for online query/download and administrator access-record review. |

## Workflow

1. **Initial build (once)** — `./auto.sh <start_year> <end_year>`
   - create per-province file lists → run `mseedindex` → merge to yearly index → merge to full index.
2. **Daily incremental update (e.g., cron)** — `./auto_daily_exp.sh`
   - index only the files added since the last indexed time → merge into yearly/full index → rebuild composite index → update and restart the FDSN service.

## Configuration

All deployment-specific values are read from environment variables (with generic defaults) and must be set for your environment:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `SEISDATA_BASE` | `auto*.sh`, `get_subfolder_names_mseed.py` | Root directory of the miniSEED archive (`<year>/<province>/...`) |
| `INDEX_PROJECT_DIR` | `auto*.sh` | Working directory of the index project |
| `MSEEDINDEX_BIN` | `auto.sh` | Path to the `mseedindex` executable |
| `FDSNWS_CONFIG` | `auto*.sh` | Path to the `fdsnws_dataselect` configuration file |
| `CONDA_ROOT`, `CONDA_ENV_NAME` | `auto*.sh` | Conda root and environment used to launch the FDSN service |
| `USER_HOME` | `auto_daily_exp.sh` | Home directory of the service account |
| `FDSNWS_BASE_URL` | `mseed_web/app.py` | URL of the FDSN `dataselect` service |
| `ADMIN_PASSWORD` | `mseed_web/app.py` | **Required**; administrator password for the access-record page |
| `SECRET_KEY` | `mseed_web/app.py` | Flask session secret (optional; random when unset) |
| `FLASK_DEBUG`, `HOST`, `PORT` | `mseed_web/app.py` | Development switches for the web app |

Example for the indexing scripts:

```bash
export SEISDATA_BASE=/data/seisdata
export USER_HOME="$HOME"
./auto.sh 2024 2026
```

Example for the web app:

```bash
cd mseed_web
pip install -r requirements.txt
export FDSNWS_BASE_URL="http://127.0.0.1:8082/fdsnws/dataselect/1/query"
export ADMIN_PASSWORD="replace-me"
python app.py
```

## Requirements

- Linux (Ubuntu) with **Bash**.
- [mseedindex](https://github.com/iris-edu/mseedindex) (IRIS) — builds the SQLite miniSEED index.
- [portable-fdsnws-dataselect](https://github.com/iris-edu/portable-fdsnws-dataselect) (IRIS) — FDSN `dataselect` service.
- SQLite3 command-line tool, Python 3, and a conda environment.

> **Note:** Both `auto*.sh` scripts call a helper `merge_sqlite_year.py` that merges several SQLite index databases into one (for example via `ATTACH DATABASE ...; INSERT OR IGNORE INTO tsindex SELECT * FROM ...;`). Keep that helper in the repository directory if it is part of your release.

## Security notes

- The admin authentication in `mseed_web` uses a single password passed in plaintext. It is intended for intranet deployment behind an access-controlled network; do not expose it to the public Internet without TLS and stronger authentication.
- No seismic data or user access records are included in this repository.

## License

[MIT](LICENSE)

Copyright (c) 2026 The Second Monitoring and Application Center, China Earthquake Administration (CEA).
