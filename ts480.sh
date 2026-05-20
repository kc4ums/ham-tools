#!/usr/bin/env bash
# Kenwood TS-480HX CAT control — bash + stty only, no other dependencies
#
# CAT serial settings: 9600 8N1, no flow control (TS-480 default)
# Change baud in TS-480 menu: Menu 60 (COM port speed)

MAX_WATTS=200   # TS-480HX; change to 100 for TS-480SAT

show_help() {
    cat << 'EOF'

  Usage: ts480.sh [OPTIONS]

  Live status display and CAT control for the Kenwood TS-480HX.
  Default: polls the rig every 3 seconds and displays status.
  With a --set-* flag: sends that command and exits immediately.

  --port PORT      Serial port (default: /dev/ttyS0)
                   Windows: COM1-COM9 accepted and converted automatically
  --baud N         Baud rate (default: 9600; match Menu 60 on the TS-480)
  --interval N     Status refresh interval in seconds (default: 3)
  --once           Poll once and exit (no auto-refresh)
  --no-color       Plain text output

  One-shot control (sends command, then exits):
  --set-freq FREQ  Set VFO A frequency: kHz (14250) or MHz (14.250)
  --set-mode MODE  Set mode: LSB USB CW CW-R AM FM FSK FSK-R
  --set-power N    Set output power: 0-100 (percentage of max; 100=200W on HX)
  --tune           Start antenna tuner cycle

  --help           Show this help

  TS-480 CAT baud rate is set via Menu 60.  stty must match.

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
port="/dev/ttyS0"
baud=9600
interval=3
once=0
no_color=0
cmd_freq=""
cmd_mode=""
cmd_power=""
do_tune=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)      port="$2";      shift 2;;
        --baud)      baud="$2";      shift 2;;
        --interval)  interval="$2";  shift 2;;
        --once)      once=1;         shift;;
        --set-freq)  cmd_freq="$2";  shift 2;;
        --set-mode)  cmd_mode="${2^^}"; shift 2;;
        --set-power) cmd_power="$2"; shift 2;;
        --tune)      do_tune=1;      shift;;
        --no-color)  shift;;
        *)           shift;;
    esac
done

# Convert Windows-style COM port (COM5 → /dev/ttyS4)
if [[ "$port" =~ ^[Cc][Oo][Mm]([0-9]+)$ ]]; then
    n=$(( ${BASH_REMATCH[1]} - 1 ))
    port="/dev/ttyS${n}"
fi

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'
    CYAN=$'\033[96m';  GRAY=$'\033[90m';   BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="----------------------------------------------------"

# ── Open serial port ───────────────────────────────────────────────────────
if [ ! -e "$port" ]; then
    printf "\n  %bError:%b port %s not found\n" "$BOLD" "$RESET" "$port" >&2
    printf "  Available: %s\n\n" "$(ls /dev/ttyS* 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
fi

# 8N1, raw, no flow control — TS-480 does not use RTS/CTS
stty -F "$port" "$baud" raw cs8 -cstopb -parenb -crtscts -echo 2>/dev/null \
    || stty  -f "$port" "$baud" raw cs8 -cstopb -parenb -crtscts -echo 2>/dev/null \
    || printf "  %bWarning:%b stty failed — port may not be configurable\n" \
              "$BOLD" "$RESET" >&2

exec 3<>"$port"
sleep 0.2   # let port settle after stty

# ── Helpers ────────────────────────────────────────────────────────────────

# Send one CAT command, return response text (without trailing ;)
rig_cmd() {
    local cmd="$1" resp=""
    printf '%s' "${cmd};" >&3
    IFS= read -r -t 2 -d ';' resp <&3 2>/dev/null
    printf '%s' "$resp"
}

# Drain any buffered responses (call before starting fresh queries)
flush_rig() {
    while IFS= read -r -t 0.1 -d ';' _ <&3 2>/dev/null; do :; done
}

# Format 11-digit Hz string → "14.250.000"
fmt_freq() {
    local raw="$1"
    [[ "$raw" =~ ^[0-9]{11}$ ]] || { printf '%-13s' '---'; return; }
    local hz=$(( 10#$raw ))
    local mhz=$(( hz / 1000000 ))
    local khz=$(( (hz % 1000000) / 1000 ))
    local sub=$(( hz % 1000 ))
    printf '%d.%03d.%03d' "$mhz" "$khz" "$sub"
}

# Frequency input (kHz or MHz) → 11-digit Hz string
freq_to_hz11() {
    local f="$1" hz
    if [[ "$f" == *.* ]]; then
        hz=$(awk "BEGIN { printf \"%011.0f\", $f * 1000000 }")
    else
        hz=$(awk "BEGIN { printf \"%011.0f\", $f * 1000 }")
    fi
    printf '%s' "$hz"
}

decode_mode() {
    case "$1" in
        1) echo "LSB";;  2) echo "USB";;  3) echo "CW";;
        4) echo "FM";;   5) echo "AM";;   6) echo "FSK";;
        7) echo "CW-R";; 9) echo "FSK-R";; *) echo "---";;
    esac
}

mode_to_num() {
    case "$1" in
        LSB)         echo "1";; USB)         echo "2";;
        CW|CW-N)     echo "3";; FM)          echo "4";;
        AM)          echo "5";; FSK|RTTY|DIG) echo "6";;
        CW-R)        echo "7";; FSK-R|RTTY-R) echo "9";;
        *) printf "\n  %bError:%b unknown mode '%s'\n\n" \
               "$BOLD" "$RESET" "$1" >&2; exit 1;;
    esac
}

