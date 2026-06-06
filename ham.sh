#!/usr/bin/env bash
# ham-tools launcher

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ─────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    GRAY=$'\033[90m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GRAY=''; BOLD=''; RESET=''
fi

SEP="----------------------------------------------------"

# ── Helpers ────────────────────────────────────────────────────────────────
run() {
    local script="$SCRIPT_DIR/$1"; shift
    [ -f "$script" ] || { printf "  Error: %s not found\n" "$script" >&2; return 1; }
    bash "$script" "$@"
}

pause() {
    printf "\n%b  Press any key to return to menu...%b\n" "$GRAY" "$RESET"
    read -r -n1 -s
}

# Intercept Ctrl+C in the launcher so the menu survives it.
# trap '' INT would set SIG_IGN which children inherit and can't override.
# trap 'true' INT runs a no-op handler instead — children get SIG_DFL and
# can set their own traps normally.
trap 'true' INT

# ── Logbook sub-menu ───────────────────────────────────────────────────────
logbook_menu() {
    while true; do
        clear
        echo
        printf "%b  Logbook%b\n" "$BOLD" "$RESET"
        echo "$SEP"
        printf "  %b1%b  View recent QSOs\n" "$BOLD" "$RESET"
        printf "  %b2%b  Add new QSO\n"      "$BOLD" "$RESET"
        printf "  %b3%b  Search by callsign\n" "$BOLD" "$RESET"
        printf "  %b4%b  Stats\n"             "$BOLD" "$RESET"
        echo "$SEP"
        printf "  [1-4  b=back]: "
        read -r -n1 sub; echo

        case "$sub" in
            1) run "logbook.sh";               pause;;
            2) run "logbook.sh" --add;;
            3)
                printf "\n  Search callsign: "
                read -e -r call
                [ -n "$call" ] && { run "logbook.sh" --search "$call"; pause; }
                ;;
            4) run "logbook.sh" --stats;       pause;;
            b|B|q|Q) return;;
        esac
    done
}

# ── Main menu ──────────────────────────────────────────────────────────────
while true; do
    clear
    echo
    printf "%b  ham-tools%b\n" "$BOLD" "$RESET"
    echo "$SEP"
    printf "  %b1%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Band Conditions"  "$GRAY" "solar data & HF band conditions"   "$RESET"
    printf "  %b2%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "POTA Spots"       "$GRAY" "live POTA activators on the air"   "$RESET"
    printf "  %b3%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "DX Cluster"       "$GRAY" "live DX spots from dxwatch.com"    "$RESET"
    printf "  %b4%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Solar Forecast"   "$GRAY" "NOAA 27-day solar outlook"         "$RESET"
    printf "  %b5%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "QRZ Lookup"       "$GRAY" "callsign lookup via QRZ XML API"   "$RESET"
    printf "  %b6%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Contest Calendar" "$GRAY" "upcoming ham radio contests"       "$RESET"
    printf "  %b7%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "WSPR Spots"       "$GRAY" "propagation spots from wspr.live"  "$RESET"
    printf "  %b8%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Logbook"          "$GRAY" "local QSO logger"                  "$RESET"
    printf "  %b9%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Weather"          "$GRAY" "current conditions & 10-day forecast" "$RESET"
    printf "  %ba%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "SOTA Spots"       "$GRAY" "recent SOTA activator spots"          "$RESET"
    printf "  %bb%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "PSK Reporter"     "$GRAY" "who's hearing your callsign"          "$RESET"
    printf "  %bc%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "APRS TNC"         "$GRAY" "live APRS via Pakratt 232 serial TNC" "$RESET"
    printf "  %bd%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "TS-480 CAT"       "$GRAY" "Kenwood TS-480HX rig control"         "$RESET"
    printf "  %be%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "Sat Passes"       "$GRAY" "upcoming amateur satellite passes"    "$RESET"
    printf "  %bf%b  %-20s %s%s%s\n" "$BOLD" "$RESET" "FT8 Activity Map" "$GRAY" "unique TX stations per band"          "$RESET"
    echo "$SEP"
    printf "  [1-9  a-f  q=quit]: "
    read -r -n1 choice; echo

    case "$choice" in
        1) run "band_conditions.sh";    pause;;
        2) run "pota_spots.sh";;
        3) run "dx_cluster.sh";;
        4) run "solar_forecast.sh";;
        5)
            printf "\n  Callsign: "
            read -e -r call
            [ -n "$call" ] && { run "qrz_lookup.sh" "$call"; pause; }
            ;;
        6) run "contest_calendar.sh";;
        7) run "wspr_spots.sh";;
        8) logbook_menu;;
        9) run "weather.sh" ${HAM_WEATHER_LOC:+"$HAM_WEATHER_LOC"};;
        a|A) run "sota_spots.sh";;
        b|B)
            if [ -n "${HAM_CALL:-}" ]; then
                run "psk_reporter.sh" --call "$HAM_CALL"
            else
                printf "\n  Callsign: "
                read -e -r call
                [ -n "$call" ] && run "psk_reporter.sh" --call "$call"
            fi
            ;;
        c|C)
            printf "\n  Serial port [/dev/ttyS0]: "
            read -e -r tnc_port
            tnc_port="${tnc_port:-/dev/ttyS0}"
            run "aprs_tnc.sh" --port "$tnc_port"
            ;;
        d|D)
            printf "\n  Serial port [/dev/ttyS0]: "
            read -e -r rig_port
            rig_port="${rig_port:-/dev/ttyS0}"
            run "ts480.sh" --port "$rig_port"
            ;;
        e|E)
            printf "\n  Satellite [ISS]: "
            read -e -r sat
            sat="${sat:-ISS}"
            if [ -n "${HAM_LAT:-}" ] && [ -n "${HAM_LON:-}" ]; then
                run "sat_passes.sh" --sat "$sat"
            else
                printf "  Latitude: "; read -e -r sat_lat
                printf "  Longitude: "; read -e -r sat_lon
                run "sat_passes.sh" --sat "$sat" --lat "$sat_lat" --lon "$sat_lon"
            fi
            ;;
        f|F) run "ft8_map.sh";;
        q|Q) clear; exit 0;;
    esac
done
