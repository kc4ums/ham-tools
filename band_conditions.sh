#!/usr/bin/env bash
# Ham band conditions — bash + curl/wget only, no other dependencies

URL="https://www.hamqsl.com/solarxml.php"

show_help() {
    cat << 'EOF'

  Usage: band_conditions.sh [--no-color] [--help]

  Show current HF band conditions and solar data from hamqsl.com.

  --no-color    Plain text output (auto-set when not a TTY)
  --help        Show this help

EOF
}
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }

# Fetch XML — try curl, fall back to wget
if command -v curl >/dev/null 2>&1; then
    xml=$(curl -sk --max-time 15 "$URL") || { echo "Fetch failed" >&2; exit 1; }
elif command -v wget >/dev/null 2>&1; then
    xml=$(wget -qO- --no-check-certificate --timeout=15 "$URL") || { echo "Fetch failed" >&2; exit 1; }
else
    echo "Error: curl or wget is required" >&2; exit 1
fi

[ -z "$xml" ] && { echo "Error: empty response" >&2; exit 1; }

# Extract text content of a simple XML tag (strips surrounding whitespace)
get() {
    printf '%s' "$xml" | grep -oE "<${1}>[^<]+" | sed "s|<${1}>||;s/^[[:space:]]*//;s/[[:space:]]*$//" | head -1
}

# Extract a band condition (e.g. name="80m-40m" time="day")
get_band() {
    printf '%s' "$xml" | grep -oE "<band name=\"${1}\" time=\"${2}\">[^<]+" | sed 's|.*>||'
}

# K-index plain-English description
k_label() {
    case "$1" in
        0) echo "Inactive";;       1) echo "Very Quiet";;
        2) echo "Quiet";;          3) echo "Unsettled";;
        4) echo "Active";;         5) echo "Minor Storm";;
        6) echo "Major Storm";;    7) echo "Severe Storm";;
        8) echo "Very Severe";;    9) echo "Extremely Severe";;
        *) echo "";;
    esac
}

# Color setup — only when writing to a terminal and not suppressed
if [ -t 1 ] && [ "${1}" != "--no-color" ]; then
    GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'
    GRAY='\033[90m';  BOLD='\033[1m';    RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; GRAY=''; BOLD=''; RESET=''
fi

# Print a condition word in color, then pad to a fixed visual width
cond_col() {
    local val="$1" width="$2" clr=""
    case "$val" in
        Good)   clr="$GREEN";;   Fair)   clr="$YELLOW";;
        Poor)   clr="$RED";;     Closed) clr="$GRAY";;
    esac
    printf "%b%s%b" "$clr" "$val" "$RESET"
    local pad=$((width - ${#val}))
    [ "$pad" -gt 0 ] && printf "%${pad}s" ""
}

SEP="----------------------------------------------------"

updated=$(get updated)
sfi=$(get solarflux)
sunspots=$(get sunspots)
xray=$(get xray)
aindex=$(get aindex)
kindex=$(get kindex)
geomagfield=$(get geomagfield)
signalnoise=$(get signalnoise)
aurora=$(get aurora)
kdesc=$(k_label "$kindex")

echo
printf "%b  Ham Band Conditions%b\n" "$BOLD" "$RESET"
printf "  %s\n" "$updated"
echo "$SEP"
printf "  %-28s %s\n" "Solar Flux (SFI)"  "$sfi"
printf "  %-28s %s\n" "Sunspot Number"    "$sunspots"
printf "  %-28s %s\n" "X-Ray Flux"        "$xray"
printf "  %-28s %s\n" "A-Index"           "$aindex"
printf "  %-28s %s" "K-Index" "$kindex"
[ -n "$kdesc" ] && printf "  (%s)" "$kdesc"
printf "\n"
printf "  %-28s %s\n" "Geomag Field"      "$geomagfield"
printf "  %-28s %s\n" "Signal Noise"      "$signalnoise"
printf "  %-28s %s\n" "Aurora"            "$aurora"
echo "$SEP"
printf "%b  %-12s %-18s %s%b\n" "$BOLD" "Band" "Day" "Night" "$RESET"
echo "$SEP"

for band in "80m-40m" "30m-20m" "17m-15m" "12m-10m"; do
    day=$(get_band "$band" "day")
    night=$(get_band "$band" "night")
    printf "  %-12s " "$band"
    cond_col "$day"   18
    cond_col "$night"  0
    printf "\n"
done

echo "$SEP"
echo
