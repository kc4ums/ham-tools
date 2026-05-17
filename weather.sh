#!/usr/bin/env bash
# Current weather and 10-day forecast — bash + curl/wget only, no other dependencies
# Data: Open-Meteo (open-meteo.com) — free, no API key required

# grep -P requires a UTF-8 locale; set one if the environment hasn't
export LANG="${LANG:-en_US.UTF-8}"

GEO_URL="https://geocoding-api.open-meteo.com/v1/search"
WX_URL="https://api.open-meteo.com/v1/forecast"

show_help() {
    cat << 'EOF'

  Usage: weather.sh [OPTIONS] [LOCATION]

  Current conditions and 10-day forecast from Open-Meteo (no API key needed).
  Refreshes every 30 minutes. Press any key to refresh immediately.

  LOCATION       City name or "City, State"  (e.g. "Tifton" or "Tifton, GA")
                 Omit to use --lat/--lon or be prompted

  --lat LAT      Latitude  (decimal degrees)
  --lon LON      Longitude (decimal degrees)
  --units F|C    Temperature units: F=Fahrenheit (default), C=Celsius
  --interval N   Refresh every N seconds  (default: 1800)
  --once         Fetch once and exit
  --no-color     Plain text output
  --help         Show this help

EOF
}

# ── Args ───────────────────────────────────────────────────────────────────
[[ " $* " == *"--help"* ]] && { show_help; exit 0; }
location=""
lat=""
lon=""
units="F"
no_color=0
interval=1800
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lat)      lat="$2";          shift 2;;
        --lon)      lon="$2";          shift 2;;
        --units)    units="${2^^}";    shift 2;;
        --interval) interval="$2";    shift 2;;
        --once)     once=1;           shift;;
        --no-color) shift;;
        -*)         shift;;
        *)          location="$1";    shift;;
    esac
done

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'
    BLUE=$'\033[94m';  CYAN=$'\033[96m';   GRAY=$'\033[90m'
    BOLD=$'\033[1m';   RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; CYAN=''; GRAY=''; BOLD=''; RESET=''
fi

SEP="--------------------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$1"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}

# 0-indexed element from a flat JSON array string like [1,2,3] or ["a","b"]
arr_get() {
    printf '%s' "$1" | tr ',' '\n' | tr -d '[]"' | sed -n "$((${2}+1))p" | tr -d ' \r'
}

round() { printf "%.0f" "${1:-0}" 2>/dev/null || echo "0"; }

dow() {
    date -d "$1" "+%a %b %d" 2>/dev/null \
    || date -j -f "%Y-%m-%d" "$1" "+%a %b %d" 2>/dev/null \
    || echo "$1"
}

wind_dir() {
    local d="${1%%.*}"
    [[ "$d" =~ ^[0-9]+$ ]] || { echo ""; return; }
    local dirs=(N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW)
    echo "${dirs[$(( (d + 11) / 22 % 16 ))]}"
}

wcode_desc() {
    case "$1" in
        0)        echo "Clear Sky";;
        1)        echo "Mainly Clear";;
        2)        echo "Partly Cloudy";;
        3)        echo "Overcast";;
        45|48)    echo "Fog";;
        51|53|55) echo "Drizzle";;
        61)       echo "Light Rain";;
        63)       echo "Rain";;
        65)       echo "Heavy Rain";;
        71)       echo "Light Snow";;
        73)       echo "Snow";;
        75)       echo "Heavy Snow";;
        77)       echo "Snow Grains";;
        80)       echo "Light Showers";;
        81)       echo "Showers";;
        82)       echo "Heavy Showers";;
        85|86)    echo "Snow Showers";;
        95)       echo "Thunderstorm";;
        96|99)    echo "Thunderstorm/Hail";;
        *)        echo "—";;
    esac
}

wcode_color() {
    case "$1" in
        0|1)                         printf '%s' "$GREEN";;
        2|3|45|48)                   printf '%s' "$GRAY";;
        51|53|55|61|63|65|80|81|82)  printf '%s' "$BLUE";;
        71|73|75|77|85|86)           printf '%s' "$CYAN";;
        95|96|99)                    printf '%s' "$YELLOW";;
        *)                           printf '%s' "$RESET";;
    esac
}

# ── Geocode (runs once before the loop) ────────────────────────────────────
geo_label=""

