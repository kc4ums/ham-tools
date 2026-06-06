#!/usr/bin/env bash
# FT8 band activity map — bash + curl/wget only, no other dependencies
# Counts unique transmitting stations per band via PSKReporter

export LANG="${LANG:-en_US.UTF-8}"

BASE_URL="https://retrieve.pskreporter.info/query"
BAR_WIDTH=30   # width of the bar chart in characters

show_help() {
    cat << 'EOF'

  Usage: ft8_map.sh [OPTIONS]

  Shows unique FT8 transmitting stations per band from PSKReporter.
  Single query covers all bands — no per-band rate-limiting delays.
  Refreshes every hour.

  --mode MODE   FT8 (default) or FT4
  --interval N  Refresh every N seconds (default: 3600)
  --once        Fetch once and exit
  --no-color    Plain text output
  --help        Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
mode="FT8"
no_color=0
interval=3600
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)     mode="${2^^}";  shift 2;;
        --interval) interval="$2"; shift 2;;
        --once)     once=1;        shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# ── Band frequency tables (Hz low:high) ────────────────────────────────────
# FT8 standard calling frequencies ±5 kHz
declare -a FT8_BANDS=(
    "160m|1.840|1835000|1845000"
    " 80m|3.573|3568000|3578000"
    " 40m|7.074|7069000|7079000"
    " 30m|10.136|10131000|10141000"
    " 20m|14.074|14069000|14079000"
    " 17m|18.100|18095000|18105000"
    " 15m|21.074|21069000|21079000"
    " 12m|24.915|24910000|24920000"
    " 10m|28.074|28069000|28079000"
    "  6m|50.313|50308000|50318000"
)

# FT4 standard calling frequencies ±5 kHz
declare -a FT4_BANDS=(
    " 80m|3.575|3570000|3580000"
    " 40m|7.0475|7042500|7052500"
    " 30m|10.140|10135000|10145000"
    " 20m|14.0805|14075500|14085500"
    " 17m|18.104|18099000|18109000"
    " 15m|21.140|21135000|21145000"
    " 12m|24.919|24914000|24924000"
    " 10m|28.180|28175000|28185000"
    "  6m|50.318|50313000|50323000"
)

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="----------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────

# Single query covering all HF (1–55 MHz) avoids per-band rate limits
fetch_all() {
    local url="${BASE_URL}?frange=1000000-55000000&rronly=1&lastsequence=0"
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 30 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=30 "$url"
    else
        echo "" ; return 1
    fi
}

# Extract "callsign<TAB>freq_hz" lines from the full XML blob
parse_senders() {
    local xml="$1"
    printf '%s' "$xml" | grep 'senderCallsign' | \
        while IFS= read -r line; do
            call=$(printf '%s' "$line" | grep -oP 'senderCallsign="\K[^"]+')
            freq=$(printf '%s' "$line" | grep -oP 'frequency="\K[0-9]+')
            [[ -n "$call" && -n "$freq" ]] && printf '%s\t%s\n' "$call" "$freq"
        done
}

count_band() {
    local pairs="$1" lo="$2" hi="$3"
    printf '%s' "$pairs" | awk -F'\t' -v lo="$lo" -v hi="$hi" \
        '$2+0 >= lo && $2+0 <= hi {print $1}' | sort -u | wc -l | tr -d ' '
}

make_bar() {
    local filled="$1" total="$2"
    local bar="" fill=""
    for (( i=0; i<filled; i++ )); do bar+="▓"; done
    for (( i=filled; i<total; i++ )); do fill+="░"; done
    printf '%s%s' "$bar" "$fill"
}

bar_color() {
    local pct="$1"
    if   (( pct >= 70 )); then printf '%s' "${BOLD}${GREEN}"
    elif (( pct >= 30 )); then printf '%s' "$GREEN"
    elif (( pct >= 10 )); then printf '%s' "$YELLOW"
    else                       printf '%s' "$GRAY"
    fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

# Select band table
if [[ "$mode" == "FT4" ]]; then
    bands=("${FT4_BANDS[@]}")
else
    bands=("${FT8_BANDS[@]}")
fi
nb=${#bands[@]}

while true; do
    [ "$once" -eq 0 ] && clear

    echo
    printf "%b  %s Activity Map%b\n" "$BOLD" "$mode" "$RESET"
    printf "  Fetching..."

    xml=$(fetch_all)
    updated=$(date "+%H:%M:%S")

    # Rate-limit or API error returns JSON {"message":"..."}
    if [[ "$xml" == *'"message"'* ]] || [ -z "$xml" ]; then
        if [[ "$xml" == *'"message"'* ]]; then
            errmsg="(rate limited — try again later)"
        else
            errmsg="(fetch error)"
        fi
        echo " error ($updated)"
        echo
        echo "$SEP"
        printf "%b  %-5s  %-7s  %-30s  %s%b\n" \
            "$BOLD" "Band" "Freq" "Unique TX (stations heard)" "Count" "$RESET"
        echo "$SEP"
        for entry in "${bands[@]}"; do
            IFS='|' read -r bname freq _ _ <<< "$entry"
            printf "  %-5s  %-7s  %b%-30s%b  %s\n" \
                "$bname" "$freq" "$GRAY" "$errmsg" "$RESET" "---"
        done
        echo "$SEP"
        echo
        [ "$once" -eq 1 ] && exit 1
        printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
        read -r -n1 -t "$interval" _ 2>/dev/null || true
        continue
    fi

    printf " done (%s)\n" "$updated"

    # Parse all sender+freq pairs once; count per band in-memory
    pairs=$(parse_senders "$xml")

    band_names=()
    band_freqs=()
    band_counts=()

    for entry in "${bands[@]}"; do
        IFS='|' read -r bname freq lo hi <<< "$entry"
        band_names+=("$bname")
        band_freqs+=("$freq")
        cnt=$(count_band "$pairs" "$lo" "$hi")
        band_counts+=("${cnt:-0}")
    done

    # Find max
    max_count=0
    for cnt in "${band_counts[@]}"; do
        (( cnt > max_count )) && max_count="$cnt"
    done

    # Display
    echo
    echo "$SEP"
    printf "%b  %-5s  %-7s  %-30s  %s%b\n" \
        "$BOLD" "Band" "Freq" "Unique TX (stations heard)" "Count" "$RESET"
    echo "$SEP"

    peak_idx=-1
    if (( max_count > 0 )); then
        for i in "${!band_counts[@]}"; do
            [[ "${band_counts[$i]}" == "$max_count" ]] && { peak_idx=$i; break; }
        done
    fi

    for (( i=0; i<nb; i++ )); do
        cnt="${band_counts[$i]}"

        if (( max_count > 0 )); then
            pct=$(( cnt * 100 / max_count ))
            filled=$(( cnt * BAR_WIDTH / max_count ))
        else
            pct=0; filled=0
        fi

        bar=$(make_bar "$filled" "$BAR_WIDTH")
        clr=$(bar_color "$pct")
        peak_marker=""
        [[ "$i" -eq "$peak_idx" ]] && peak_marker=" ← peak"

        printf "  %-5s  %-7s  %b%s%b  %5d%s\n" \
            "${band_names[$i]}" "${band_freqs[$i]}" \
            "$clr" "$bar" "$RESET" "$cnt" "$peak_marker"
    done

    echo "$SEP"
    printf "  Unique transmitting stations  •  PSKReporter  •  %s\n" "$mode"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
