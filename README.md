# Seismic Waveform Index Service

Shell and Python scripts to build and incrementally maintain a **file-level SQLite index** over a large archive of **miniSEED** waveform files, and to serve the archive through the **FDSN `dataselect` Web service**.

This is the supporting source code of the manuscript:

> *Design and Implementation of Large-Scale Seismic Waveform Data Extraction Software Based on an Index Database* (under review, *Earth Science Informatics*)

## Files

| File | Purpose |
| --- | --- |
| `auto.sh` | One-off full build. Generates per-province file lists with `find`, runs `mseedindex` for each province, merges the provincial databases into per-year databases, merges all yearly databases into `All_Merged.sqlite`, updates the `fdsnws_dataselect` configuration, and (re)starts the service. |
| `auto_daily_exp.sh` | Daily **dynamic (incremental) update**. Reads `MAX(endtime)` from the merged yearly index, finds miniSEED files newer than that timestamp, indexes only the new files with `mseedindex`, merges them into the yearly database, rebuilds the full database and its composite query index on `(network, station, location, channel, starttime, endtime)`, then updates the configuration and restarts the service. |
| `get_subfolder_names_mseed.py` | For a given year, lists the valid sub-folders under the data root and emits one `find` command per folder, which are used to create the per-province `inputfile_list_*` files. |

## Workflow

1. **Initial build (once)** — `./auto.sh <start_year> <end_year>`
   1. Create per-province file lists for each year.
   2. Run `mseedindex` per province to produce provincial SQLite indexes.
   3. Merge provincial indexes into a yearly index, then all yearly indexes into the full index.
2. **Daily incremental update (cron)** — `./auto_daily_exp.sh`
   1. Read the latest indexed time from the database.
   2. Detect newly added files with `find -newer`.
   3. Index the new files into a temporary database and merge them into the yearly index.
   4. Rebuild the full database and the composite query index; update and restart the FDSN service.

## Requirements

- **Linux (Ubuntu), Bash**, and a conda environment (paths are configured in `auto_daily_exp.sh`; `auto.sh` contains equivalent hard-coded paths that must be adjusted for your environment).
- **mseedindex** (IRIS) — builds the SQLite miniSEED index.
- **portable-fdsnws-dataselect** (IRIS) — serves the FDSN `dataselect` interface.
- **SQLite3** command-line tool and **Python 3**.

> ⚠️ Both scripts call a helper `merge_sqlite_year.py` that merges several SQLite index databases into one (e.g., `ATTACH DATABASE ...; INSERT OR IGNORE INTO tsindex SELECT * FROM ...;`). Add that helper in the same directory if it is part of your release.

## Disclaimer

- This repository contains **no seismic data** and no proprietary data products.
- File paths, conda environment names, and service locations are site-specific and must be edited before use on another machine.
- The scripts target the archive layout `$SEISDATA_BASE/<year>/<province>/<station>/<channel>/<file>` described in the paper.

## License

[MIT](LICENSE)

Copyright (c) 2026 The Second Monitoring and Application Center, China Earthquake Administration (CEA).
