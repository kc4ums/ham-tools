Generate a CHIRP-compatible CSV file of repeaters along a driving route between two points,
ordered from the starting point to the destination.

## Usage
```
/chirp-route-repeaters <start location>, <state> to <end location>, <state> [band] [--corridor N]
```

Examples:
  /chirp-route-repeaters Tifton, GA to Atlanta, GA 2m
  /chirp-route-repeaters Sarasota, FL to Tampa, FL 70cm --corridor 15
  /chirp-route-repeaters Macon, GA to Savannah, GA

Band defaults to `2m`. Supported bands: 10m, 6m, 2m, 1.25m, 70cm, 33cm, 23cm.
`--corridor N` sets how far off the route (in miles) to search for repeaters — default `10`.

Before fetching anything, confirm the geocoded start/end points and the chosen route summary
(distance/duration) with the user if the location names are ambiguous (e.g. a city name that
exists in multiple states without a state qualifier).

---

## Step 0 — Output directory

Use PowerShell for all steps (Git Bash cannot reliably access `C:/` paths on this machine).
Use `python` — that is the Python launcher available on Windows here (`py` is not available).

Read `C:\Projects\ham-tools\.env` if it exists and extract `CHIRP_OUTPUT_DIR`.
Default: `C:\Projects\ham-tools\chirp-files`. Ensure the directory exists.

---

## Step 1 — Parse arguments

From `$ARGUMENTS`, split on the literal word `to` (the part before is the start, the part after
is the end). From each side extract:
- **location**: city or county name
- **state**: two-letter abbreviation

From the remainder (after the end location/state) extract:
- **band**: optional token matching `10m 6m 2m 1.25m 70cm 33cm 23cm` — default `2m`
- **corridor**: optional miles value after `--corridor` — default `10`

---

## Step 2 — Geocode start and end points

Enable TLS 1.2 and bypass cert errors for PowerShell 5.1 (same block used by `/chirp-repeaters`):
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

Geocode **both** points via Nominatim:
```
GET https://nominatim.openstreetmap.org/search?q=<location>,<state>&format=json&limit=1
Header: User-Agent: chirp-route-repeaters-hamtool/1.0
```
Extract `lat`/`lon` for the start and the end. If either lookup returns zero results, stop and
ask the user to clarify the location.

---

## Step 3 — Fetch the driving route (OSRM)

```
GET https://router.project-osrm.org/route/v1/driving/<startLon>,<startLat>;<endLon>,<endLat>
    ?overview=full&geometries=geojson&steps=false
```

From the response take `routes[0]`:
- `geometry.coordinates` — ordered list of `[lon, lat]` points along the road path
- `distance` — meters
- `duration` — seconds

If OSRM returns no route (e.g. `code != "Ok"`), fall back to a straight line between the two
geocoded points (just the two endpoints as the "route") and tell the user the corridor search
will be less accurate since it can't follow actual roads.

---

## Step 4 — Build cumulative distance along the route

In Python (`py`), walk the `coordinates` list and compute the haversine distance (in miles)
between each consecutive pair, building a running cumulative-distance array the same length as
the coordinate list. `cumulative[0] = 0`, `cumulative[-1] ≈ total route distance`.

```python
from math import radians, sin, cos, asin, sqrt

def haversine_mi(lat1, lon1, lat2, lon2):
    R = 3958.8
    p1, p2 = radians(lat1), radians(lat2)
    dphi = radians(lat2 - lat1)
    dlambda = radians(lon2 - lon1)
    a = sin(dphi/2)**2 + cos(p1)*cos(p2)*sin(dlambda/2)**2
    return 2 * R * asin(sqrt(a))
```

This cumulative array is used twice: to pick sampling waypoints (Step 5) and to order the final
repeater list by how far along the route each repeater sits (Step 8).

---

## Step 5 — Pick sampling waypoints along the route

Walk the cumulative-distance array and pick a waypoint coordinate roughly every **2 × corridor**
miles (so search circles overlap enough not to miss anything between samples), always including
the very first and very last coordinate. For a short route this may be just the two endpoints;
for a long route it could be 5–15 waypoints. Cap at 20 waypoints to avoid hammering the API — if
the route is long enough to need more, widen the spacing instead of dropping the cap silently
(mention the wider spacing to the user).

---

## Step 6 — Query RepeaterBook around each waypoint

For each waypoint, run the same proximity search used by `/chirp-repeaters`:

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

```
GET https://www.repeaterbook.com/repeaters/prox_result.php
    ?lat=<lat>&long=<lon>&distance=<corridor>&Dunit=m
    &band%5B%5D=<bandcode>
    &mode%5B%5D=1&mode%5B%5D=2&mode%5B%5D=4&mode%5B%5D=8&mode%5B%5D=16&mode%5B%5D=32&mode%5B%5D=64
```
Note: the parameter is `long` (not `lon`). Include all mode codes (1–64) so every mode is
returned; filter to the target band in Python. Space requests out slightly (e.g. small delay) to
be polite to the API since this command can issue several requests.

---

## Step 7 — Parse each response and merge

Parse every response using the **proximity search HTML structure** (same as `/chirp-repeaters`
Step 3, proximity branch — these are always radius searches here, never the exact-location
structure):

Columns within each `<tr>` block (split on `data-rpt-id="`):
1. Checkbox td
2. **Frequency td** (`class="text-nowrap"`) — `<a href="details.php?...">145.1200</a>`
3. **Offset td** — e.g. `-0.6 MHz` or `+0.6 MHz`
4. **Tone td** — CTCSS value or empty
5. **Callsign td** — plain text
6. **Location td** — city + landmark
7. State td — skip
8. Use td — skip
9. **Modes td** — e.g. `FM DSTAR`
10. Distance td — skip
11. Direction td — skip
12. **Status td** — 🟢 operational or 🔴 off air

