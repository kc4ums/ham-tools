Generate a CHIRP-compatible CSV file of repeaters for a given location and band.

## Usage
```
/chirp-repeaters <location>, <state> [band] [--radius N]
```

Examples:
  /chirp-repeaters Sarasota County, FL 2m
  /chirp-repeaters Tampa, FL 70cm
  /chirp-repeaters Tifton, GA 2m --radius 50
  /chirp-repeaters Manatee County, FL 2m --radius 30

`--radius N` searches within N miles of the location center.
Band defaults to `2m`. Supported bands: 10m, 6m, 2m, 1.25m, 70cm, 33cm, 23cm.

---

## Step 0 — Output directory

Use PowerShell for all steps (Git Bash cannot reliably access `C:/` paths on this machine).
Use `python` (not `py` or `python3`) — `py` is not installed on this machine.
Set `$env:PYTHONIOENCODING='utf-8'` before running so the 🟢/🔴 status glyphs don't crash output.

Read `C:\Projects\ham-tools\.env` if it exists and extract `CHIRP_OUTPUT_DIR`.
Default: `C:\Projects\ham-tools\chirp-files`. Ensure the directory exists.

---

## Step 1 — Parse arguments

From `$ARGUMENTS` extract:
- **location**: city or county name (e.g. "Tifton", "Sarasota County")
- **state**: two-letter abbreviation (e.g. GA, FL, TX)
- **band**: optional token matching one of `10m 6m 2m 1.25m 70cm 33cm 23cm` — default `2m`
- **radius**: optional miles value — look for `--radius N`, `N mi`, `N miles`, or a bare integer
  after the state. If absent, use exact county/city search (Step 2B).

---

## Step 2 — Fetch repeater HTML

Enable TLS 1.2 and bypass cert errors for PowerShell 5.1:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int err) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll
```

### 2A — Radius search

**Geocode** the location via Nominatim (no API key needed):
```
GET https://nominatim.openstreetmap.org/search?q=<location>,<state>&format=json&limit=1
Header: User-Agent: chirp-repeaters-hamtool/1.0
```
Extract `lat` and `lon` from the first result.

**Band codes** for the `band[]` parameter:

| Band  | Code |
|-------|------|
| 10m   | 1    |
| 6m    | 2    |
| 2m    | 4    |
| 1.25m | 8    |
| 70cm  | 16   |
| 33cm  | 32   |
| 23cm  | 64   |

**Fetch from RepeaterBook proximity search** — must include `band[]` AND all `mode[]` values or
the server returns a validation error:
```
GET https://www.repeaterbook.com/repeaters/prox_result.php
    ?lat=<lat>&long=<lon>&distance=<radius>&Dunit=m
    &band%5B%5D=<bandcode>
    &mode%5B%5D=1&mode%5B%5D=2&mode%5B%5D=4&mode%5B%5D=8&mode%5B%5D=16&mode%5B%5D=32&mode%5B%5D=64
```
Note: the parameter is `long` (not `lon`). Include all mode codes (1–64) so every mode is
returned; filter to the target band in Python.

**Filename pattern:** `<location>_<radius>mi_<band>.csv`
e.g. `tifton_50mi_2m.csv`

### 2B — Exact county/city search

Find the state_id by fetching `https://www.repeaterbook.com/repeaters/index.php` and extracting
the `<option value="NN">StateName` entry.

Determine type:
- "County" in location → `type=county`, strip "County" from the loc value
- Otherwise → `type=city`

Fetch:
```
GET https://www.repeaterbook.com/repeaters/location_search.php?type=<type>&state_id=<ID>&loc=<location>
```

**Filename pattern:** `<location>_<band>.csv` (lowercase, spaces→underscores, strip "county")
e.g. `tift_2m.csv`

---

## Step 3 — Parse repeaters with Python (`python`)

The two search modes return **different HTML structures**. Detect which by checking if the first
repeater block's freq `<td>` uses `class="freq"` (exact search) or `class="text-nowrap"` with a
`details.php` link (proximity search).

