# ham-tools User Manual

Console-only ham radio utilities for Windows (Git Bash), macOS, and Linux.
No installs beyond `curl` or `wget` — everything runs with standard shell tools.

---

## Quick Start

### Launch the menu

```bash
bash ham.sh
```

Select a tool by number (1–9). Press **Ctrl+C** to stop a running tool and return to the menu.

### Run a tool directly

```bash
bash band_conditions.sh
bash pota_spots.sh --band 20m
bash logbook.sh --add
```

Every tool supports `--help` for a quick reference.

---

## Tools

---

### 1. Band Conditions — `band_conditions.sh`

Fetches current HF band conditions and solar indices from hamqsl.com.
One-shot (runs once and exits).

```bash
bash band_conditions.sh
bash band_conditions.sh --no-color
```

**Output includes:**
- Solar Flux Index (SFI), Sunspot Number, X-Ray Flux
- A-Index, K-Index (with plain-English label), Geomag Field
- Signal Noise, Aurora level
- Band condition table (Good / Fair / Poor / Closed) for 80m–40m, 30m–20m, 17m–15m, 12m–10m, Day and Night

**Flags:**

| Flag | Description |
|---|---|
| `--no-color` | Plain text output |
| `--help` | Show usage |

---

### 2. POTA Spots — `pota_spots.sh`

Live Parks on the Air activator spots from api.pota.app.
Auto-refreshes every 5 minutes. Press any key to refresh immediately.

```bash
bash pota_spots.sh
bash pota_spots.sh --band 40m
bash pota_spots.sh --mode CW
bash pota_spots.sh --mode FT8 --band 20m
bash pota_spots.sh --once
```

**Flags:**

| Flag | Description |
|---|---|
| `--mode MODE` | Filter by mode: `CW` `SSB` `FT8` `FT4` `FM` |
| `--band BAND` | Filter by band: `160m` `80m` `40m` `30m` `20m` `17m` `15m` `12m` `10m` |
| `--interval N` | Refresh every N seconds (default: 300) |
| `--once` | Fetch once and exit |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Color coding:** CW=green, SSB=yellow, FT8=blue, FT4=cyan, FM=magenta

---

### 3. DX Cluster — `dx_cluster.sh`

Live DX spots from dxwatch.com. No telnet required.
Auto-refreshes every 5 minutes. Press any key to refresh immediately.

```bash
bash dx_cluster.sh
bash dx_cluster.sh --band 20m
bash dx_cluster.sh --once
```

**Flags:**

| Flag | Description |
|---|---|
| `--band BAND` | Filter by band: `160m` `80m` `40m` `30m` `20m` `17m` `15m` `12m` `10m` `6m` |
| `--interval N` | Refresh every N seconds (default: 300) |
| `--once` | Fetch once and exit |
| `--debug` | Print raw API response and exit (troubleshooting) |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Color coding by band:** 160m/80m=red, 40m/30m=yellow, 20m/17m=green, 15m/12m/10m=blue, 6m=magenta

---

### 4. Solar Forecast — `solar_forecast.sh`

NOAA 27-day solar cycle outlook: SFI, A-index, and Kp for each day.
Auto-refreshes every hour. Press any key to refresh immediately.
Today's row is bold.

```bash
bash solar_forecast.sh
bash solar_forecast.sh --days 7
bash solar_forecast.sh --once
```

**Flags:**

| Flag | Description |
|---|---|
| `--days N` | Rows to display (default: 27) |
| `--interval N` | Refresh every N seconds (default: 3600) |
| `--once` | Fetch once and exit |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Color coding:**
- SFI: green ≥150, yellow 100–149, red <100
- Kp: green 0–2 (Quiet), yellow 3–4 (Unsettled), red 5+ (Storm)

---

### 5. QRZ Lookup — `qrz_lookup.sh`

Look up any callsign via the QRZ XML API.
Requires a free QRZ account with XML access enabled.

**Setup (one time):**

```bash
export QRZ_USER=yourcall
export QRZ_PASS=yourpassword
```

Add those lines to your `~/.bashrc` or `~/.bash_profile` to make them permanent.

```bash
bash qrz_lookup.sh W1AW
bash qrz_lookup.sh KD9ABC --no-color
```

**Output includes:** name, license class, address, grid square, coordinates, DXCC entity, email, aliases.

**Flags:**

| Flag | Description |
|---|---|
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Required environment variables:**

| Variable | Purpose |
|---|---|
| `QRZ_USER` | Your QRZ username (callsign) |
| `QRZ_PASS` | Your QRZ password |

