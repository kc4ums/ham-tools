#!/usr/bin/env bash
# SDR voice receiver — RTL-SDR via rtl_fm + aplay (built for Arduino UNO Q / any Linux)
#
# Exception to the no-installs rule: needs the distro's rtl-sdr and alsa-utils
# packages (rtl_fm, aplay).  On the UNO Q (Debian):
#     sudo apt install rtl-sdr alsa-utils

show_help() {
    cat << 'EOF'

  Usage: sdr_listen.sh --freq MHZ [OPTIONS]

  Listen to FM / AM / SSB voice with an RTL-SDR dongle.  Ctrl+C to quit.

  --freq F       Frequency in MHz (e.g. 146.52).  Give a comma list or repeat
                 --freq to scan; scanning stops on the first channel that
                 breaks squelch and resumes when it drops.
                 Presets: 2m (146.52 calling), noaa (162.400-162.550),
                          air (121.5 guard), marine (156.8 ch16)
  --mode M       fm | wbfm | am | usb | lsb   (default: fm, or preset's mode)
  --gain N       Tuner gain in dB, or "auto" (default: auto)
  --squelch N    Squelch level, 0 = open (default: 0; 30 when scanning)
  --ppm N        Frequency correction in ppm (default: 0)
  --hf           Direct sampling for HF on RTL-SDR v3 (not needed on v4)
  --device N     RTL-SDR device index (default: 0)
  --audio DEV    ALSA output device for aplay (e.g. plughw:1,0); see aplay -L
  --no-color     Plain text output
  --help         Show this help

  Examples:
    sdr_listen.sh --freq 146.94
    sdr_listen.sh --freq 146.52,146.94,147.06 --squelch 40
    sdr_listen.sh --freq noaa
    sdr_listen.sh --freq 99.1 --mode wbfm
    sdr_listen.sh --freq 7.200 --mode lsb --hf

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *" --help "* ]] && { show_help; exit 0; }

no_color=0
freqs=()
mode=""
gain="auto"
squelch=""
ppm=0
hf=0
device=0
audio=""

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --freq)     IFS=',' read -r -a _f <<< "$2"; freqs+=("${_f[@]}"); shift 2;;
        --mode)     mode="${2,,}";   shift 2;;   # ,, = lowercase
        --gain)     gain="$2";       shift 2;;
        --squelch)  squelch="$2";    shift 2;;
        --ppm)      ppm="$2";        shift 2;;
        --hf)       hf=1;            shift;;
        --device)   device="$2";     shift 2;;
        --audio)    audio="$2";      shift 2;;
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

SEP="----------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
die() { printf "\n  %bError:%b %s\n\n" "$RED" "$RESET" "$1" >&2; exit 1; }

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

# Band label for MHz input — HF bands via get_band (kHz), plus VHF/UHF
band_label() {
    local khz
    khz=$(awk -v m="$1" 'BEGIN { printf "%d", m * 1000 }')
    local b; b=$(get_band "$khz")
    if [ "$b" = "Other" ]; then
        if   (( khz >= 88000  && khz <= 108000 )); then b="FM bcast"
        elif (( khz >= 108000 && khz <= 137000 )); then b="Airband"
        elif (( khz >= 144000 && khz <= 148000 )); then b="2m"
        elif (( khz >= 156000 && khz <= 162025 )); then b="Marine"
        elif (( khz >= 162400 && khz <= 162550 )); then b="NOAA WX"
        elif (( khz >= 222000 && khz <= 225000 )); then b="1.25m"
        elif (( khz >= 420000 && khz <= 450000 )); then b="70cm"
        fi
    fi
    echo "$b"
}

mode_color() {
    case "$1" in
        fm|wbfm) printf '%s' "$MAGENTA";;
        usb|lsb) printf '%s' "$YELLOW";;
        am)      printf '%s' "$CYAN";;
        *)       printf '%s' "$RESET";;
    esac
}

# ── Presets ────────────────────────────────────────────────────────────────
expanded=()
for f in "${freqs[@]}"; do
    case "${f,,}" in
        2m)     expanded+=(146.52);                                        : "${mode:=fm}";;
        noaa)   expanded+=(162.400 162.425 162.450 162.475 162.500 162.525 162.550)
                : "${mode:=fm}"; : "${squelch:=30}";;
        air)    expanded+=(121.5);                                         : "${mode:=am}";;
        marine) expanded+=(156.8);                                         : "${mode:=fm}";;
        *)      expanded+=("${f%[Mm]}");;   # allow "146.52M"
    esac
