#!/usr/bin/env bash
# Ham radio logbook — bash only, no network required
# Stores QSOs as tab-separated values in a local file

LOG_FILE="${HAM_LOG:-$HOME/.ham_log.tsv}"
VIEW_COUNT=25

show_help() {
    cat << 'EOF'

  Usage: logbook.sh [OPTIONS]

  Local ham radio QSO logger. Data stored in ~/.ham_log.tsv
  Override location with: export HAM_LOG=/path/to/log.tsv

  (no args)              Show last 25 QSOs
  --add                  Interactively log a new QSO
  --search CALL          Search log by callsign
  --stats                Summary by band and mode
  --export-adif [FILE]   Export all QSOs to ADIF for LoTW/TQSL upload
                         Default output: ~/.ham_log.adi
  --import-adif FILE     Import QSOs from an ADIF file (e.g. LoTW export)
                         Skips duplicates matched by call + date + time
  --tail N               Show last N QSOs  (default: 25)
  --file PATH            Use a different log file
  --no-color             Plain text output
  --help                 Show this help

  HAM_CALL  Your callsign for ADIF export  (e.g. export HAM_CALL=W1AW)

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }

action="view"
search_term=""
adif_file=""
adif_import_file=""
no_color=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --add)         action="add";              shift;;
        --search)      action="search"; search_term="${2^^}"; shift 2;;
        --stats)       action="stats";            shift;;
        --export-adif)
            action="export_adif"
            [[ -n "${2:-}" && "${2:0:1}" != "-" ]] && { adif_file="$2"; shift; }
            shift;;
        --import-adif) action="import_adif"; adif_import_file="$2"; shift 2;;
        --tail)        VIEW_COUNT="$2";           shift 2;;
        --file)        LOG_FILE="$2";             shift 2;;
        --no-color)    no_color=1;                shift;;
        *)             shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; BLUE=$'\033[94m'
    CYAN=$'\033[96m';  MAGENTA=$'\033[95m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
get_band() {
    local f="${1%%.*}"
    [[ "$f" =~ ^[0-9]+$ ]] || { echo ""; return; }
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
    elif (( f >= 144000 && f <= 148000 )); then echo "2m"
    else echo ""; fi
}

default_rst() {
    case "${1^^}" in
        CW|FT8|FT4|WSPR|PSK31|RTTY|JS8|OLIVIA) echo "599";;
        *) echo "59";;
    esac
}

mode_color() {
    case "${1^^}" in
        CW)  printf '%b' "$GREEN";;
        SSB) printf '%b' "$YELLOW";;
        FT8) printf '%b' "$BLUE";;
        FT4) printf '%b' "$CYAN";;
        FM)  printf '%b' "$MAGENTA";;
    esac
}

ensure_log() {
    [ -f "$LOG_FILE" ] && return
    touch "$LOG_FILE" 2>/dev/null \
        || { printf "Error: cannot create log file: %s\n" "$LOG_FILE" >&2; exit 1; }
}

qso_count() {
    [ -f "$LOG_FILE" ] || { echo 0; return; }
    wc -l < "$LOG_FILE" | tr -d ' '
}

print_header() {
    printf "%b  %-11s %-6s %-12s %-9s %-5s %-6s %-4s %-4s %s%b\n" \
        "$BOLD" "Date" "Time" "Callsign" "Freq" "Band" "Mode" "S" "R" "Notes" "$RESET"
}

print_qso() {
    local date="$1" time="$2" call="$3" freq="$4" band="$5"
    local mode="$6" rst_s="$7" rst_r="$8" notes="$9"
    local clr
    clr=$(mode_color "$mode")
    printf "  %-11s %-6s %-12s %-9s %-5s %b%-6s%b %-4s %-4s %s\n" \
        "$date" "${time}z" "$call" "$freq" "$band" \
        "$clr" "$mode" "$RESET" "$rst_s" "$rst_r" "$notes"
}

