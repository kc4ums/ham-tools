#!/usr/bin/env bash
# DX cluster spots — bash + curl/wget only, no other dependencies
# Source: dxwatch.com JSON API (HTTPS, no telnet required)

URL="https://dxwatch.com/dxsd1/s.php?s=0&r=30"

# ── Args ───────────────────────────────────────────────────────────────────
filter_band=""
no_color=0
interval=300
once=0
debug=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --band)     filter_band="$2"; shift 2;;
        --interval) interval="$2";    shift 2;;
        --once)     once=1;           shift;;
        --debug)    debug=1;          shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'
    BLUE=$'\033[94m';  CYAN=$'\033[96m';   MAGENTA=$'\033[95m'
    GRAY=$'\033[90m';  BOLD=$'\033[1m';    RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''; BOLD=''; RESET=''
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
        printf "\n  %bDX Spots%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # --debug: dump raw response so field names can be verified
    if [ "$debug" -eq 1 ]; then
        printf '%s\n' "$json"
        exit 0
    fi

    # DXWatch JSON: {"dx":[{"t":"HHMM","db":"FREQ","dx":"DXCALL","de":"SPOTTER","msg":"COMMENT"},...]}
    json_flat=$(printf '%s' "$json" | tr -d '\n\r')
    rows=()

    while IFS= read -r obj; do
        dxcall=$(printf '%s' "$obj"  | grep -oP '"dx"\s*:\s*"\K[^"]+')
        freq=$(  printf '%s' "$obj"  | grep -oP '"db"\s*:\s*"\K[^"]+')
        [ -z "$freq" ] && freq=$(printf '%s' "$obj" | grep -oP '"db"\s*:\s*\K[0-9.]+')
        spotter=$(printf '%s' "$obj" | grep -oP '"de"\s*:\s*"\K[^"]+')
        comment=$(printf '%s' "$obj" | grep -oP '"msg"\s*:\s*"\K[^"]+')
        time=$(  printf '%s' "$obj"  | grep -oP '"t"\s*:\s*"\K[^"]+')
        band=$(get_band "$freq")

        [ -z "$dxcall" ] && continue
        [ -n "$filter_band" ] && [ "$band" != "$filter_band" ] && continue

        rows+=("${dxcall}	${freq}	${band}	${spotter}	${comment}	${time}")
    done < <(printf '%s' "$json_flat" | grep -oP '\{[^}]+\}')

    count=${#rows[@]}

    echo
    printf "%b  DX Spots%b  — updated %s\n" "$BOLD" "$RESET" "$updated"
    printf "  %d spot(s)  [dxwatch.com]\n" "$count"
    echo "$SEP"
    printf "%b  %-12s %-10s %-6s %-12s %-20s %s%b\n" \
        "$BOLD" "DX Call" "Freq (kHz)" "Band" "Spotter" "Comment" "Time" "$RESET"
    echo "$SEP"

    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r dxcall freq band spotter comment time <<< "${rows[$i]}"
        clr=""
        case "$band" in
            160m|80m)    clr="$RED";;
            40m|30m)     clr="$YELLOW";;
            20m|17m)     clr="$GREEN";;
            15m|12m|10m) clr="$BLUE";;
            6m)          clr="$MAGENTA";;
        esac
        printf "  %b%-12s%b %-10s %-6s %-12s %-20s %s\n" \
            "$clr" "$dxcall" "$RESET" "$freq" "$band" "$spotter" "${comment:0:20}" "$time"
    done

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
