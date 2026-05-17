#!/usr/bin/env bash
# LoTW upload — sign and upload new QSOs to ARRL Logbook of The World
# Requires TQSL from trustedqsl.org

LOG_FILE="${HAM_LOG:-$HOME/.ham_log.tsv}"
WM_FILE="${LOG_FILE%.tsv}.lotw_wm"
TQSL_BIN="${TQSL_BIN:-tqsl}"

show_help() {
    cat << 'EOF'

  Usage: lotw_upload.sh [OPTIONS]

  Sign and upload new QSOs to ARRL LoTW via TQSL. A watermark file
  tracks which QSOs have already been sent — only new entries are
  uploaded on each run.

  --all           Upload every QSO, ignoring watermark (re-upload all)
  --dry-run       Preview what would be sent; does not call tqsl
  --loc NAME      TQSL station location name  (or set HAM_LOC env var)
  --call SIGN     Callsign / certificate to use  (or set HAM_CALL)
  --tqsl PATH     Path to tqsl binary  (or set TQSL_BIN; default: tqsl)
  --no-color      Plain text output
  --help          Show this help

  Environment variables:
    HAM_LOG       Log file path       (default: ~/.ham_log.tsv)
    HAM_CALL      Your callsign
    HAM_LOC       TQSL station location name
    TQSL_BIN      Path to tqsl binary

  Watermark file: <logfile>.lotw_wm  (auto-created on first upload)

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }

upload_all=0
dry_run=0
station_loc="${HAM_LOC:-}"
station_call="${HAM_CALL:-}"
no_color=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)      upload_all=1;              shift;;
        --dry-run)  dry_run=1;                 shift;;
        --loc)      station_loc="$2";          shift 2;;
        --call)     station_call="${2^^}";     shift 2;;
        --tqsl)     TQSL_BIN="$2";            shift 2;;
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

SEP="----------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
adif_field() { local n="$1" v="$2"; printf '<%s:%d>%s' "$n" "${#v}" "$v"; }

build_adif() {
    local from_line="$1" call="$2" outfile="$3"
    {
        printf '<ADIF_VER:5>3.1.4\n'
        adif_field PROGRAMID "ham-tools"; printf '\n'
        printf '<EOH>\n\n'

        tail -n +"$from_line" "$LOG_FILE" | \
        while IFS=$'\t' read -r qdate qtime qcall freq band mode rst_s rst_r notes; do
            [ -z "$qcall" ] && continue
            local qso_date="${qdate//-/}"
            local freq_mhz=""
            [ "${freq:-0}" != "0" ] && \
                freq_mhz=$(awk "BEGIN{printf \"%.4f\",$freq/1000}")

            local rec
            rec="$(adif_field CALL       "$qcall")"
            rec+=" $(adif_field QSO_DATE "$qso_date")"
            rec+=" $(adif_field TIME_ON  "$qtime")"
            rec+=" $(adif_field BAND     "$band")"
            [ -n "$freq_mhz" ] && rec+=" $(adif_field FREQ "$freq_mhz")"
            rec+=" $(adif_field MODE     "$mode")"
            rec+=" $(adif_field RST_SENT "$rst_s")"
            rec+=" $(adif_field RST_RCVD "$rst_r")"
            rec+=" $(adif_field STATION_CALLSIGN "$call")"
            [ -n "$notes" ] && rec+=" $(adif_field COMMENT "$notes")"
            rec+=" <EOR>"
            printf '%s\n' "$rec"
        done
    } > "$outfile"
}

# ── Main ───────────────────────────────────────────────────────────────────
if [ ! -f "$LOG_FILE" ]; then
    printf "\n  %bError:%b log file not found: %s\n\n" "$RED" "$RESET" "$LOG_FILE" >&2
    exit 1
fi

total=$(wc -l < "$LOG_FILE" | tr -d ' ')
watermark=0
[ -f "$WM_FILE" ] && watermark=$(cat "$WM_FILE")

if [ "$upload_all" -eq 1 ]; then
    from_line=1
    new_count="$total"
else
    from_line=$((watermark + 1))
    new_count=$((total - watermark))
fi

echo
printf "%b  LoTW Upload%b\n" "$BOLD" "$RESET"
echo "$SEP"
printf "  Log file:    %s\n" "$LOG_FILE"
printf "  Total QSOs:  %d\n" "$total"
printf "  Uploaded:    %d\n" "$watermark"

if [ "$upload_all" -eq 1 ]; then
    printf "  Sending:     %b%d (all — watermark ignored)%b\n" "$YELLOW" "$new_count" "$RESET"
else
    printf "  New to send: %b%d%b\n" "$GREEN" "$new_count" "$RESET"
fi

echo "$SEP"

if [ "$new_count" -le 0 ]; then
    printf "\n  Nothing new to upload.\n"
    printf "  Use --all to re-upload every QSO.\n\n"
    exit 0
fi

# Callsign
if [ -z "$station_call" ]; then
    [ -t 0 ] || { printf "Error: set HAM_CALL env var\n" >&2; exit 1; }
    echo
    read -e -r -p "  Your callsign (or set HAM_CALL): " station_call
    station_call="${station_call^^}"
fi
[ -z "$station_call" ] && { printf "\nError: callsign required\n" >&2; exit 1; }

# Station location
if [ -z "$station_loc" ]; then
    [ -t 0 ] || { printf "Error: set HAM_LOC env var\n" >&2; exit 1; }
    read -e -r -p "  TQSL station location: " station_loc
fi
[ -z "$station_loc" ] && { printf "\nError: station location required\n" >&2; exit 1; }

# Check tqsl
if [ "$dry_run" -eq 0 ] && ! command -v "$TQSL_BIN" >/dev/null 2>&1; then
    printf "\n  %bError:%b tqsl not found (%s)\n" "$RED" "$RESET" "$TQSL_BIN"
    printf "  Install from trustedqsl.org or set TQSL_BIN=/path/to/tqsl\n\n"
    exit 1
fi

# Build temp ADIF
tmp_adif=$(mktemp /tmp/ham_lotw_XXXXXX.adi 2>/dev/null || mktemp)
trap 'rm -f "$tmp_adif"' EXIT

build_adif "$from_line" "$station_call" "$tmp_adif"

if [ "$dry_run" -eq 1 ]; then
    printf "\n  %b[dry run — %d QSO(s) — tqsl not called]%b\n\n" \
        "$YELLOW" "$new_count" "$RESET"
    cat "$tmp_adif"
    echo
    printf "  Would run:\n"
    printf "    %s -x -q -d -c %s -l \"%s\" <tempfile.adi>\n\n" \
        "$TQSL_BIN" "$station_call" "$station_loc"
    exit 0
fi

printf "\n  Uploading %d QSO(s) as %b%s%b...\n\n" \
    "$new_count" "$BOLD" "$station_call" "$RESET"

"$TQSL_BIN" -x -q -d -c "$station_call" -l "$station_loc" "$tmp_adif"
tqsl_rc=$?

if [ "$tqsl_rc" -eq 0 ]; then
    printf '%d\n' "$total" > "$WM_FILE"
    printf "  %bSuccess.%b Watermark advanced to QSO #%d\n\n" \
        "$GREEN" "$RESET" "$total"
else
    printf "  %bError:%b tqsl exited with code %d — watermark not updated\n\n" \
        "$RED" "$RESET" "$tqsl_rc"
    exit "$tqsl_rc"
fi