### Proximity search HTML structure (prox_result.php)

Columns within each `<tr>` block (split on `data-rpt-id="`):
1. Checkbox td
2. **Frequency td** (`class="text-nowrap"`) — contains `<a href="details.php?...">145.1200</a>`
3. **Offset td** (`class="text-nowrap"`) — contains e.g. `-0.6 MHz` or `+0.6 MHz`
4. **Tone td** — CTCSS value or empty. May be prefixed with a DMR color code or P25 NAC,
   e.g. `CC 1 127.3` or `NAC 2645 127.3` — take only the decimal CTCSS value
   (`\b(\d{2,3}\.\d)\b`, 60–260 Hz); never treat `1` or `2645` as a tone.
5. **Callsign td** — plain callsign text
6. **Location td** (`class="text-nowrap"`) — city + landmark
7. State td — skip
8. Use td — skip
9. **Modes td** — plain text e.g. `FM DSTAR`, `FM AllStar EchoLink`
10. Distance td (`data-sort="..."`) — skip
11. Direction td — skip
12. **Status td** — contains `🟢` (operational) or `🔴` (`\U0001f534`, off air)

Parse approach:
```python
# Find freq td: contains details.php link
freq_m = re.search(r'details\.php[^"]*"[^>]*>\s*([\d.]+)\s*<', content)

# Offset from the td after freq: match "[+/-]N.N MHz"
off_m = re.match(r'([+\-])\s*[\d.]+\s*MHz', offset_raw)

# Modes: scan forward from freq_idx+5 for td matching mode keywords
re.search(r'\b(FM|DMR|D-STAR|P25|NXDN|Fusion|M17|YSF|DSTAR)\b', m_text, re.I)
```

### Exact search HTML structure (location_search.php)

Freq td uses `class="freq"` with `<a>` inside and a `<span class="text-muted">+/-</span>` for
the offset direction. Remaining tds in order after the freq td: tone, location+landmark, county,
callsign, use, modes (badge spans with `mode-badge` class), status.

```python
freq_td_m = re.search(r'<td[^>]*class="freq"[^>]*>(.*?)</td>', block, re.DOTALL)
off_m = re.search(r'class="text-muted"[^>]*>([+\-])<', freq_td_content)
mode_badges = re.findall(r'mode-badge[^>]*>([^<]+)<', modes_raw)
```

### Band frequency ranges

| Band  | Min MHz  | Max MHz  | Std Offset MHz |
|-------|----------|----------|----------------|
| 10m   | 28.0     | 29.7     | 0.1            |
| 6m    | 50.0     | 54.0     | 1.0            |
| 2m    | 144.0    | 148.0    | 0.6            |
| 1.25m | 222.0    | 225.0    | 1.6            |
| 70cm  | 420.0    | 450.0    | 5.0            |
| 33cm  | 902.0    | 928.0    | 12.0           |
| 23cm  | 1240.0   | 1300.0   | 12.0           |

Filter to target band, deduplicate on (freq, callsign), sort by frequency ascending.

### FM-only filter

**Exclude every repeater that lists any digital voice mode**, even mixed-mode ones that also list FM.
Keep a repeater only if its modes contain `FM` (incl. `FM-N`) and do NOT match:
```python
re.search(r'DMR|D-?STAR|YSF|Fusion|WIRES|P-?25|NXDN|M17|DPMR|TETRA', modes, re.I)
```
AllStar, EchoLink and IRLP are internet links, not RF modes — they do not disqualify a repeater.
Collect the excluded entries and list them at the end of the report.

---

## Step 4 — Build the CHIRP CSV

```
Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Skip,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE
```

### 4A — Repeater rows

