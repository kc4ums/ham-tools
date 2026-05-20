#!/usr/bin/env bash
# PSK Reporter reception spots — bash + curl/wget only, no other dependencies

export LANG="${LANG:-en_US.UTF-8}"

BASE_URL="https://retrieve.pskreporter.info/query"

show_help() {
    cat << 'EOF'

  Usage: psk_reporter.sh --call CALLSIGN [OPTIONS]

  Show stations that recently heard CALLSIGN, via PSK Reporter.
  Uses $HAM_CALL if --call is not provided.
  Refreshes every 5 minutes. Press any key to refresh immediately.

  --call CALL   Callsign to look up (required if $HAM_CALL not set)
  --mode MODE   Filter by mode: CW FT8 FT4 SSB JS8
  --band BAND   Filter by band: 160m 80m 40m 30m 20m 17m 15m 12m 10m 6m
  --sort FIELD  Sort results: call  snr  band  time  (default: newest first)
  --interval N  Refresh every N seconds (default: 300)
  --once        Fetch once and exit
  --no-color    Plain text output
  --help        Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
callsign="${HAM_CALL:-}"
filter_mode=""
filter_band=""
sort_by=""
no_color=0
interval=300
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --call)     callsign="${2^^}";    shift 2;;
        --mode)     filter_mode="${2^^}"; shift 2;;
        --band)     filter_band="$2";     shift 2;;
        --sort)     sort_by="${2,,}";     shift 2;;
        --interval) interval="$2";        shift 2;;
        --once)     once=1;               shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

if [ -z "$callsign" ]; then
    printf "\n  Error: --call CALLSIGN required (or set \$HAM_CALL)\n\n" >&2
    exit 1
fi

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; BLUE=$'\033[94m'
    CYAN=$'\033[96m';  MAGENTA=$'\033[95m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''
    BOLD=''; RESET=''
fi

SEP="------------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_xml() {
    local url="${BASE_URL}?senderCallsign=${callsign}&rronly=1&lastsequence=0"
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 20 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=20 "$url"
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

fmt_time() {
    # Convert Unix epoch to HH:MM local time
    date -d "@${1}" "+%H:%M" 2>/dev/null \
        || date -r "$1" "+%H:%M" 2>/dev/null \
        || echo "--:--"
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    xml=$(fetch_xml)
    updated=$(date "+%H:%M:%S")

    if [ -z "$xml" ]; then
        printf "\n  %bPSK Reporter — %s%b  — fetch error at %s\n\n" \
            "$BOLD" "$callsign" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    rows=()

    while IFS= read -r line; do
        [[ "$line" != *"receptionReport"* ]] && continue

        receiver=$(printf '%s' "$line" | grep -oP 'receiverCallsign="\K[^"]+')
        locator=$(printf '%s' "$line"  | grep -oP 'receiverLocator="\K[^"]+')
        freq_hz=$(printf '%s' "$line"  | grep -oP 'frequency="\K[0-9]+')
        mode=$(printf '%s' "$line"     | grep -oP ' mode="\K[^"]+')
        snr=$(printf '%s' "$line"      | grep -oP 'sNR="\K[^"]+')
        dxcc=$(printf '%s' "$line"     | grep -oP 'receiverDXCCCode="\K[^"]+')
        ts=$(printf '%s' "$line"       | grep -oP 'flowStartSeconds="\K[0-9]+')

        [ -z "$receiver" ] && continue

        freq_khz=$(( ${freq_hz:-0} / 1000 ))
        band=$(get_band "$freq_khz")
        time=$(fmt_time "$ts")

        [ -n "$filter_mode" ] && [ "${mode^^}" != "$filter_mode" ] && continue
        [ -n "$filter_band" ] && [ "$band" != "$filter_band" ] && continue

        rows+=("${receiver}	${locator}	${freq_khz}	${band}	${mode}	${snr}	${dxcc}	${time}")
    done <<< "$xml"

    # Sort rows if requested
    # Tab-separated fields: receiver locator freq_khz band mode snr dxcc time
    #                       1        2       3        4    5    6   7    8
    if [ -n "$sort_by" ] && [ ${#rows[@]} -gt 0 ]; then
        case "$sort_by" in
            call) sort_flags=(-t$'\t' -k1,1);;           # alphabetical by callsign
            snr)  sort_flags=(-t$'\t' -k6,6rn);;         # highest SNR first
            band) sort_flags=(-t$'\t' -k3,3n);;          # lowest freq first (160m→6m)
            time) sort_flags=(-t$'\t' -k8,8r);;          # most recent first
            *)    sort_flags=();;
        esac
        if [ ${#sort_flags[@]} -gt 0 ]; then
            mapfile -t rows < <(printf '%s\n' "${rows[@]}" | sort "${sort_flags[@]}")
        fi
    fi

    count=${#rows[@]}

    # Display
    echo
    printf "%b  PSK Reporter — %s%b" "$BOLD" "$callsign" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  %d reception report(s)" "$count"
    [ -n "$filter_mode" ] && printf "  mode=%s" "$filter_mode"
    [ -n "$filter_band" ] && printf "  band=%s" "$filter_band"
    [ -n "$sort_by" ]     && printf "  sort=%s" "$sort_by"
    echo
    echo "$SEP"
    printf "%b  %-12s %-10s %-10s %-5s %-8s %-5s %-4s %s%b\n" \
        "$BOLD" "Heard By" "Grid" "Freq (kHz)" "Band" "Mode" "SNR" "DX" "Time" "$RESET"
    echo "$SEP"

    if [ "$count" -eq 0 ]; then
        printf "  %bNo reports found%b\n" "$GRAY" "$RESET"
    fi

    for (( i=0; i<count; i++ )); do
        IFS=$'\t' read -r receiver locator freq_khz band mode snr dxcc time <<< "${rows[$i]}"
        clr=""
        case "${mode^^}" in
            CW)  clr="$GREEN";;    SSB) clr="$YELLOW";;
            FT8) clr="$BLUE";;     FT4) clr="$CYAN";;
            FM)  clr="$MAGENTA";;
        esac
        snr_fmt="${snr:+${snr} dB}"
        printf "  %-12s %-10s %-10s %-5s %b%-8s%b %-5s %-4s %s\n" \
            "$receiver" "$locator" "$freq_khz" "$band" \
            "$clr" "$mode" "$RESET" \
            "$snr_fmt" "$dxcc" "$time"
    done

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