if [ -n "$lat" ] && [ -n "$lon" ]; then
    geo_label="$(printf '%.4f, %.4f' "$lat" "$lon")"
else
    if [ -z "$location" ]; then
        [ -t 0 ] || { printf "Error: provide LOCATION or --lat/--lon\n" >&2; exit 1; }
        echo
        read -e -r -p "  Location (city or 'City, State'): " location
        [ -z "$location" ] && { printf "Error: location required\n" >&2; exit 1; }
    fi

    # Geocoder only accepts a city name — strip ", State" or ", Country" qualifiers
    city_only=$(printf '%s' "$location" | sed 's/,.*//' | sed 's/^ *//; s/ *$//')
    name_enc=$(printf '%s' "$city_only" | sed 's/ /+/g')
    geo_json=$(fetch "${GEO_URL}?name=${name_enc}&count=1&language=en&format=json")

    if [ -z "$geo_json" ]; then
        printf "Error: geocoding failed — check network\n" >&2; exit 1
    fi

    lat=$(printf '%s' "$geo_json" | grep -oP '"latitude":\K[0-9.-]+' | head -1)
    lon=$(printf '%s' "$geo_json" | grep -oP '"longitude":\K[0-9.-]+' | head -1)

    if [ -z "$lat" ] || [ -z "$lon" ]; then
        printf "Error: location not found: %s\n" "$location" >&2; exit 1
    fi

    geo_name=$(printf '%s' "$geo_json"    | grep -oP '"name":"\K[^"]+' | head -1)
    geo_admin=$(printf '%s' "$geo_json"   | grep -oP '"admin1":"\K[^"]+' | head -1)
    geo_country=$(printf '%s' "$geo_json" | grep -oP '"country_code":"\K[^"]+' | head -1)

    geo_label="$geo_name"
    [ -n "$geo_admin" ]   && geo_label="${geo_label}, ${geo_admin}"
    [ -n "$geo_country" ] && geo_label="${geo_label}, ${geo_country}"
fi

# ── Build weather URL ──────────────────────────────────────────────────────
if [ "$units" = "C" ]; then
    temp_unit="celsius"; precip_unit="mm"; speed_unit="kmh"
    temp_sym="°C"; precip_sym="mm"; speed_lbl="km/h"
else
    temp_unit="fahrenheit"; precip_unit="inch"; speed_unit="mph"
    temp_sym="°F"; precip_sym="in"; speed_lbl="mph"
fi

WX_PARAMS="latitude=${lat}&longitude=${lon}"
WX_PARAMS+="&current=temperature_2m,apparent_temperature,relative_humidity_2m"
WX_PARAMS+=",wind_speed_10m,wind_direction_10m,weathercode,precipitation"
WX_PARAMS+="&daily=weathercode,temperature_2m_max,temperature_2m_min"
WX_PARAMS+=",precipitation_sum,wind_speed_10m_max"
WX_PARAMS+="&temperature_unit=${temp_unit}&wind_speed_unit=${speed_unit}"
WX_PARAMS+="&precipitation_unit=${precip_unit}&forecast_days=10&timezone=auto"

# ── Main loop ──────────────────────────────────────────────────────────────
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

today_date=$(date "+%Y-%m-%d")

