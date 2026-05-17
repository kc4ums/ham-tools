#!/usr/bin/env bash
# NOAA 27-day solar cycle outlook — bash + curl/wget only, no other dependencies

URL="https://services.swpc.noaa.gov/text/27-day-outlook.txt"

# ── Args ───────────────────────────────────────────────────────────────────
no_color=0
interval=3600
once=0
days=27

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)     days="$2";     shift 2;;
        --interval) interval="$2"; shift 2;;
        --once)     once=1;        shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'
    GRAY=$'\033[90m';  BOLD=$'\033[1m';    RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="--------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_txt() {
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$URL"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

sfi_color() {
    local v="$1"
    if   (( v >= 150 )); then printf '%b' "$GREEN"
    elif (( v >= 100 )); then printf '%b' "$YELLOW"
    else                      printf '%b' "$RED"
    fi
}

kp_color() {
    local v="$1"
    if   (( v <= 2 )); then printf '%b' "$GREEN"
    elif (( v <= 4 )); then printf '%b' "$YELLOW"
    else                    printf '%b' "$RED"
    fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

# Today's components for row highlighting (Mon = Jan Feb Mar ...)
cur_year=$(date "+%Y")
cur_mon=$(date "+%b")
cur_day=$(date "+%-d" 2>/dev/null || date "+%d" | sed 's/^0//')

while true; do
    [ "$once" -eq 0 ] && clear

    data=$(fetch_txt)
    updated=$(date "+%H:%M:%S")

    if [ -z "$data" ]; then
        printf "\n  %b27-Day Solar Forecast%b  — fetch error at %s\n\n" \
            "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # Extract the issued date from the header
    issued=$(printf '%s' "$data" | grep "^:Issued:" | sed 's/:Issued: //')

    echo
    printf "%b  27-Day Solar Forecast%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  Issued: %s\n" "$issued"
    echo "$SEP"
    printf "%b  %-12s %6s   %4s   %s%b\n" \
        "$BOLD" "Date" "SFI" "Ap" "Kp" "$RESET"
    echo "$SEP"

    row_count=0
    while IFS= read -r line; do
        # Data lines start with a 4-digit year
        year=$(awk '{print $1}' <<< "$line")
        [[ "$year" =~ ^[0-9]{4}$ ]] || continue
        (( row_count >= days )) && break

        mon=$(awk '{print $2}' <<< "$line")
        day=$(awk '{print $3+0}' <<< "$line")   # +0 strips leading zero
        sfi=$(awk '{print $4}' <<< "$line")
        ap=$( awk '{print $5}' <<< "$line")
        kp=$( awk '{print $6}' <<< "$line")

        # Highlight today's row
        is_today=0
        if [[ "$year" == "$cur_year" && "$mon" == "$cur_mon" && "$day" == "$cur_day" ]]; then
            is_today=1
        fi

        date_str=$(printf "%s %s %2d" "$year" "$mon" "$day")

        if [ "$is_today" -eq 1 ]; then
            printf "%b  %-12s%b " "$BOLD" "$date_str" "$RESET"
        else
            printf "  %-12s " "$date_str"
        fi

        sfi_c=$(sfi_color "$sfi")
        kp_c=$(kp_color "$kp")
        printf "%b%6s%b   %4s   %b%s%b\n" \
            "$sfi_c" "$sfi" "$RESET" "$ap" "$kp_c" "$kp" "$RESET"

        (( row_count++ ))
    done <<< "$data"

    echo "$SEP"
    printf "  SFI: %b>=150 Good%b  %b100-149 Fair%b  %b<100 Poor%b\n" \
        "$GREEN" "$RESET" "$YELLOW" "$RESET" "$RED" "$RESET"
    printf "  Kp:  %b0-2 Quiet%b   %b3-4 Unsettled%b  %b5+ Storm%b\n" \
        "$GREEN" "$RESET" "$YELLOW" "$RESET" "$RED" "$RESET"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