```python
freq_m = re.search(r'details\.php[^"]*"[^>]*>\s*([\d.]+)\s*<', content)
off_m = re.match(r'([+\-])\s*[\d.]+\s*MHz', offset_raw)
re.search(r'\b(FM|DMR|D-STAR|P25|NXDN|Fusion|M17|YSF|DSTAR)\b', m_text, re.I)
```

**Band frequency ranges** (filter parsed results to the target band):

| Band  | Min MHz  | Max MHz  | Std Offset MHz |
|-------|----------|----------|----------------|
| 10m   | 28.0     | 29.7     | 0.1            |
| 6m    | 50.0     | 54.0     | 1.0            |
| 2m    | 144.0    | 148.0    | 0.6            |
| 1.25m | 222.0    | 225.0    | 1.6            |
| 70cm  | 420.0    | 450.0    | 5.0            |
| 33cm  | 902.0    | 928.0    | 12.0           |
| 23cm  | 1240.0   | 1300.0   | 12.0           |

Merge results from all waypoints into one list, **deduplicating on (frequency, callsign)** since
overlapping search circles will return the same repeater more than once.

You will need each repeater's own lat/lon to order it along the route in Step 8. RepeaterBook's
proximity result rows don't carry lat/lon directly in the visible columns above — fetch it from
the `details.php?id=...` link embedded in the frequency `<a href>` for each repeater (parse the
`id` query param, then `GET https://www.repeaterbook.com/repeaters/details.php?id=<id>` and pull
`lat`/`long` from the page, e.g. from the embedded map link or coordinate text on the page).
Batch these lookups with a small delay between requests.

---

## Step 8 — Order repeaters from start to destination

For each repeater's `(lat, lon)`, find the index of the **nearest coordinate** in the route's
`coordinates` list (by haversine distance), and read off that index's value from the
cumulative-distance array built in Step 4. That value is the repeater's "route mile marker."

Sort the deduplicated repeater list ascending by route mile marker — this gives the order from
the start location to the destination. If two repeaters land at nearly the same mile marker but
on opposite sides of the corridor, that's fine; ordering by mile marker along the route is the
intent, not lateral position.

---

## Step 9 — Build the CHIRP CSV

```
Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Skip,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE
```

### 9A — Repeater rows (in route order from Step 8)

- **Location**: sequential integer from 0, in route order (start → destination)
- **Name**: callsign truncated to 8 chars
- **Frequency**: 6 decimal places (`145.120000`)
- **Duplex**: `+` or `-`; empty if no offset
- **Offset**: standard band offset, 6 decimal places (`0.600000`)
- **Tone**: `Tone` if CTCSS present and non-zero, else `''`
- **rToneFreq**: CTCSS value; `88.5` if none
- **cToneFreq**: `88.5`
- **DtcsCode**: `023`
- **DtcsPolarity**: `NN`
- **Mode**: `FM`
- **TStep**: `5.00`
- **Skip**: empty
- **Comment**: `<city> <callsign> [<modes>] mi <N>` where `<N>` is the rounded route mile marker
  + ` OFF-AIR` if off air
- **URCALL/RPT1CALL/RPT2CALL/DVCODE**: empty

### 9B — NOAA Weather Radio channels

After all repeater rows, always append the 7 standard NOAA Weather Radio channels. Channel
numbers continue from where repeaters left off.

| Name | Frequency  |
|------|------------|
| WX1  | 162.400000 |
| WX2  | 162.425000 |
| WX3  | 162.450000 |
| WX4  | 162.475000 |
| WX5  | 162.500000 |
| WX6  | 162.525000 |
| WX7  | 162.550000 |

WX channel CSV values: `Duplex=''`, `Offset=0.000000`, `Tone=''`, `rToneFreq=88.5`,
`cToneFreq=88.5`, `DtcsCode=023`, `DtcsPolarity=NN`, `Mode=FM`, `TStep=5.00`, `Skip=''`,
`Comment=NOAA Weather Radio`.

Write with Python's `csv` module.

---

## Step 10 — Save and report

**Filename pattern:** `<start>_to_<end>_<band>` (lowercase, spaces→underscores, strip
"county"), e.g. `tifton_to_atlanta_2m` — used as the base for all three output files below.

Save to `<CHIRP_OUTPUT_DIR>\<filename>`:

1. **`<filename>.csv`** — CHIRP-compatible CSV (always written first, as above)
2. **`<filename>.json`** — JSON export of the same rows (use Python's `csv`+`json` modules)
3. **`<filename>.TM271`** — RT-Systems TM-271 binary, generated by calling:
   ```
   python C:\Projects\ham-tools\chirp_to_tm271.py <CHIRP_OUTPUT_DIR>\<filename>.csv
   ```
   The converter reads `chirp-files\original.TM271` as the template automatically.
   If `chirp_to_tm271.py` is not present, skip the TM271 step with a notice.

```
Wrote 23 repeaters to C:\...\tifton_to_atlanta_2m.csv
  Route: Tifton, GA -> Atlanta, GA  |  178 mi  |  corridor: 10 mi  |  9 waypoints sampled

 Ch  Mile  Frequency   Offset  Tone   Callsign  Location            Notes
 --  ----  ----------  ------  -----  --------  ------------------  --------------------
  0     4  145.120000  -600    88.5   W4PVW     Tifton              FM DSTAR
  1    38  146.880000  -600    None   KJ4ABC    Cordele              FM
  ...
```

Flag OFF-AIR repeaters in Notes. If 0 results, suggest increasing `--corridor` or checking that
the route actually passes near populated areas. Always show the 7 WX channels in the summary
table after the repeaters, labeled `WX1`–`WX7`.
