#!/usr/bin/env bash
# Satellite pass predictor — bash + curl/wget only, no other dependencies
# Pass predictions via n2yo.com API (free key required)
# Register at: https://www.n2yo.com/login/register/

export LANG="${LANG:-en_US.UTF-8}"

API_BASE="https://api.n2yo.com/rest/v1/satellite"

show_help() {
    cat << 'EOF'

  Usage: sat_passes.sh --sat NAME [OPTIONS]

  Upcoming satellite passes from n2yo.com. Requires a free API key.
  Register at https://www.n2yo.com/login/register/ then:
    export N2YO_KEY=your_key_here

  Location is taken from HAM_LAT / HAM_LON env vars or --lat / --lon.

  --sat NAME    Satellite name (see --list for built-in names)
  --norad N     NORAD catalog ID (use instead of --sat for unlisted sats)
  --lat LAT     Latitude in decimal degrees  (or set HAM_LAT)
  --lon LON     Longitude in decimal degrees (or set HAM_LON)
  --alt M       Altitude in meters (default: 0)
  --days N      Days to look ahead (default: 2, max: 10)
  --min-el N    Minimum elevation in degrees (default: 10)
  --key KEY     n2yo API key (or set N2YO_KEY)
  --list        Show built-in satellite catalog and exit
  --interval N  Refresh every N seconds (default: 3600)
  --once        Fetch once and exit
  --no-color    Plain text output
  --help        Show this help

  Built-in satellite names: ISS  SO-50  AO-91  AO-92  AO-73  PO-101

EOF
}

# ── Built-in satellite catalog ─────────────────────────────────────────────
# Returns "NORAD_ID|display name" or empty if unknown
sat_lookup() {
    case "${1^^}" in
        ISS)                  echo "25544|ISS (International Space Station)";;
        SO-50|SO50)           echo "27607|SO-50  145.850↑ 436.795↓ FM";;
        AO-91|AO91|FOX-1B)   echo "43017|AO-91  435.250↑ 145.960↓ FM";;
        AO-92|AO92|FOX-1D)   echo "43137|AO-92  435.350↑ 145.880↓ FM";;
        AO-73|AO73|FUNCUBE)   echo "39444|AO-73  435.170↑ 145.950↓ Linear";;
        PO-101|PO101|DIWATA2) echo "43678|PO-101 435.525↑ 145.900↓ FM";;
        *) echo "";;
    esac
}

show_list() {
    printf "\n  Built-in satellites (use with --sat):\n\n"
    printf "  %-10s  %-7s  %s\n" "Name" "NORAD" "Description"
    printf "  %-10s  %-7s  %s\n" "----------" "-------" "-----------------------------------"
    printf "  %-10s  %-7s  %s\n" "ISS"    "25544"  "International Space Station"
    printf "  %-10s  %-7s  %s\n" "SO-50"  "27607"  "FM voice  145.850 up / 436.795 down"
    printf "  %-10s  %-7s  %s\n" "AO-91"  "43017"  "FM voice  435.250 up / 145.960 down"
    printf "  %-10s  %-7s  %s\n" "AO-92"  "43137"  "FM voice  435.350 up / 145.880 down"
    printf "  %-10s  %-7s  %s\n" "AO-73"  "39444"  "Linear    435.170 up / 145.950 down"
    printf "  %-10s  %-7s  %s\n" "PO-101" "43678"  "FM voice  435.525 up / 145.900 down"
    printf "\n  Use --norad N for any other satellite.\n\n"
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]]  && { show_help; exit 0; }
[[ " $* " == *"--list"* ]]  && { show_list; exit 0; }

sat_name=""
norad_id=""
lat="${HAM_LAT:-}"
lon="${HAM_LON:-}"
alt=0
days=2
min_el=10
api_key="${N2YO_KEY:-}"
no_color=0
interval=3600
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sat)      sat_name="${2^^}";  shift 2;;
        --norad)    norad_id="$2";      shift 2;;
        --lat)      lat="$2";           shift 2;;
        --lon)      lon="$2";           shift 2;;
        --alt)      alt="$2";           shift 2;;
        --days)     days="$2";          shift 2;;
        --min-el)   min_el="$2";        shift 2;;
        --key)      api_key="$2";       shift 2;;
        --interval) interval="$2";      shift 2;;
        --once)     once=1;             shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# Resolve satellite
sat_label=""
if [ -n "$sat_name" ]; then
    result=$(sat_lookup "$sat_name")
    if [ -z "$result" ]; then
        printf "\n  Error: unknown satellite '%s' — run with --list to see options\n\n" "$sat_name" >&2
        exit 1
    fi
    norad_id="${result%%|*}"
    sat_label="${result#*|}"
elif [ -z "$norad_id" ]; then
    printf "\n  Error: --sat NAME or --norad N required\n\n" >&2
    show_help; exit 1
fi

[ -z "$sat_label" ] && sat_label="NORAD ${norad_id}"

# Validate required fields
if [ -z "$api_key" ]; then
    printf "\n  Error: N2YO API key required\n"
    printf "  Register free at https://www.n2yo.com/login/register/\n"
    printf "  Then: export N2YO_KEY=your_key\n\n" >&2
    exit 1