# ── Actions ────────────────────────────────────────────────────────────────
do_add() {
    [ -t 0 ] || { printf "Error: --add requires an interactive terminal\n" >&2; exit 1; }
    ensure_log

    local now_date now_time
    now_date=$(date -u "+%Y-%m-%d")
    now_time=$(date -u "+%H%M")

    echo
    printf "%b  Log QSO%b  — %s %sz UTC\n" "$BOLD" "$RESET" "$now_date" "$now_time"
    echo "$SEP"

    # Callsign — required
    local call=""
    while [ -z "$call" ]; do
        read -e -r -p "  Callsign        : " call
        call="${call^^}"
    done

    # Frequency
    local freq band
    read -e -r -p "  Freq (kHz)      : " freq
    freq="${freq:-0}"
    band=$(get_band "$freq")

    # Mode
    local mode
    read -e -r -p "  Mode       [SSB]: " mode
    mode="${mode:-SSB}"
    mode="${mode^^}"

    # RST
    local def_rst
    def_rst=$(default_rst "$mode")
    local rst_s rst_r
    read -e -r -p "  RST Sent  [$def_rst]: " rst_s
    rst_s="${rst_s:-$def_rst}"
    read -e -r -p "  RST Rcvd  [$def_rst]: " rst_r
    rst_r="${rst_r:-$def_rst}"

    # Notes
    local notes=""
    read -e -r -p "  Notes           : " notes

    # Append
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$now_date" "$now_time" "$call" "$freq" "$band" \
        "$mode" "$rst_s" "$rst_r" "$notes" >> "$LOG_FILE"

    echo "$SEP"
    printf "  Saved — QSO #%s\n" "$(qso_count)"
    echo
    print_header
    echo "$SEP"
    print_qso "$now_date" "$now_time" "$call" "$freq" "$band" "$mode" "$rst_s" "$rst_r" "$notes"
    echo "$SEP"
    echo
}