done
freqs=("${expanded[@]}")
mode="${mode:-fm}"

# ── Validate ───────────────────────────────────────────────────────────────
[ "${#freqs[@]}" -eq 0 ] && { show_help; exit 1; }

for f in "${freqs[@]}"; do
    [[ "$f" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "bad frequency '$f' (use MHz, e.g. 146.52)"
done

case "$mode" in
    fm|wbfm|am|usb|lsb) ;;
    *) die "unknown mode '$mode' (fm, wbfm, am, usb, lsb)";;
esac

[ "${#freqs[@]}" -gt 1 ] && [ -z "$squelch" ] && squelch=30
squelch="${squelch:-0}"
[ "${#freqs[@]}" -gt 1 ] && [ "$squelch" -eq 0 ] && die "scanning needs --squelch above 0"
[ "${#freqs[@]}" -gt 1 ] && [ "$mode" = "wbfm" ] && die "wbfm cannot scan; give one frequency"

command -v rtl_fm >/dev/null 2>&1 || die "rtl_fm not found — sudo apt install rtl-sdr"
command -v aplay  >/dev/null 2>&1 || die "aplay not found — sudo apt install alsa-utils"

# ── Build rtl_fm command ───────────────────────────────────────────────────
RATE=48000
cmd=(rtl_fm -d "$device" -p "$ppm")

for f in "${freqs[@]}"; do cmd+=(-f "${f}M"); done

case "$mode" in
    fm)      cmd+=(-M fm  -s 12k);;
    wbfm)    cmd+=(-M wbfm -s 170k -A fast -E deemp);;
    am)      cmd+=(-M am  -s 12k);;
    usb|lsb) cmd+=(-M "$mode" -s 12k);;
esac

# -l and -r must follow -M: "-M wbfm" resets output rate to 32k and squelch to 0
cmd+=(-l "$squelch" -r "$RATE")
[ "$gain" != "auto" ] && cmd+=(-g "$gain")
[ "$hf" -eq 1 ]       && cmd+=(-E direct2)

play=(aplay -q -r "$RATE" -f S16_LE -t raw -c 1)
[ -n "$audio" ] && play+=(-D "$audio")

# ── Main ───────────────────────────────────────────────────────────────────
log=$(mktemp "${TMPDIR:-/tmp}/sdr_listen.XXXXXX")
trap 'rm -f "$log"; printf "\n  Stopped.\n\n"; exit 0' INT TERM

clr=$(mode_color "$mode")

echo
printf "%b  SDR Listen%b\n" "$BOLD" "$RESET"
printf "  %s\n" "$(date "+%Y-%m-%d %H:%M:%S")"
echo "$SEP"
printf "%b  %-12s %-10s %s%b\n" "$BOLD" "FREQ (MHz)" "BAND" "MODE" "$RESET"
echo "$SEP"
for f in "${freqs[@]}"; do
    printf "  %-12s %-10s %b%s%b\n" "$f" "$(band_label "$f")" "$clr" "${mode^^}" "$RESET"
done
echo "$SEP"
printf "  %bGain%b %-6s %bSquelch%b %-4s %bPPM%b %-4s %bDev%b %s%s\n" \
    "$GRAY" "$RESET" "$gain" "$GRAY" "$RESET" "$squelch" \
    "$GRAY" "$RESET" "$ppm" "$GRAY" "$RESET" "$device" \
    "$( [ "$hf" -eq 1 ] && printf '  HF direct' )"
[ "${#freqs[@]}" -gt 1 ] && printf "  %bScanning %d channels%b\n" "$GREEN" "${#freqs[@]}" "$RESET"
echo "$SEP"
printf "  Listening — Ctrl+C to quit\n\n"

"${cmd[@]}" 2>"$log" | "${play[@]}" 2>>"$log"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
    printf "  %brtl_fm exited (%d):%b\n" "$RED" "$status" "$RESET"
    tail -n 8 "$log" | sed 's/^/    /'
    if grep -qi "usb_claim_interface\|kernel driver" "$log"; then
        printf "\n  The DVB-T kernel driver has the dongle.  Fix once with:\n"
        printf "    echo 'blacklist dvb_usb_rtl28xxu' | sudo tee /etc/modprobe.d/rtlsdr.conf\n"
        printf "    sudo modprobe -r dvb_usb_rtl28xxu\n"
    fi
    if grep -qi "No supported devices" "$log"; then
        printf "\n  No RTL-SDR found — check the hub/cable and run: rtl_test -t\n"
    fi
    echo
fi

rm -f "$log"
exit "$status"
