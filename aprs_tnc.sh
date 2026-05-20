#!/usr/bin/env bash
# APRS monitor via Pakratt 232 TNC — bash + stty only, no other dependencies

show_help() {
    cat << 'EOF'

  Usage: aprs_tnc.sh [OPTIONS]

  Monitor APRS traffic from a Pakratt 232 TNC connected to a serial port.
  Parses both the two-line AEA "Fm/To/Via" monitor format and single-line
  AX.25 format.  Ctrl+C to quit.

  --port PORT   Serial port (default: /dev/ttyS0)
                Windows: COM1–COM9 are accepted and converted automatically
                Examples: /dev/ttyS4  COM5  /dev/ttyUSB0
  --baud N      Host baud rate (default: 9600)
  --init        Send startup commands to put TNC in monitor mode:
                  Ctrl-C → command mode
                  MONITOR ON, MRPT ON, MCON ON
                Skip if TNC is already configured.
  --no-color    Plain text output
  --help        Show this help

  TNC must be in normal terminal mode (not KISS).  For the Pakratt 232,
  the relevant commands are:
    MONITOR ON   — enable packet monitoring
    MRPT ON      — show already-digipeated packets (needed for APRS)
    MCON ON      — also show connected-mode packets

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
port="/dev/ttyS0"
baud=9600
do_init=0
no_color=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)     port="$2";  shift 2;;
        --baud)     baud="$2";  shift 2;;
        --init)     do_init=1;  shift;;
        --no-color) shift;;
        *)          shift;;
    esac
done

# Convert Windows-style COM port (COM3 → /dev/ttyS2)
if [[ "$port" =~ ^[Cc][Oo][Mm]([0-9]+)$ ]]; then
    n=$(( ${BASH_REMATCH[1]} - 1 ))
    port="/dev/ttyS${n}"
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

SEP="----------------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
pkt_type() {
    case "${1:0:1}" in
        '!'|'=') echo "POS";;
        '/'|'@') echo "POS";;
        ':')     echo "MSG";;
        '>')     echo "STAT";;
        'T')     echo "TELEM";;
        '_')     echo "WX";;
        ';')     echo "OBJ";;
        ')')     echo "ITEM";;
        '$')     echo "NMEA";;
        '#'|'*') echo "WX";;
        *)       echo "PKT";;
    esac
}

type_color() {
    case "$1" in
        POS)        printf '%s' "$GREEN";;
        MSG)        printf '%s' "$YELLOW";;
        WX)         printf '%s' "$CYAN";;
        OBJ|ITEM)   printf '%s' "$BLUE";;
        STAT)       printf '%s' "$GRAY";;
        TELEM)      printf '%s' "$MAGENTA";;
        *)          printf '%s' "";;
    esac
}

print_packet() {
    local src="$1" payload="$2"
    local type ts info clr

    type=$(pkt_type "$payload")
    ts=$(date "+%H:%M:%S")
    info="${payload:1}"                          # drop leading type byte
    [ ${#info} -gt 50 ] && info="${info:0:49}…"

    clr=$(type_color "$type")
    printf "  %-9s %-12s %b%-6s%b %s\n" \
        "$ts" "$src" "$clr" "$type" "$RESET" "$info"
}

# ── Open port ──────────────────────────────────────────────────────────────
if [ ! -e "$port" ]; then
    printf "\n  %bError:%b port %s not found\n" "$BOLD" "$RESET" "$port" >&2
    printf "  Available ttyS devices: %s\n\n" \
        "$(ls /dev/ttyS* 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
fi

# Configure port: raw mode, 8N1
stty -F "$port" "$baud" raw cs8 -cstopb -parenb -echo 2>/dev/null \
    || stty  -f "$port" "$baud" raw cs8 -cstopb -parenb -echo 2>/dev/null \
    || printf "  %bWarning:%b stty failed — port may not be configurable\n" \
              "$BOLD" "$RESET" >&2

# ── Optional TNC init ──────────────────────────────────────────────────────
if [ "$do_init" -eq 1 ]; then
    printf "  Sending TNC init... "
    printf '\x03'       > "$port"   # Ctrl-C → command mode
    sleep 1
    printf 'MONITOR ON\r' > "$port"
    sleep 0.3
    printf 'MRPT ON\r'    > "$port"
    sleep 0.3
    printf 'MCON ON\r'    > "$port"
    sleep 0.3
    printf "done\n"
fi

# ── Header ─────────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

echo
printf "%b  APRS Monitor%b — %s @ %d baud\n" "$BOLD" "$RESET" "$port" "$baud"
printf "  Ctrl+C to quit\n"
echo "$SEP"
printf "%b  %-9s %-12s %-6s %s%b\n" "$BOLD" "Time" "Callsign" "Type" "Info" "$RESET"
echo "$SEP"

# ── Packet loop ────────────────────────────────────────────────────────────
# The Pakratt 232 (and most AEA-compatible TNCs) outputs a two-line format
# when HEADERLN is ON (the default):
#
#   Fm N0ABC-9 To APRS Via RELAY*,WIDE <UI>:
#   !3456.78N/09823.45W>test
#
# Some TNCs or settings produce single-line AX.25 format:
#   N0ABC-9>APRS,RELAY*,WIDE:!3456.78N/09823.45W>test

pending_src=""

while IFS= read -r raw; do
    # Strip CR (serial ports send CRLF)
    line="${raw%$'\r'}"

    # Skip blank lines and TNC command-mode prompts
    [ -z "$line" ] && continue
    [[ "$line" == "cmd:"*  ]] && continue
    [[ "$line" == "Cmd:"*  ]] && continue
    [[ "$line" == "***"*   ]] && continue
    [[ "$line" == "[Ack]"* ]] && continue

    # ── Two-line AEA format: header line ───────────────────────────────────
    # "Fm N0ABC-9 To APRS Via RELAY*,WIDE <UI>:" (colon optional at end)
    # Also handles "[Fm N0ABC To APRS Via ...]" bracket variant
    clean="${line#[}"               # strip optional leading [
    if [[ "$clean" =~ ^[Ff]m\ +([A-Z0-9/-]+)\ +[Tt]o\ +([A-Z0-9/-]+) ]]; then
        pending_src="${BASH_REMATCH[1]}"
        continue
    fi

    # ── Two-line AEA format: payload line after a header ───────────────────
    if [ -n "$pending_src" ]; then
        # Any non-empty, non-status line following a header is the payload
        print_packet "$pending_src" "$line"
        pending_src=""
        continue
    fi

    # ── Single-line AX.25 format: CALL>DEST,...:payload ────────────────────
    if [[ "$line" =~ ^([A-Z0-9]+-?[0-9]*)\> ]]; then
        src="${BASH_REMATCH[1]}"
        payload="${line#*:}"
        [ -z "$payload" ] && continue
        print_packet "$src" "$payload"
        continue
    fi

    # Anything else: unknown / TNC status — ignore silently
done < "$port"