# SM0 raw value (0-30) → S-unit string
decode_smeter() {
    local raw="$1"
    [[ "$raw" =~ ^[0-9]+$ ]] || { echo "---"; return; }
    local v=$(( 10#$raw ))
    if   (( v >= 28 )); then echo "S9+"
    elif (( v >= 24 )); then echo "S9"
    elif (( v >= 21 )); then echo "S8"
    elif (( v >= 18 )); then echo "S7"
    elif (( v >= 15 )); then echo "S6"
    elif (( v >= 12 )); then echo "S5"
    elif (( v >= 9  )); then echo "S4"
    elif (( v >= 6  )); then echo "S3"
    elif (( v >= 3  )); then echo "S2"
    elif (( v >= 1  )); then echo "S1"
    else echo "S0"
    fi
}

smeter_color() {
    case "$1" in
        S9+|S9) printf '%s' "$RED";;
        S8|S7)  printf '%s' "$YELLOW";;
        S6|S5)  printf '%s' "$GREEN";;
        *)      printf '%s' "$GRAY";;
    esac
}

mode_color() {
    case "$1" in
        CW|CW-R)  printf '%s' "$GREEN";;
        LSB|USB)  printf '%s' "$YELLOW";;
        FSK|FSK-R) printf '%s' "$CYAN";;
        *)        printf '%s' "";;
    esac
}

# ── One-shot control commands ──────────────────────────────────────────────
if [ -n "$cmd_freq" ]; then
    hz11=$(freq_to_hz11 "$cmd_freq")
    result=$(rig_cmd "FA${hz11}")
    if [ -z "$result" ]; then
        printf "  %bError:%b no response — check port and baud rate\n" "$BOLD" "$RESET" >&2
        exit 1
    fi
    printf "  VFO A set to %s\n" "$(fmt_freq "${result#FA}")"
    exit 0
fi

if [ -n "$cmd_mode" ]; then
    mnum=$(mode_to_num "$cmd_mode")
    rig_cmd "MD${mnum}" > /dev/null
    printf "  Mode set to %s\n" "$cmd_mode"
    exit 0
fi

if [ -n "$cmd_power" ]; then
    pc=$(printf '%03d' "$cmd_power")
    rig_cmd "PC${pc}" > /dev/null
    watts=$(( cmd_power * MAX_WATTS / 100 ))
    printf "  Power set to %s%% (~%dW)\n" "$cmd_power" "$watts"
    exit 0
fi

if [ "$do_tune" -eq 1 ]; then
    printf "  Starting antenna tuner...\n"
    rig_cmd "AC002" > /dev/null
    exit 0
fi

# ── Status display loop ────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exec 3>&-; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    flush_rig

    # Poll each parameter (individual commands are more reliable than IF;)
    fa_raw=$(rig_cmd "FA");  fa_freq="${fa_raw#FA}"
    fb_raw=$(rig_cmd "FB");  fb_freq="${fb_raw#FB}"
    md_raw=$(rig_cmd "MD");  md_num="${md_raw#MD}"
    sm_raw=$(rig_cmd "SM0"); sm_val="${sm_raw#SM0}"
    pc_raw=$(rig_cmd "PC");  pc_val="${pc_raw#PC}"
    pa_raw=$(rig_cmd "PA0"); pa_val="${pa_raw#PA0}"
    ra_raw=$(rig_cmd "RA");  ra_val="${ra_raw#RA}"
    sp_raw=$(rig_cmd "SP");  sp_val="${sp_raw#SP}"

    updated=$(date "+%H:%M:%S")

    # Decode values
    fa_disp=$(fmt_freq "$fa_freq")
    fb_disp=$(fmt_freq "$fb_freq")
    mode=$(decode_mode "$md_num")
    smeter=$(decode_smeter "$sm_val")
    pc_pct=$(( 10#${pc_val:-0} ))
    pc_watts=$(( pc_pct * MAX_WATTS / 100 ))
    pre=$( [[ "$pa_val" == "1" ]] && echo "On" || echo "Off" )
    att="Off"
    case "$ra_val" in
        01) att="6 dB";; 02) att="12 dB";; 03) att="18 dB";;
    esac
    split=$( [[ "$sp_val" == "1" ]] && echo "On" || echo "Off" )

    mc=$(mode_color "$mode")
    sc=$(smeter_color "$smeter")

    # Display
    echo
    printf "%b  Kenwood TS-480HX%b" "$BOLD" "$RESET"
    [ "$once" -eq 0 ] && printf "  — %s" "$updated"
    echo
    printf "  %s @ %d baud\n" "$port" "$baud"
    echo "$SEP"
    printf "  %b%-7s%b  %s MHz  %b%-6s%b  %b%s%b\n" \
        "$BOLD" "VFO A" "$RESET" \
        "$fa_disp" \
        "$mc" "$mode" "$RESET" \
        "$sc" "$smeter" "$RESET"
    printf "  %b%-7s%b  %s MHz\n" \
        "$GRAY" "VFO B" "$RESET" \
        "$fb_disp"
    echo "$SEP"
    printf "  Power  %3d%%  (~%dW)\n" "$pc_pct" "$pc_watts"
    printf "  ATT    %s\n" "$att"
    printf "  Pre    %s\n" "$pre"
    printf "  Split  %s\n" "$split"
    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done

exec 3>&-
