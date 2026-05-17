#!/usr/bin/env bash
# QRZ callsign lookup — bash + curl/wget only, no other dependencies
# Requires a QRZ account: https://www.qrz.com
# Set credentials: export QRZ_USER=yourcall  QRZ_PASS=yourpassword

QRZ_URL="https://xmldata.qrz.com/xml/current/"

show_help() {
    cat << 'EOF'

  Usage: qrz_lookup.sh [--no-color] CALLSIGN

  Look up a callsign via the QRZ XML API.

  Credentials (required):
    export QRZ_USER=yourcall
    export QRZ_PASS=yourpassword

  --no-color    Plain text output
  --help        Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
CALLSIGN=""
no_color=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-color) shift;;
        -*)         shift;;
        *)          CALLSIGN="${1^^}"; shift;;
    esac
done

if [ -z "$CALLSIGN" ]; then
    printf "Usage: %s [--no-color] CALLSIGN\n" "$(basename "$0")" >&2
    printf "  Credentials: export QRZ_USER=yourcall  QRZ_PASS=yourpassword\n" >&2
    exit 1
fi

if [ -z "$QRZ_USER" ] || [ -z "$QRZ_PASS" ]; then
    printf "Error: QRZ_USER and QRZ_PASS environment variables must be set\n" >&2
    printf "  export QRZ_USER=yourcall\n" >&2
    printf "  export QRZ_PASS=yourpassword\n" >&2
    exit 1
fi

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="----------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$url"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

# Extract content of a simple XML tag (first match)
xml_get() {
    local tag="$1" xml="$2"
    printf '%s' "$xml" | grep -oE "<${tag}>[^<]+" | sed "s|<${tag}>||" | head -1
}

class_label() {
    case "$1" in
        E) echo "Amateur Extra";;
        G) echo "General";;
        T) echo "Technician";;
        N) echo "Novice";;
        A) echo "Advanced";;
        *) echo "$1";;
    esac
}

# ── Login — get session key ─────────────────────────────────────────────────
session_xml=$(fetch "${QRZ_URL}?username=${QRZ_USER}&password=${QRZ_PASS}&agent=ham-tools")

if [ -z "$session_xml" ]; then
    printf "Error: no response from QRZ\n" >&2; exit 1
fi

session_error=$(xml_get "Error" "$session_xml")
if [ -n "$session_error" ]; then
    printf "QRZ login error: %s\n" "$session_error" >&2; exit 1
fi

session_key=$(xml_get "Key" "$session_xml")
if [ -z "$session_key" ]; then
    printf "Error: could not obtain session key\n" >&2; exit 1
fi

# ── Lookup callsign ────────────────────────────────────────────────────────
lookup_xml=$(fetch "${QRZ_URL}?s=${session_key}&callsign=${CALLSIGN}")

if [ -z "$lookup_xml" ]; then
    printf "Error: no response from QRZ\n" >&2; exit 1
fi

lookup_error=$(xml_get "Error" "$lookup_xml")
if [ -n "$lookup_error" ]; then
    printf "QRZ error: %s\n" "$lookup_error" >&2; exit 1
fi

# ── Parse fields ───────────────────────────────────────────────────────────
call=$(xml_get "call"    "$lookup_xml")
fname=$(xml_get "fname"  "$lookup_xml")
lname=$(xml_get "name"   "$lookup_xml")
addr1=$(xml_get "addr1"  "$lookup_xml")
city=$( xml_get "addr2"  "$lookup_xml")
state=$(xml_get "state"  "$lookup_xml")
zip=$(  xml_get "zip"    "$lookup_xml")
country=$(xml_get "country" "$lookup_xml")
grid=$(  xml_get "grid"  "$lookup_xml")
county=$(xml_get "county" "$lookup_xml")
class=$( xml_get "class" "$lookup_xml")
email=$( xml_get "email" "$lookup_xml")
aliases=$(xml_get "aliases" "$lookup_xml")
lat=$(   xml_get "lat"   "$lookup_xml")
lon=$(   xml_get "lon"   "$lookup_xml")
dxcc=$(  xml_get "dxcc"  "$lookup_xml")

if [ -z "$call" ]; then
    printf "Callsign not found: %s\n" "$CALLSIGN" >&2; exit 1
fi

# ── Display ────────────────────────────────────────────────────────────────
fullname="${fname} ${lname}"
location="${city}"
[ -n "$state"   ] && location="${location}, ${state}"
[ -n "$zip"     ] && location="${location} ${zip}"
[ -n "$country" ] && location="${location}  ${country}"

echo
printf "%b  %-10s%b %s\n" "$BOLD" "$call" "$RESET" "$fullname"
echo "$SEP"

row() {
    local label="$1" value="$2" color="$3"
    [ -z "$value" ] && return
    printf "  %-18s %b%s%b\n" "$label" "$color" "$value" "$RESET"
}

row "License Class"   "$(class_label "$class")"  "$GREEN"
row "Address"         "$addr1"                   ""
row "Location"        "$location"                ""
row "County"          "$county"                  ""
row "Grid Square"     "$grid"                    "$YELLOW"
row "Coordinates"     "${lat}, ${lon}"           "$GRAY"
row "DXCC Entity"     "$dxcc"                    ""
row "Email"           "$email"                   "$GRAY"
row "Aliases"         "$aliases"                 "$GRAY"

echo "$SEP"
echo
