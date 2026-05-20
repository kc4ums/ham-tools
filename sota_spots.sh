#!/usr/bin/env bash
# SOTA recent spots fetcher — bash + curl/wget only, no other dependencies

export LANG="${LANG:-en_US.UTF-8}"

LIMIT=50
URL_BASE="https://api2.sota.org.uk/api/spots"

show_help() {
    cat << 'EOF'

  Usage: sota_spots.sh [OPTIONS]

  Recent SOTA activator spots from api2.sota.org.uk.
  Refreshes every 5 minutes. Press any key to refresh immediately.

  --mode MODE   Filter by mode: CW SSB FT8 FT4 FM
  --band BAND   Filter by band: 160m 80m 40m 30m 20m 17m 15m 12m 10m 6m
  --limit N     Fetch last N spots (default: 50)
  --interval N  Refresh every N seconds (default: 300)
  --once        Fetch once and exit
  --no-color    Plain text output
  --help        Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
filter_mode=""
filter_band=""
no_color=0
interval=300
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)     filter_mode="${2^^}"; shift 2;;
        --band)     filter_band="$2";    shift 2;;
        --limit)    LIMIT="$2";          shift 2;;
        --interval) interval="$2";       shift 2;;
        --once)     once=1;              shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; BLUE=$'\033[94m'
    CYAN=$'\033[96m';  MAGENTA=$'\033[95m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; BOLD=''; RESET=''
fi

SEP="------------------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_json() {
    local url="${URL_BASE}/${LIMIT}"
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$url"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

get_band() {
    local f="${1%%.*}"
    [[ "$f" =~ ^[0-9]+$ ]] || { echo "Other"; return; }
    if   (( f >= 1800  && f <= 2000  )); then echo "160m"
    elif (( f >= 3500  && f <= 4000  )); then echo "80m"
    elif (( f >= 5330  && f <= 5410  )); then echo "60m"
    elif (( f >= 7000  && f <= 7300  )); then echo "40m"
    elif (( f >= 10100 && f <= 10150 )); then echo "30m"
    elif (( f >= 14000 && f <= 14350 )); then echo "20m"
    elif (( f >= 18068 && f <= 18168 )); then echo "17m"
    elif (( f >= 21000 && f <= 21450 )); then echo "15m"
    elif (( f >= 24890 && f <= 24990 )); then echo "12m"
    elif (( f >= 28000 && f <= 29700 )); then echo "10m"
    elif (( f >= 50000 && f <= 54000 )); then echo "6m"
    else echo "Other"
    fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    json=$(fetch_json)
    updated=$(date "+%H:%M:%S")

    if [ -z "$json" ]; then
        printf "\n  %bSOTA Spots%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # Parse JSON: collapse to one line, extract each {...} object
    json_flat=$(printf '%s' "$json" | tr -d '\n\r')
    rows=()

    while IFS= read -r obj; do
        activator=$(printf '%s' "$obj" | grep -oP '"activatorCallsign"\s*:\s*"\K[^"]+')
        freq=$(printf '%s' "$obj"      | grep -oP '"frequency"\s*:\s*"\K[^"]+')
        mode=$(printf '%s' "$obj"      | grep -oP '"mode"\s*:\s*"\K[^"]+')
        assoc=$(printf '%s' "$obj"     | grep -oP '"associationCode"\s*:\s*"\K[^"]+')
        summit=$(printf '%s' "$obj"    | grep -oP '"summitCode"\s*:\s*"\K[^"]+')
        details=$(printf '%s' "$obj"   | grep -oP '"summitDetails"\s*:\s*"\K[^"]+')
        ts=$(printf '%s' "$obj"        | grep -oP '"timeStamp"\s*:\s*"\K[^"]+')

        [ -z "$activator" ] && continue

        # Build full summit reference and extract HH:MM from timestamp
        ref="${assoc}/${summit}"
        time="${ts:11:5}"

        # Convert MHz to kHz for band detection
        freq_khz=$(awk "BEGIN {printf \"%d\", ${freq:-0} * 1000}" 2>/dev/null)

        [ -n "$filter_mode" ] && [ "${mode^^}" != "$filter_mode" ] && continue
        [ -n "$filter_band" ] && [ "$(get_band "$freq_khz")" != "$filter_band" ] && continue

        # Truncate details to 30 chars
        [ ${#details} -gt 30 ] && details="${details:0:29}…"

        rows+=("${activator}	${freq}	${mode}	${ref}	${time}	${details}")
    done < <(printf '%s' "$json_flat" | grep -oP '\{[^}]+\}')

    count=${#rows[@]}

    # Display
    echo
    printf "%b  SOTA Spots%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  last %d spots fetched" "$LIMIT"
    [ -n "$filter_mode" ] && printf "  mode=%s" "$filter_mode"
    [ -n "$filter_band" ] && printf "  band=%s" "$filter_band"
    printf "  (%d shown)\n" "$count"
    echo "$SEP"
    printf "%b  %-4s %-12s %-10s %-8s %-12s %-5s %s%b\n" \
        "$BOLD" "#" "Activator" "Freq (MHz)" "Mode" "Summit" "Time" "Summit Name" "$RESET"
    echo "$SEP"

    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r activator freq mode ref time details <<< "${rows[$i]}"
        clr=""
        case "${mode^^}" in
            CW)  clr="$GREEN";;    SSB) clr="$YELLOW";;
            FT8) clr="$BLUE";;     FT4) clr="$CYAN";;
            FM)  clr="$MAGENTA";;
        esac
        printf "  %-4d %-12s %-10s %b%-8s%b %-12s %-5s %s\n" \
            "$((i+1))" "$activator" "$freq" "$clr" "$mode" "$RESET" "$ref" "$time" "$details"
    done

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
