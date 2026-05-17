#!/usr/bin/env bash
# POTA active spots fetcher — bash + curl/wget only, no other dependencies

URL="https://api.pota.app/spot/activator"

# ── Args ───────────────────────────────────────────────────────────────────
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

SEP="--------------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_json() {
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$URL"
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
        printf "\n  %bPOTA Active Spots%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        if [ "$once" -eq 1 ]; then
            exit 1
        fi
        sleep "$interval"
        continue
    fi

    # Parse JSON: collapse to one line, extract each {...} object
    json_flat=$(printf '%s' "$json" | tr -d '\n\r')
    rows=()

    while IFS= read -r obj; do
        activator=$(printf '%s' "$obj" | grep -oP '"activator"\s*:\s*"\K[^"]+')
        freq=$(printf '%s' "$obj"      | grep -oP '"frequency"\s*:\s*"\K[^"]+')
        mode=$(printf '%s' "$obj"      | grep -oP '"mode"\s*:\s*"\K[^"]+')
        ref=$(printf '%s' "$obj"       | grep -oP '"reference"\s*:\s*"\K[^"]+')
        name=$(printf '%s' "$obj"      | grep -oP '"name"\s*:\s*"\K[^"]+')

        [ -z "$activator" ] && continue
        [ -z "$freq" ] && freq=$(printf '%s' "$obj" | grep -oP '"frequency"\s*:\s*\K[0-9.]+')

        [ -n "$filter_mode" ] && [ "${mode^^}" != "$filter_mode" ] && continue
        [ -n "$filter_band" ] && [ "$(get_band "$freq")" != "$filter_band" ] && continue

        rows+=("${activator}	${freq}	${mode}	${ref}	${name}")
    done < <(printf '%s' "$json_flat" | grep -oP '\{[^}]+\}')

    count=${#rows[@]}

    # Display
    echo
    printf "%b  POTA Active Spots%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  %d activator(s) on the air\n" "$count"
    echo "$SEP"
    printf "%b  %-4s %-12s %-12s %-8s %-12s %s%b\n" \
        "$BOLD" "#" "Activator" "Freq (kHz)" "Mode" "Reference" "Location" "$RESET"
    echo "$SEP"

    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r activator freq mode ref name <<< "${rows[$i]}"
        clr=""
        case "$mode" in
            CW)  clr="$GREEN";;    SSB) clr="$YELLOW";;
            FT8) clr="$BLUE";;     FT4) clr="$CYAN";;
            FM)  clr="$MAGENTA";;
        esac
        printf "  %-4d %-12s %-12s %b%-8s%b %-12s %s\n" \
            "$((i+1))" "$activator" "$freq" "$clr" "$mode" "$RESET" "$ref" "$name"
    done

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — Ctrl+C to quit\n\n" "$interval"
    sleep "$interval"
done