---

### 6. Contest Calendar — `contest_calendar.sh`

Upcoming ham radio contests from contestcalendar.com.
Auto-refreshes every hour. Press any key to refresh immediately.
Data covers approximately the next 7 days from the live iCal feed.

```bash
bash contest_calendar.sh
bash contest_calendar.sh --days 7
bash contest_calendar.sh --once
```

**Flags:**

| Flag | Description |
|---|---|
| `--days N` | Look-ahead window in days (default: 30; feed covers ~7 days) |
| `--interval N` | Refresh every N seconds (default: 3600) |
| `--once` | Fetch once and exit |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Color coding:** green = starts within 7 days, yellow = starts today

---

### 7. WSPR Spots — `wspr_spots.sh`

WSPR propagation spots from db1.wspr.live (public wsprnet.org mirror).
Auto-refreshes every 2 minutes (one WSPR TX cycle). Press any key to refresh.

```bash
bash wspr_spots.sh
bash wspr_spots.sh --band 40m
bash wspr_spots.sh --call KC4UMS
bash wspr_spots.sh --band 20m --hours 4 --limit 50
bash wspr_spots.sh --once
```

**Flags:**

| Flag | Description |
|---|---|
| `--band BAND` | Filter by band: `160m` `80m` `40m` `30m` `20m` `17m` `15m` `12m` `10m` `6m` `2m` |
| `--call CALL` | Filter by callsign (TX or RX, case-insensitive) |
| `--hours N` | Look-back window in hours (default: 1) |
| `--limit N` | Max spots to show (default: 30) |
| `--interval N` | Refresh every N seconds (default: 120) |
| `--once` | Fetch once and exit |
| `--debug` | Print raw API response (troubleshooting) |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Columns:** Time (UTC), TX Call, TX Grid, RX Call, RX Grid, Band, Freq (MHz), SNR, Power (dBm)

**SNR color:** green ≥ −10 dB (strong), yellow −11 to −20 dB (moderate), gray < −20 dB (weak)

---

### 8. Logbook — `logbook.sh`

Local QSO logger. Stores contacts as tab-separated values in `~/.ham_log.tsv`.
All operations are one-shot (no auto-refresh).

```bash
bash logbook.sh                        # view last 25 QSOs
bash logbook.sh --add                  # log a new QSO interactively
bash logbook.sh --search W1AW          # search by callsign
bash logbook.sh --stats                # summary by band and mode
bash logbook.sh --tail 50              # show last 50 QSOs
bash logbook.sh --export-adif          # export all QSOs to ADIF for LoTW
bash logbook.sh --export-adif my.adi   # export to a specific file
```

#### Logging a QSO (`--add`)

Prompts for:
- **Callsign** (required)
- **Freq (kHz)** — band is derived automatically
- **Mode** — default SSB
- **RST Sent / Received** — default 599 for CW/digital, 59 for voice
- **Notes** — optional

#### Exporting to ADIF (`--export-adif`)

Writes a valid ADIF 3.1.4 file suitable for signing with TQSL and uploading to LoTW.
Your callsign is read from `HAM_CALL` or prompted interactively.

```bash
export HAM_CALL=KC4UMS
bash logbook.sh --export-adif           # writes ~/.ham_log.adi
bash logbook.sh --export-adif /tmp/log.adi
```

**Flags:**

| Flag | Description |
|---|---|
| `--add` | Interactively log a new QSO |
| `--search CALL` | Search log by callsign (partial match) |
| `--stats` | Summary: QSO count, breakdown by band and mode, last 10 days |
| `--export-adif [FILE]` | Export all QSOs to ADIF (default: `~/.ham_log.adi`) |
| `--tail N` | Show last N QSOs (default: 25) |
| `--file PATH` | Use a different log file |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Log file location:** `~/.ham_log.tsv` — override with `export HAM_LOG=/path/to/log.tsv`

---

### 9. Weather — `weather.sh`

Current conditions and 10-day forecast from Open-Meteo.
No API key required. Auto-refreshes every 30 minutes. Press any key to refresh immediately.

```bash
bash weather.sh "Raleigh"              # geocode city and show weather
bash weather.sh "Raleigh, NC"          # state qualifier is accepted (stripped for geocoder)
bash weather.sh --lat 35.77 --lon -78.64   # exact coordinates, skip geocoding
bash weather.sh "London" --units C     # Celsius, km/h, mm
bash weather.sh --once "Chicago"       # one-shot, no auto-refresh
```

