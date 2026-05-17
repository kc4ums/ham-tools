#!/usr/bin/env bash
# WSPR propagation spots — bash + curl/wget only, no other dependencies
# Source: db1.wspr.info — public ClickHouse mirror of wsprnet.org
# Refreshes every 2 min (one WSPR TX cycle)

BASE_URL="https://db1.wspr.info/"
LIMIT=30

# ── Args ───────────────────────────────────────────────────────────────────
filter_band=""
filter_call=""
no_color=0
interval=120
once=0
debug=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --band)     filter_band="$2";      shift 2;;
        --call)     filter_call="${2^^}";   shift 2;;
        --limit)    LIMIT="$2";            shift 2;;
        --interval) interval="$2";         shift 2;;
        --once)     once=1;                shift;;
        --debug)    debug=1;               shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="----------------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
band_to_num() {
    case "$1" in
        160m) echo 1;;   80m) echo 3;;   60m) echo 5;;
        40m)  echo 7;;   30m) echo 10;;  20m) echo 14;;
        17m)  echo 18;;  15m) echo 21;;  12m) echo 24;;
        10m)  echo 28;;  6m)  echo 50;;  2m)  echo 144;;
        *)    echo "";;
    esac
}

band_name() {
    case "$1" in
        1)   echo "160m";;  3)   echo "80m";;   5)   echo "60m";;
        7)   echo "40m";;   10)  echo "30m";;   14)  echo "20m";;
        18)  echo "17m";;   21)  echo "15m";;   24)  echo "12m";;
        28)  echo "10m";;   50)  echo "6m";;    144) echo "2m";;
        *)   echo "${1}MHz";;
    esac
}

snr_color() {
    local abs="${1#-}"    # strip leading minus
    abs="${abs%%.*}"      # integer part
    if   (( abs <= 10 )); then printf '%b' "$GREEN"
    elif (( abs <= 20 )); then printf '%b' "$YELLOW"
    else                       printf '%b' "$GRAY"
    fi
}

build_url() {
    local fields="time%2Ccallsign%2Cgrid%2Creporter%2Creporter_grid%2Csnr%2Cfrequency%2Cpower%2Cband"
    local sql="SELECT+${fields}+FROM+wspr2_decoded"
    local where=""

    if [ -n "$filter_band" ]; then
        local bnum
        bnum=$(band_to_num "$filter_band")
        [ -n "$bnum" ] && where="band%3D${bnum}"
    fi

    if [ -n "$filter_call" ]; then
        local cc="(callsign%3D'${filter_call}'+OR+reporter%3D'${filter_call}')"
        [ -n "$where" ] && where="${where}+AND+${cc}" || where="$cc"
    fi

    [ -n "$where" ] && sql="${sql}+WHERE+${where}"
    sql="${sql}+ORDER+BY+time+DESC+LIMIT+${LIMIT}"

    printf '%s' "${BASE_URL}?query=${sql}"
}

fetch_spots() {
    local url
    url=$(build_url)
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$url"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    data=$(fetch_spots)
    updated=$(date "+%H:%M:%S")

    if [ -z "$data" ]; then
        printf "\n  %bWSPR Spots%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # --debug: show first few raw lines to verify field names/format
    if [ "$debug" -eq 1 ]; then
        printf '%s\n' "$data" | head -5
        exit 0
    fi

    # ClickHouse returns "Code. N. Exception..." on error
    if printf '%s' "$data" | grep -qE '^Code\.|^Exception'; then
        printf "\n  %bWSPR Spots%b  — query error: %s\n\n" "$BOLD" "$RESET" "$data"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # TSV: time, callsign(TX), grid(TX), reporter(RX), reporter_grid(RX), snr, frequency, power, band
    rows=()
    while IFS=$'\t' read -r ts tx_call tx_grid rx_call rx_grid snr freq_mhz power band_num; do
        [ -z "$tx_call" ] && continue
        local_band=$(band_name "$band_num")
        [[ "$freq_mhz" =~ ^[0-9] ]] && freq_fmt=$(printf '%.4f' "$freq_mhz") || freq_fmt="$freq_mhz"
        # "2024-05-17 14:22:00" → "1422z"
        time_fmt=$(printf '%s' "$ts" | grep -oP '\d{2}:\d{2}' | head -1 | tr -d ':')z
        rows+=("${time_fmt}	${tx_call}	${tx_grid}	${rx_call}	${rx_grid}	${local_band}	${freq_fmt}	${snr}	${power}")
    done <<< "$data"

    count=${#rows[@]}

    filter_desc=""
    [ -n "$filter_band" ] && filter_desc=" band:${filter_band}"
    [ -n "$filter_call" ] && filter_desc="${filter_desc} call:${filter_call}"

    echo
    printf "%b  WSPR Spots%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  %d spot(s)  [db1.wspr.info%s]\n" "$count" "$filter_desc"
    echo "$SEP"
    printf "%b  %-6s %-11s %-6s %-11s %-6s %-6s %-11s %5s %4s%b\n" \
        "$BOLD" "Time" "TX Call" "Grid" "RX Call" "Grid" "Band" "Freq (MHz)" "SNR" "Pwr" "$RESET"
    echo "$SEP"

    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r time_fmt tx_call tx_grid rx_call rx_grid bnd freq_fmt snr power <<< "${rows[$i]}"
        clr=$(snr_color "$snr")
        printf "  %-6s %-11s %-6s %-11s %-6s %-6s %-11s %b%5s%b %4s\n" \
            "$time_fmt" "$tx_call" "$tx_grid" "$rx_call" "$rx_grid" \
            "$bnd" "$freq_fmt" "$clr" "$snr" "$RESET" "${power}dBm"
    done

    echo "$SEP"
    printf "  SNR: %b≥ -10 Strong%b   %b-11 to -20 Moderate%b   %b< -20 Weak%b\n" \
        "$GREEN" "$RESET" "$YELLOW" "$RESET" "$GRAY" "$RESET"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