while true; do
    [ "$once" -eq 0 ] && clear

    json=$(fetch "${WX_URL}?${WX_PARAMS}")
    updated=$(date "+%H:%M:%S")

    if [ -z "$json" ]; then
        printf "\n  %bWeather%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    json_flat=$(printf '%s' "$json" | tr -d '\n\r')

    # ── Current conditions ──────────────────────────────────────────────────
    cur_temp=$(printf '%s' "$json_flat" | grep -oP '"temperature_2m":\K[0-9.-]+'      | head -1)
    cur_feel=$(printf '%s' "$json_flat" | grep -oP '"apparent_temperature":\K[0-9.-]+' | head -1)
    cur_hum=$( printf '%s' "$json_flat" | grep -oP '"relative_humidity_2m":\K[0-9]+'  | head -1)
    cur_wind=$(printf '%s' "$json_flat" | grep -oP '"wind_speed_10m":\K[0-9.-]+'      | head -1)
    cur_wdir=$(printf '%s' "$json_flat" | grep -oP '"wind_direction_10m":\K[0-9.]+'   | head -1)
    cur_code=$(printf '%s' "$json_flat" | grep -oP '"weathercode":\K[0-9]+'           | head -1)
    cur_prec=$(printf '%s' "$json_flat" | grep -oP '"precipitation":\K[0-9.-]+'       | head -1)
    timezone=$(printf '%s' "$json_flat" | grep -oP '"timezone":"?\K[^,"]+' | head -1 | tr -d '"')

    cur_desc=$(wcode_desc "$cur_code")
    cur_clr=$( wcode_color "$cur_code")
    cur_dir=$( wind_dir "$cur_wdir")

    # ── Daily forecast arrays ───────────────────────────────────────────────
    date_arr=$( printf '%s' "$json_flat" | grep -oP '"time":\K\[[^\]]+\]'              | head -1)
    code_arr=$( printf '%s' "$json_flat" | grep -oP '"weathercode":\K\[[^\]]+\]')
    max_arr=$(  printf '%s' "$json_flat" | grep -oP '"temperature_2m_max":\K\[[^\]]+\]')
    min_arr=$(  printf '%s' "$json_flat" | grep -oP '"temperature_2m_min":\K\[[^\]]+\]')
    prec_arr=$( printf '%s' "$json_flat" | grep -oP '"precipitation_sum":\K\[[^\]]+\]')
    wmax_arr=$( printf '%s' "$json_flat" | grep -oP '"wind_speed_10m_max":\K\[[^\]]+\]')

    # ── Display: current ───────────────────────────────────────────────────
    echo
    printf "%b  Weather — %s%b\n" "$BOLD" "$geo_label" "$RESET"
    [ "$once" -eq 0 ] && printf "  %s  (%s)\n" "$updated" "$timezone"
    echo "$SEP"
    printf "  %-16s %s%s%s\n"   "Conditions"   "$cur_clr" "$cur_desc"          "$RESET"
    printf "  %-16s %s%s"       "Temperature"  "$(round "$cur_temp")" "$temp_sym"
    printf "  %s(feels like %s%s)%s\n" "$GRAY" "$(round "$cur_feel")" "$temp_sym" "$RESET"
    printf "  %-16s %s%%\n"     "Humidity"     "$cur_hum"
    printf "  %-16s %s %s"      "Wind"         "$(round "$cur_wind")" "$speed_lbl"
    [ -n "$cur_dir" ] && printf "  %s" "$cur_dir"
    printf "\n"
    if [ "$(printf '%.2f' "${cur_prec:-0}")" != "0.00" ]; then
        printf "  %-16s %s %s\n" "Precipitation" "$(printf '%.2f' "${cur_prec:-0}")" "$precip_sym"
    fi

    # ── Display: 10-day forecast ───────────────────────────────────────────
    echo "$SEP"
    printf "%b  %-14s  %6s  %6s  %7s  %5s  %s%b\n" \
        "$BOLD" "Date" "Hi" "Lo" "Precip" "Wind" "Conditions" "$RESET"
    echo "$SEP"

    for (( i=0; i<10; i++ )); do
        d=$(   arr_get "$date_arr" $i)
        code=$(arr_get "$code_arr" $i)
        hi=$(  round "$(arr_get "$max_arr"  $i)")
        lo=$(  round "$(arr_get "$min_arr"  $i)")
        pr=$(  printf "%.2f" "$(arr_get "$prec_arr" $i)")
        wd=$(  round "$(arr_get "$wmax_arr" $i)")
        desc=$(wcode_desc "$code")
        clr=$( wcode_color "$code")

        [ -z "$d" ] && continue

        if [ "$d" = "$today_date" ]; then
            day_str="Today"
        else
            day_str=$(dow "$d")
        fi

        printf "  %-14s  %3s%-3s  %3s%-3s  %5s%-2s  %4s%-5s  %s%s%s\n" \
            "$day_str" \
            "$hi" "$temp_sym"  "$lo" "$temp_sym" \
            "$pr" "$precip_sym" \
            "$wd" "$speed_lbl" \
            "$clr" "$desc" "$RESET"
    done

    echo "$SEP"
    echo

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — press any key to refresh, Ctrl+C to quit\n\n" "$interval"
    read -r -n1 -t "$interval" _ 2>/dev/null || true
done
