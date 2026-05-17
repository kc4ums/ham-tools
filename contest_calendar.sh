#!/usr/bin/env bash
# Upcoming ham radio contests — bash + curl/wget only, no other dependencies
# Source: contestcalendar.com iCal feed

URL="https://www.contestcalendar.com/ftp/AllContests.ics"

show_help() {
    cat << 'EOF'

  Usage: contest_calendar.sh [OPTIONS]

  Upcoming ham radio contests from contestcalendar.com.
  Refreshes every hour. Press any key to refresh immediately.

  --days N      Look-ahead window in days  (default: 30)
  --interval N  Refresh every N seconds  (default: 3600)
  --once        Fetch once and exit
  --no-color    Plain text output
  --help        Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
no_color=0
interval=3600
once=0
days=30

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
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch_ical() {
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 20 "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=20 "$URL"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

# Format YYYYMMDD as "Mon DD" e.g. "May 13"
fmt_date() {
    local d="$1"
    local months=("" Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
    local m=$((10#${d:4:2}))
    printf '%s %s' "${months[$m]}" "${d:6:2}"
}

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    raw=$(fetch_ical)
    updated=$(date "+%H:%M:%S")

    if [ -z "$raw" ]; then
        printf "\n  %bContest Calendar%b  — fetch error at %s\n\n" \
            "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    today=$(date "+%Y%m%d")
    future=$(date -d "+${days} days" "+%Y%m%d" 2>/dev/null \
          || date -v+${days}d        "+%Y%m%d" 2>/dev/null \
          || echo "99991231")

    # Unfold iCal continuation lines (lines starting with space/tab), strip \r
    unfolded=$(printf '%s' "$raw" | tr -d '\r' | awk '
        /^[ \t]/ { printf "%s", substr($0,2); next }
        { printf "\n%s", $0 }
    ')

    # Parse VEVENT blocks into TSV: DTSTART<tab>DTEND<tab>SUMMARY
    events=$(awk '
        /^BEGIN:VEVENT/  { dtstart=""; dtend=""; summary="" }
        /^DTSTART/       { match($0,/[0-9]{8}/); dtstart=substr($0,RSTART,8) }
        /^DTEND/         { match($0,/[0-9]{8}/); dtend=substr($0,RSTART,8) }
        /^SUMMARY:/      { summary=substr($0,9) }
        /^END:VEVENT/    { printf "%s\t%s\t%s\n", dtstart, dtend, summary }
    ' <<< "$unfolded")

    # Filter to window and sort by date
    filtered=$(
        awk -F'\t' -v lo="$today" -v hi="$future" \
            '$1 >= lo && $1 <= hi { print }' <<< "$events" \
        | sort -t$'\t' -k1,1
    )

    count=$([ -n "$filtered" ] && printf '%s\n' "$filtered" | wc -l | tr -d ' ' || echo 0)

    echo
    printf "%b  Contest Calendar%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — updated %s" "$updated"
    echo
    printf "  Next %d days  (%d contest(s))\n" "$days" "$count"
    echo "$SEP"
    printf "%b  %-12s %-12s %s%b\n" "$BOLD" "Start" "End" "Contest" "$RESET"
    echo "$SEP"

    this_week=$(date -d "+7 days" "+%Y%m%d" 2>/dev/null \
             || date -v+7d       "+%Y%m%d" 2>/dev/null \
             || echo "99991231")

    if [ -z "$filtered" ]; then
        printf "%b  No contests found in the next %d days.%b\n" "$GRAY" "$days" "$RESET"
    else
        while IFS=$'\t' read -r dtstart dtend summary; do
            [ -z "$dtstart" ] && continue

            start_str=$(fmt_date "$dtstart")

            # iCal DTEND for all-day events is exclusive (day after last day)
            # Subtract one day for display
            dtend_disp=$(date -d "${dtend:0:4}-${dtend:4:2}-${dtend:6:2} - 1 day" "+%Y%m%d" 2>/dev/null \
                      || date -v-1d -j -f "%Y%m%d" "$dtend" "+%Y%m%d" 2>/dev/null \
                      || echo "$dtend")
            end_str=$(fmt_date "$dtend_disp")

            # Color: this week = green, today = yellow, further = plain
            clr=""
            [[ "$dtstart" < "$this_week" || "$dtstart" == "$this_week" ]] && clr="$GREEN"
            [[ "$dtstart" == "$today"    ]] && clr="$YELLOW"

            printf "  %b%-12s %-12s %s%b\n" \
                "$clr" "$start_str" "$end_str" "$summary" "$RESET"
        done <<< "$filtered"
    fi

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