fi
if [ -z "$lat" ] || [ -z "$lon" ]; then
    printf "\n  Error: location required — use --lat/--lon or set HAM_LAT/HAM_LON\n\n" >&2
    exit 1
fi

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_json() {
    local url="${API_BASE}/radiopasses/${norad_id}/${lat}/${lon}/${alt}/${days}/${min_el}?apiKey=${api_key}"
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 20 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=20 "$url"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

fmt_utc() {
    date -d "@${1}" "+%a %H:%M" 2>/dev/null \
        || date -r "$1" "+%a %H:%M" 2>/dev/null \
        || echo "??:??"
}

fmt_utc_time() {
    date -d "@${1}" "+%H:%M" 2>/dev/null \
        || date -r "$1" "+%H:%M" 2>/dev/null \
        || echo "??:??"
}

el_color() {
    local el="${1:-0}"
    if   (( el >= 45 )); then printf '%s' "$GREEN"
    elif (( el >= 20 )); then printf '%s' "$YELLOW"
    else                      printf '%s' "$GRAY"
    fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    json=$(fetch_json)
    updated=$(date "+%H:%M:%S")

    if [ -z "$json" ]; then
        printf "\n  %bSat Passes%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # Check for API error
    if [[ "$json" == *'"error"'* ]]; then
        err=$(printf '%s' "$json" | grep -oP '"error"\s*:\s*"\K[^"]+')
        printf "\n  %bAPI error:%b %s\n\n" "$BOLD" "$RESET" "${err:-unknown}" >&2
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # Extract satellite name from API response (may differ from input)
    api_satname=$(printf '%s' "$json" | grep -oP '"satname"\s*:\s*"\K[^"]+')
    [ -n "$api_satname" ] && sat_label="$api_satname"

    # Parse pass objects — filter by presence of startUTC (skips the info object)
    json_flat=$(printf '%s' "$json" | tr -d '\n\r')
    rows=()
    now=$(date +%s)

    while IFS= read -r obj; do
        [[ "$obj" != *"startUTC"* ]] && continue

        start_utc=$(printf '%s' "$obj" | grep -oP '"startUTC"\s*:\s*\K[0-9]+')
        start_az=$(printf '%s' "$obj"  | grep -oP '"startAzCompass"\s*:\s*"\K[^"]+')
        max_el=$(printf '%s' "$obj"    | grep -oP '"maxEl"\s*:\s*\K[0-9]+')
        max_az=$(printf '%s' "$obj"    | grep -oP '"maxAzCompass"\s*:\s*"\K[^"]+')
        end_utc=$(printf '%s' "$obj"   | grep -oP '"endUTC"\s*:\s*\K[0-9]+')
        end_az=$(printf '%s' "$obj"    | grep -oP '"endAzCompass"\s*:\s*"\K[^"]+')
        dur=$(printf '%s' "$obj"       | grep -oP '"duration"\s*:\s*\K[0-9]+')

        [ -z "$start_utc" ] && continue

        dur_min=$(( ${dur:-0} / 60 ))
        rows+=("${start_utc}	${start_az}	${max_el}	${max_az}	${end_utc}	${end_az}	${dur_min}")
    done < <(printf '%s' "$json_flat" | grep -oP '\{[^}]+\}')

    count=${#rows[@]}

    # Display
    echo
    printf "%b  Sat Passes — %s%b" "$BOLD" "$sat_label" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  Location: %s°, %s°  |  Next %d day(s)  |  Min el: %d°\n" \
        "$lat" "$lon" "$days" "$min_el"
    echo "$SEP"
    printf "%b  %-3s  %-10s %-5s  %b%-7s%b  %-5s  %-9s %-5s  %s%b\n" \
        "$BOLD" "#" "Start" "Az" "" "Max El" "" "Az" "End" "Az" "Dur" "$RESET"
    echo "$SEP"

    if [ "$count" -eq 0 ]; then
        printf "  %bNo passes found in the next %d day(s)%b\n" "$GRAY" "$days" "$RESET"
    fi

    next_utc=0
    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r start_utc start_az max_el max_az end_utc end_az dur_min \
            <<< "${rows[$i]}"

        # Track next upcoming pass
        if (( next_utc == 0 && start_utc > now )); then
            next_utc="$start_utc"
        fi

        start_fmt=$(fmt_utc "$start_utc")
        end_fmt=$(fmt_utc_time "$end_utc")
        clr=$(el_color "$max_el")

        printf "  %-3d  %-10s %-5s  %b%5d°%b  %-5s  %-9s %-5s  %dm\n" \
            "$((i+1))" "$start_fmt" "$start_az" \
            "$clr" "$max_el" "$RESET" "$max_az" \
            "$end_fmt" "$end_az" "$dur_min"
    done

    echo "$SEP"

    # Next pass countdown
    if (( next_utc > 0 )); then
        mins=$(( (next_utc - now) / 60 ))
        if (( mins < 60 )); then
            printf "  Next pass in %bT-%dm%b\n" "$YELLOW" "$mins" "$RESET"
        else
            printf "  Next pass in %dh %dm\n" $(( mins / 60 )) $(( mins % 60 ))
        fi
    fi
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