- **Location**: sequential integer from 0
- **Name**: callsign truncated to 8 chars (e.g. `W4PVW`, `KM4EYX`)
- **Frequency**: 6 decimal places (`145.120000`)
- **Duplex**: `+` or `-`; empty if no offset
- **Offset**: standard band offset, 6 decimal places (`0.600000`)
- **Tone**: `Tone` if CTCSS present and non-zero, else `''` (empty string — CHIRP rejects `None`)
- **rToneFreq**: CTCSS value; `88.5` if none
- **cToneFreq**: `88.5`
- **DtcsCode**: `023`
- **DtcsPolarity**: `NN`
- **Mode**: `FM`
- **TStep**: `5.00`
- **Skip**: empty
- **Comment**: `<city> <callsign> [<modes>]` + ` OFF-AIR` if off air
- **URCALL/RPT1CALL/RPT2CALL/DVCODE**: empty

### 4B — Simplex channels

After the repeater rows, always append the FM simplex channels for the target band.
Channel numbers continue from where repeaters left off.

| Band  | Simplex frequencies (MHz)                                                    | Calling |
|-------|------------------------------------------------------------------------------|---------|
| 2m    | 146.415–146.580 and 147.420–147.570, 15 kHz steps (23 channels)              | 146.520 |
| 1.25m | 223.420–223.580, 20 kHz steps                                                | 223.500 |
| 70cm  | 446.000–446.175, 25 kHz steps                                                | 446.000 |
| 6m    | 52.525, 52.540                                                               | 52.525  |
| 10m   | 29.600                                                                       | 29.600  |
| 33cm  | 927.500                                                                      | 927.500 |
| 23cm  | 1294.500                                                                     | 1294.500|

Simplex CSV values:
- **Name**: `CALL` for the calling frequency; otherwise `S` + frequency, truncated to 8 chars (`S146.415`)
- **Duplex**: `''`; **Offset**: `0.000000`; **Tone**: `''`
- **rToneFreq/cToneFreq**: `88.5`; **DtcsCode**: `023`; **DtcsPolarity**: `NN`
- **Mode**: `FM`; **TStep**: `5.00`; **Skip**: empty
- **Comment**: `National Simplex Calling` for the calling frequency, else `<band> FM Simplex`

Round generated frequencies (e.g. `round(146.415 + 0.015*k, 3)`) to avoid float drift.

### 4C — NOAA Weather Radio channels

After the simplex rows, always append the 7 standard NOAA Weather Radio channels.
Channel numbers continue from where simplex left off.

| Name | Frequency  |
|------|------------|
| WX1  | 162.400000 |
| WX2  | 162.425000 |
| WX3  | 162.450000 |
| WX4  | 162.475000 |
| WX5  | 162.500000 |
| WX6  | 162.525000 |
| WX7  | 162.550000 |

WX channel CSV values:
- **Duplex**: `''` (receive only — no offset)
- **Offset**: `0.000000`
- **Tone**: `''`
- **rToneFreq**: `88.5`
- **cToneFreq**: `88.5`
- **DtcsCode**: `023`
- **DtcsPolarity**: `NN`
- **Mode**: `FM`
- **TStep**: `5.00`
- **Skip**: empty
- **Comment**: `NOAA Weather Radio`

Write with Python's `csv` module.

---

## Step 5 — Save and report

Save to `<CHIRP_OUTPUT_DIR>\<filename>`.

For radius searches, print the geocoded center and radius in the header line.

```
Wrote 44 FM repeaters + 23 simplex + 7 WX to C:\...\tifton_50mi_2m.csv
  Center: 31.4550, -83.5108  |  Radius: 50 miles

 Ch  Frequency   Offset  Tone   Callsign  Location            Notes
 --  ----------  ------  -----  --------  ------------------  --------------------
  0  145.130000  -600    100.0  WB4EN     Keystone Heights    FM
  1  145.330000  -600    131.8  WX4BWK    Brunswick           FM EchoLink
  ...
 44  146.415000                 S146.415                      2m FM Simplex
  ...

Excluded 18 digital/mixed-mode:
  145.2900 N4GIH [FM DMR YSF]
  ...
```

Flag OFF-AIR repeaters in Notes. If 0 results, suggest increasing radius or checking adjacent counties.
Always show the simplex channels and the 7 WX channels (`WX1`–`WX7`) in the summary table after the repeaters.