**Output includes:**
- **Current:** conditions, temperature (with feels-like), humidity, wind speed and direction, precipitation if any
- **10-day:** high/low temps, precipitation sum, max wind, condition description

**Color coding:** clear=green, cloudy/fog=gray, rain/drizzle=blue, snow=cyan, storms=yellow

**Flags:**

| Flag | Description |
|---|---|
| `--lat LAT` | Latitude in decimal degrees |
| `--lon LON` | Longitude in decimal degrees |
| `--units F\|C` | Temperature units: F=Fahrenheit (default), C=Celsius |
| `--interval N` | Refresh every N seconds (default: 1800) |
| `--once` | Fetch once and exit |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Launcher shortcut:** set `HAM_WEATHER_LOC` in your environment and option 9 in the menu will always use that location without prompting.

```bash
export HAM_WEATHER_LOC="Kansas City, MO"
```

---

### 10. LoTW Upload — `lotw_upload.sh`

Signs and uploads new QSOs to ARRL Logbook of The World via TQSL.
Requires [TQSL](https://lotw.arrl.org/lotw-help/installation/) to be installed and your certificate set up.

A watermark file (`~/.ham_log.lotw_wm`) tracks which QSOs have been uploaded.
Only new QSOs are sent on each run. The watermark only advances when TQSL succeeds.

```bash
bash lotw_upload.sh                    # upload new QSOs only
bash lotw_upload.sh --all              # re-upload every QSO (like ACLog "upload all")
bash lotw_upload.sh --dry-run          # preview ADIF + tqsl command, no upload
bash lotw_upload.sh --all --dry-run    # preview full re-upload without sending
```

**Setup — recommended (add to `~/.bashrc`):**

```bash
export HAM_CALL=KC4UMS
export HAM_LOC="Home QTH"         # must match a station location in TQSL
export TQSL_BIN=/path/to/tqsl     # only needed if tqsl is not in PATH
```

Without env vars the script will prompt interactively.

**Flags:**

| Flag | Description |
|---|---|
| `--all` | Upload every QSO, ignoring the watermark |
| `--dry-run` | Preview what would be sent; do not call tqsl |
| `--loc NAME` | TQSL station location name (or `HAM_LOC`) |
| `--call SIGN` | Override callsign / certificate (or `HAM_CALL`) |
| `--tqsl PATH` | Path to tqsl binary (or `TQSL_BIN`) |
| `--no-color` | Plain text output |
| `--help` | Show usage |

**Watermark file:** `~/.ham_log.lotw_wm` — delete this file to reset upload history.

---

## Environment Variables

| Variable | Used by | Purpose |
|---|---|---|
| `HAM_LOG` | logbook, lotw_upload | Path to TSV log file (default: `~/.ham_log.tsv`) |
| `HAM_CALL` | logbook, lotw_upload | Your callsign (for ADIF `STATION_CALLSIGN`) |
| `HAM_LOC` | lotw_upload | TQSL station location name |
| `TQSL_BIN` | lotw_upload | Full path to `tqsl` binary if not in PATH |
| `HAM_WEATHER_LOC` | ham.sh launcher | Default city for weather (e.g. `"Kansas City, MO"`) |
| `QRZ_USER` | qrz_lookup | QRZ username |
| `QRZ_PASS` | qrz_lookup | QRZ password |

---

## File Locations

| File | Purpose |
|---|---|
| `~/.ham_log.tsv` | QSO log (tab-separated) |
| `~/.ham_log.adi` | Default ADIF export output |
| `~/.ham_log.lotw_wm` | LoTW upload watermark (last uploaded line count) |

---

## Tips

**Persistent env vars** — add these to `~/.bashrc` (Linux/macOS) or your Git Bash profile (`~/.bash_profile`) so you don't have to set them each session:

```bash
export HAM_CALL=KC4UMS
export HAM_LOC="Home QTH"
export HAM_WEATHER_LOC="Kansas City, MO"
export QRZ_USER=KC4UMS
export QRZ_PASS=yourpassword
```

**Running without color** — useful for piping output or logging to a file:

```bash
bash band_conditions.sh --no-color > conditions.txt
bash logbook.sh --stats --no-color
```

**Checking what TQSL would do before uploading:**

```bash
bash lotw_upload.sh --dry-run
```

**Full LoTW workflow:**

```bash
bash logbook.sh --add          # log your QSOs
bash lotw_upload.sh            # sign and upload new ones to LoTW
```
