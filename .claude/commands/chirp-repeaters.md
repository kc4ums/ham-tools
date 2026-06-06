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
Use `py` (not `python3`) — that is the Python launcher available on Windows here.

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

## Step 3 — Parse repeaters with Python (`py`)

The two search modes return **different HTML structures**. Detect which by checking if the first
repeater block's freq `<td>` uses `class="freq"` (exact search) or `class="text-nowrap"` with a
`details.php` link (proximity search).

### Proximity search HTML structure (prox_result.php)

Columns within each `<tr>` block (split on `data-rpt-id="`):
1. Checkbox td
2. **Frequency td** (`class="text-nowrap"`) — contains `<a href="details.php?...">145.1200</a>`
3. **Offset td** (`class="text-nowrap"`) — contains e.g. `-0.6 MHz` or `+0.6 MHz`
4. **Tone td** — CTCSS value or empty
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

---

## Step 4 — Build the CHIRP CSV

```
Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Skip,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE
```

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

Write with Python's `csv` module.

---

## Step 5 — Save and report

Save to `<CHIRP_OUTPUT_DIR>\<filename>`.

For radius searches, print the geocoded center and radius in the header line.

```
Wrote 17 repeaters to C:\...\tifton_50mi_2m.csv
  Center: 31.4550, -83.5108  |  Radius: 50 miles

 Ch  Frequency   Offset  Tone   Callsign  Location            Notes
 --  ----------  ------  -----  --------  ------------------  --------------------
  0  144.960000  +600    88.5   KJ4KLD    Albany              FM DSTAR
  1  145.120000  -600    88.5   W4PVW     Tifton              FM DSTAR
  ...
```

Flag OFF-AIR repeaters in Notes. If 0 results, suggest increasing radius or checking adjacent counties.