do_view() {
    ensure_log
    local total
    total=$(qso_count)

    echo
    printf "%b  Ham Logbook%b  — %d QSO(s)  [%s]\n" "$BOLD" "$RESET" "$total" "$LOG_FILE"
    echo "$SEP"
    print_header
    echo "$SEP"

    if [ "$total" -eq 0 ]; then
        printf "%b  No QSOs logged yet. Use --add to log your first contact.%b\n" "$GRAY" "$RESET"
    else
        # Read last VIEW_COUNT lines into array, display newest first
        mapfile -t qsos < <(tail -"$VIEW_COUNT" "$LOG_FILE")
        for (( i=${#qsos[@]}-1; i>=0; i-- )); do
            IFS=$'\t' read -r date time call freq band mode rst_s rst_r notes <<< "${qsos[$i]}"
            print_qso "$date" "$time" "$call" "$freq" "$band" "$mode" "$rst_s" "$rst_r" "$notes"
        done
        if (( total > VIEW_COUNT )); then
            printf "\n%b  %d more QSO(s) not shown — use --tail N or --search CALL%b\n" \
                "$GRAY" "$((total - VIEW_COUNT))" "$RESET"
        fi
    fi

    echo "$SEP"
    echo
}

do_search() {
    ensure_log
    local total
    total=$(qso_count)

    echo
    printf "%b  Search: %s%b  — %d total QSO(s)\n" "$BOLD" "$search_term" "$RESET" "$total"
    echo "$SEP"
    print_header
    echo "$SEP"

    local count=0
    while IFS=$'\t' read -r date time call freq band mode rst_s rst_r notes; do
        [[ "${call^^}" == *"${search_term}"* ]] || continue
        count=$((count + 1))
        print_qso "$date" "$time" "$call" "$freq" "$band" "$mode" "$rst_s" "$rst_r" "$notes"
    done < "$LOG_FILE"

    echo "$SEP"
    printf "  %d result(s)\n" "$count"
    echo
}

do_stats() {
    ensure_log
    local total
    total=$(qso_count)

    echo
    printf "%b  Logbook Stats%b  — %s\n" "$BOLD" "$RESET" "$LOG_FILE"
    echo "$SEP"
    printf "  Total QSOs: %b%s%b\n" "$BOLD" "$total" "$RESET"

    if [ "$total" -gt 0 ]; then
        echo
        printf "%b  By Band:%b\n" "$BOLD" "$RESET"
        awk -F'\t' '{print $5}' "$LOG_FILE" | sort | uniq -c | sort -rn | \
            awk '{printf "    %-8s %s\n", $2, $1}'

        echo
        printf "%b  By Mode:%b\n" "$BOLD" "$RESET"
        awk -F'\t' '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | \
            awk '{printf "    %-8s %s\n", $2, $1}'

        echo
        printf "%b  Last 10 days:%b\n" "$BOLD" "$RESET"
        awk -F'\t' '{print $1}' "$LOG_FILE" | sort | uniq -c | tail -10 | \
            awk '{printf "    %-12s %s\n", $2, $1}'
    fi

    echo "$SEP"
    echo
}

do_export_adif() {
    ensure_log
    local total
    total=$(qso_count)

    local station_call="${HAM_CALL:-}"
    if [ -z "$station_call" ]; then
        [ -t 0 ] || { printf "Error: set HAM_CALL env var for non-interactive export\n" >&2; exit 1; }
        echo
        read -e -r -p "  Your callsign (or set HAM_CALL): " station_call
        station_call="${station_call^^}"
    fi
    [ -z "$station_call" ] && { printf "\nError: callsign required\n" >&2; exit 1; }

    local outfile="${adif_file:-${HOME}/.ham_log.adi}"

    adif_field() { local n="$1" v="$2"; printf '<%s:%d>%s' "$n" "${#v}" "$v"; }

    {
        printf '<ADIF_VER:5>3.1.4\n'
        adif_field PROGRAMID "ham-tools"; printf '\n'
        printf '<EOH>\n\n'

        while IFS=$'\t' read -r date time call freq band mode rst_s rst_r notes; do
            [ -z "$call" ] && continue
            local qso_date="${date//-/}"
            local freq_mhz=""
            [ "${freq:-0}" != "0" ] && freq_mhz=$(awk "BEGIN{printf \"%.4f\",$freq/1000}")

            local rec
            rec="$(adif_field CALL          "$call")"
            rec+=" $(adif_field QSO_DATE    "$qso_date")"
            rec+=" $(adif_field TIME_ON     "$time")"
            rec+=" $(adif_field BAND        "$band")"
            [ -n "$freq_mhz" ] && rec+=" $(adif_field FREQ "$freq_mhz")"
            rec+=" $(adif_field MODE        "$mode")"
            rec+=" $(adif_field RST_SENT    "$rst_s")"
            rec+=" $(adif_field RST_RCVD    "$rst_r")"
            rec+=" $(adif_field STATION_CALLSIGN "$station_call")"
            [ -n "$notes" ] && rec+=" $(adif_field COMMENT "$notes")"
            rec+=" <EOR>"
            printf '%s\n' "$rec"
        done < "$LOG_FILE"
    } > "$outfile"

    echo
    printf "%b  Exported%b  %d QSO(s) → %s\n" "$BOLD" "$RESET" "$total" "$outfile"
    printf "  Sign & upload with: tqsl -d -u \"%s\"\n" "$outfile"
    echo
}

do_import_adif() {
    [ -f "$adif_import_file" ] || {
        printf "\n  Error: file not found: %s\n\n" "$adif_import_file" >&2; exit 1
    }
    ensure_log

    # Build a temp file of existing keys (CALL<tab>DATE<tab>TIME) for dup detection
    local tmp_keys
    tmp_keys=$(mktemp)

    awk -F'\t' 'NF>=3 { print $3 "\t" $1 "\t" $2 }' "$LOG_FILE" > "$tmp_keys" 2>/dev/null

    echo
    printf "%b  Import ADIF%b  — %s\n" "$BOLD" "$RESET" "$adif_import_file"
    echo "$SEP"

    # Single awk pass: parse ADIF using field lengths (handles // comments correctly),
    # check duplicates, append new records directly to the log file.
    local stats
    stats=$(awk -v keys="$tmp_keys" -v logfile="$LOG_FILE" '
    BEGIN {
        in_hdr = 1; imported = 0; skipped = 0; errors = 0
        while ((getline line < keys) > 0) existing[line] = 1
        close(keys)
    }
    in_hdr { if (tolower($0) ~ /<eoh>/) in_hdr = 0; next }
    {
        line = $0
        # Extract every <NAME:LEN>VALUE token on this line
        while (match(line, /<[A-Za-z_][A-Za-z_0-9]*:[0-9]+>/)) {
            tag   = substr(line, RSTART, RLENGTH)
            rest  = substr(line, RSTART + RLENGTH)
            inner = substr(tag, 2, length(tag) - 2)   # strip < >
            colon = index(inner, ":")
            fname = toupper(substr(inner, 1, colon - 1))
            flen  = substr(inner, colon + 1) + 0
            fields[fname] = substr(rest, 1, flen)      # exact length — ignores // comments
            line  = substr(rest, flen + 1)
        }
        if (tolower($0) ~ /<eor>/) {
            call     = toupper(fields["CALL"])
            d        = fields["QSO_DATE"]
            t        = fields["TIME_ON"]
            freq_mhz = fields["FREQ"] + 0
            band     = tolower(fields["BAND"])
            mode     = toupper(fields["MODE"])
            grid     = toupper(fields["GRIDSQUARE"])
            for (k in fields) delete fields[k]

            if (call == "" || d == "" || t == "") { errors++; next }

            date_fmt = substr(d,1,4)"-"substr(d,5,2)"-"substr(d,7,2)
            time4    = substr(t, 1, 4)
            freq_khz = int(freq_mhz * 1000 + 0.5)
            rst      = (mode ~ /^(CW|FT8|FT4|WSPR|PSK31|RTTY|JS8|OLIVIA)$/) ? "599" : "59"

            dup_key = call "\t" date_fmt "\t" time4
            if (dup_key in existing) { skipped++; next }

            print date_fmt "\t" time4 "\t" call "\t" freq_khz "\t" band "\t" mode "\t" rst "\t" rst "\t" grid >> logfile
            existing[dup_key] = 1
            imported++
        }
    }
    END { print imported ":" skipped ":" errors }
    ' "$adif_import_file")

    rm -f "$tmp_keys"

    local imported skipped errors
    imported=$(printf '%s' "$stats" | cut -d: -f1)
    skipped=$(printf '%s'  "$stats" | cut -d: -f2)
    errors=$(printf '%s'   "$stats" | cut -d: -f3)

    printf "  Imported:  %b%d%b\n"  "$GREEN" "${imported:-0}" "$RESET"
    printf "  Skipped:   %d  (already in log)\n" "${skipped:-0}"
    [ "${errors:-0}" -gt 0 ] && \
        printf "  %bErrors:%b   %d  (missing call/date/time)\n" "$RED" "$RESET" "${errors:-0}"
    echo "$SEP"
    printf "  Log now has %d QSO(s)  [%s]\n" "$(qso_count)" "$LOG_FILE"
    echo
}

# ── Dispatch ───────────────────────────────────────────────────────────────
case "$action" in
    add)          do_add;;
    search)       do_search;;
    stats)        do_stats;;
    export_adif)  do_export_adif;;
    import_adif)  do_import_adif;;
    view)         do_view;;
esac
