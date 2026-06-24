# ham-tools

Console-only ham radio utilities for Windows (Git Bash), macOS, and Linux.  
No installs — just `bash` + `curl` (or `wget`). Every tool is a single self-contained script.

---

## Quick Start

```bash
git clone https://github.com/kc4ums/ham-tools.git
cd ham-tools
bash ham.sh
```

Pick a tool by number or letter. Press **Ctrl+C** to stop a running tool and return to the menu.  
Run any script directly with `bash <script>.sh --help` for usage.

---

## Tools

| Key | Script | Description |
|-----|--------|-------------|
| `1` | `band_conditions.sh` | HF band conditions and solar indices (hamqsl.com) |
| `2` | `pota_spots.sh` | Live POTA activator spots — filter by band/mode |
| `3` | `dx_cluster.sh` | Live DX spots from dxwatch.com |
| `4` | `solar_forecast.sh` | NOAA 27-day solar outlook: SFI, A-index, Kp |
| `5` | `qrz_lookup.sh` | Callsign lookup via QRZ XML API |
| `6` | `contest_calendar.sh` | Upcoming ham radio contests |
| `7` | `wspr_spots.sh` | WSPR propagation spots from wspr.live |
| `8` | `logbook.sh` | Local QSO logger with ADIF export and LoTW import |
| `9` | `weather.sh` | Current conditions + 10-day forecast (Open-Meteo, no key) |
| `a` | `sota_spots.sh` | Live SOTA activator spots — filter by band/mode |
| `b` | `psk_reporter.sh` | Who's hearing your callsign (PSKReporter) |
| `c` | `aprs_tnc.sh` | Live APRS packets from a Pakratt 232 serial TNC |
| `d` | `ts480.sh` | Kenwood TS-480HX/SAT CAT control and status display |
| `e` | `sat_passes.sh` | Upcoming amateur satellite passes (n2yo.com) |
| `f` | `ft8_map.sh` | FT8/FT4 activity bar chart — which bands are open? |
| — | `lotw_upload.sh` | Sign and upload new QSOs to LoTW via TQSL |

Live-data tools auto-refresh (default 300 s). All support `--once`, `--interval N`, and `--no-color`.

---

## Setup

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

```bash
# .env
HAM_CALL=KC4UMS
HAM_LOC="Home QTH"          # TQSL station location name
HAM_LAT=31.45               # decimal degrees
HAM_LON=-83.51
HAM_WEATHER_LOC="Tifton, GA"
N2YO_KEY=your_key_here      # free at n2yo.com
QRZ_USER=KC4UMS
QRZ_PASS=yourpassword
CHIRP_OUTPUT_DIR=C:/Projects/ham-tools/chirp-files
```

`.env` is gitignored — never commit credentials.  
Add your vars to `~/.bashrc` or `~/.bash_profile` for a permanent session-wide setup instead.

### Tools that require credentials

| Tool | Requirement |
|------|-------------|
| `qrz_lookup.sh` | Free QRZ account with XML API enabled |
| `sat_passes.sh` | Free n2yo.com API key |
| `lotw_upload.sh` | TQSL installed with your LoTW certificate |

---

## CHIRP Repeater Files

The `/chirp-repeaters` Claude Code command generates CHIRP-compatible CSV files from RepeaterBook.

```
/chirp-repeaters Sarasota County, FL 2m
/chirp-repeaters Tifton, GA 2m --radius 50
/chirp-repeaters Valdosta, GA 70cm --radius 25
```

- Without `--radius`: exact county or city search
- With `--radius N`: geocodes the location and searches within N miles
- NOAA Weather Radio channels (WX1–WX7, 162.400–162.550 MHz) are always appended
- Output goes to `chirp-files/` (or `CHIRP_OUTPUT_DIR`)

Requires Claude Code. See `.claude/commands/chirp-repeaters.md` for the full spec.

The `/chirp-route-repeaters` command does the same thing but along a driving route between
two points, ordered from the start to the destination.

```
/chirp-route-repeaters Tifton, GA to Atlanta, GA 2m
/chirp-route-repeaters Sarasota, FL to Tampa, FL 70cm --corridor 15
```

- Geocodes both endpoints and fetches a driving route (OSRM)
- Samples waypoints along the route and searches RepeaterBook within `--corridor N` miles
  (default 10) of each
- Repeaters are deduplicated and ordered by distance along the route, with the route mile
  marker noted in each row's comment
- NOAA Weather Radio channels are always appended
- Three files are written per run: `.csv` (CHIRP), `.json` (JSON export), `.TM271` (RT-Systems binary)
- Output goes to `chirp-files/` (or `CHIRP_OUTPUT_DIR`)

Requires Claude Code. See `.claude/commands/chirp-route-repeaters.md` for the full spec.

Every CSV in `chirp-files/` also has a matching `.json` export with the same rows, for use
outside CHIRP.

### RT-Systems TM-271 converter

`chirp_to_tm271.py` converts any CHIRP CSV to a native RT-Systems **TM-271 binary** (`.TM271`)
file that can be opened directly in RT-Systems programming software and written to the radio.

```bash
python chirp_to_tm271.py chirp-files/tifton_to_st_augustine_2m.csv
python chirp_to_tm271.py chirp-files/tifton_50mi_2m.csv --verbose
python chirp_to_tm271.py input.csv --template chirp-files/original.TM271 --out my_channels.TM271
```

- Channels must be in the 2m band (144–148 MHz) — out-of-band rows (e.g. NOAA WX) are skipped with a notice
- Channel limit: 200 (TM-271 memory size); names truncated to 6 characters
- `--template` — path to an existing `.TM271` file whose header and footer are reused
  (default: `chirp-files/original.TM271`); determines the RT-Systems version signature
- `--verbose` / `-v` prints a channel summary table
- Binary format reverse-engineered from a real `original.TM271` backup:
  - 200 × 295-byte channel records; frequencies as LE uint32 in Hz; CTCSS as Kenwood 1-indexed table

---

## Requirements

- **bash** — any version ≥ 4 (Git Bash on Windows works)
- **curl** or **wget** — for all network fetches
- Standard POSIX tools: `grep`, `sed`, `awk`, `tr`, `date` — present on all supported platforms
- **python / py** — only for `/chirp-repeaters` (parses HTML, builds CSV)
- **TQSL** — only for `lotw_upload.sh`

---

## Full Documentation

See **[MANUAL.md](MANUAL.md)** for complete flag reference, color coding, output column descriptions, Windows COM port mapping, and workflow examples for every tool.
