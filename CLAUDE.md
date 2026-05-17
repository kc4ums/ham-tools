# ham-tools

Console-only ham radio utilities. Each script is a single self-contained bash file with no external dependencies beyond `curl` or `wget`.

## Philosophy

- **No installs.** Only bash builtins + `curl`/`wget` + standard POSIX tools (`grep`, `sed`, `awk`, `tr`, `date`).
- **Console only.** No GUI, no TUI libraries. Plain `printf` output with ANSI color.
- **One file per tool.** Everything in a single `.sh` — no sourced libs, no helper files.
- **Auto-refresh by default** for live-data tools (default 300s). Single-run with `--once`.

---

## Script structure (section order)

```
#!/usr/bin/env bash
# <Tool name> — bash + curl/wget only, no other dependencies

URL="..."          # one constant at the top if there's a single endpoint

# ── Args ───────────────────────────
# ── Colors ─────────────────────────
# ── Helpers ────────────────────────
# ── Main loop ──────────────────────
```

---

## Args

Pre-scan `"$@"` for `--no-color` (needed before color setup), then do a full parse with `while/case/shift`.

```bash
no_color=0
interval=300   # default for live-data tools; omit for one-shot tools
once=0

for arg in "$@"; do [[ "$arg" == "--no-color" ]] && no_color=1; done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --foo)      foo_var="${2^^}"; shift 2;;   # ^^  = uppercase
        --bar)      bar_var="$2";    shift 2;;
        --once)     once=1;          shift;;
        --interval) interval="$2";   shift 2;;
        --no-color) shift;;
        *)          shift;;
    esac
done
```

**Standard flags every live-data tool supports:**

| Flag | Meaning |
|---|---|
| `--interval N` | Refresh every N seconds (default 300) |
| `--once` | Fetch once and exit |
| `--no-color` | Plain output; also auto-set when stdout is not a TTY |

Tool-specific filters (e.g. `--mode`, `--band`) are added on top.

---

## Colors

Use `$'...'` ANSI literals. Assign empty strings when color is off so every `%b` / `printf` call still works without branching.

```bash
if [ -t 1 ] && [ "$no_color" -eq 0 ]; then
    GREEN=$'\033[92m'; YELLOW=$'\033[93m'; RED=$'\033[91m'
    BLUE=$'\033[94m';  CYAN=$'\033[96m';   MAGENTA=$'\033[95m'
    GRAY=$'\033[90m';  BOLD=$'\033[1m';    RESET=$'\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''; BOLD=''; RESET=''
fi
```

**Inject color in printf with `%b`:**

```bash
printf "%b%-8s%b" "$clr" "$value" "$RESET"
```

**Standard color meanings for ham data:**

| Color | Use |
|---|---|
| GREEN | Good / CW |
| YELLOW | Fair / SSB |
| RED | Poor |
| GRAY | Closed / inactive |
| BLUE | FT8 |
| CYAN | FT4 |
| MAGENTA | FM |

---

## Fetch

Always try `curl` first, fall back to `wget`. Use `-s`/`-k` flags to suppress noise and skip cert errors (common on Windows).

**JSON:**
```bash
fetch_json() {
    if command -v curl >/dev/null 2>&1; then
        curl -sk --max-time 15 "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --no-check-certificate --timeout=15 "$URL"
    else
        echo "Error: curl or wget is required" >&2; return 1
    fi
}
```

**XML:** same pattern, just rename to `fetch_xml`.

---

## Parsing

### XML — `grep -oE` + `sed`

```bash
# Value of a simple tag: <tag>value</tag>
get() {
    printf '%s' "$xml" | grep -oE "<${1}>[^<]+" \
        | sed "s|<${1}>||;s/^[[:space:]]*//;s/[[:space:]]*$//" | head -1
}

# Attributed tag: <band name="80m-40m" time="day">Good</band>
get_band() {
    printf '%s' "$xml" | grep -oE "<band name=\"${1}\" time=\"${2}\">[^<]+" \
        | sed 's|.*>||'
}
```

### JSON — `grep -oP` (Perl regex, available in GNU grep / Git Bash)

Collapse to one line first, then extract `{...}` objects, then pick fields out of each object.

```bash
json_flat=$(printf '%s' "$json" | tr -d '\n\r')
rows=()   # reset with plain assignment — never use declare inside a loop

while IFS= read -r obj; do
    field=$(printf '%s' "$obj" | grep -oP '"fieldname"\s*:\s*"\K[^"]+')
    # for unquoted numbers:
    num=$(printf '%s' "$obj"   | grep -oP '"numfield"\s*:\s*\K[0-9.]+')

    [ -z "$field" ] && continue   # skip malformed objects

    rows+=("${field}	${num}")    # tab-separated; one element per row
done < <(printf '%s' "$json_flat" | grep -oP '\{[^}]+\}')
```

> `grep -oP '\{[^}]+\}'` works as long as field values don't contain `}` — true for all ham API responses seen so far.

### Reading rows back out

```bash
for (( i=0; i<${#rows[@]}; i++ )); do
    IFS=$'\t' read -r field num <<< "${rows[$i]}"
    ...
done
```

---

## Display

Two-space indent on all output lines. Bold headers. Fixed-width columns with `printf` format strings. Separator line sized to match the widest row.

```bash
SEP="----------------------------------------------------"  # size to fit

echo
printf "%b  Tool Title%b\n" "$BOLD" "$RESET"
printf "  subtitle or timestamp\n"
echo "$SEP"
printf "%b  %-COLs %-COLs %s%b\n" "$BOLD" "HEADER1" "HEADER2" "HEADER3" "$RESET"
echo "$SEP"

# rows
printf "  %-12s %b%-8s%b %s\n" "$col1" "$clr" "$col2" "$RESET" "$col3"

echo "$SEP"
echo
```

---

## Main loop

All live-data tools use this pattern. One-shot tools (no auto-refresh) skip the loop entirely.

```bash
trap 'printf "\n  Stopped.\n\n"; exit 0' INT TERM

while true; do
    [ "$once" -eq 0 ] && clear

    data=$(fetch_json)
    updated=$(date "+%H:%M:%S")

    if [ -z "$data" ]; then
        printf "\n  %bTool Name%b  — fetch error at %s\n\n" "$BOLD" "$RESET" "$updated"
        [ "$once" -eq 1 ] && exit 1
        sleep "$interval"
        continue
    fi

    # ... parse ...
    # ... display ...

    [ "$once" -eq 1 ] && break

    printf "  Refreshing in %ds — Ctrl+C to quit\n\n" "$interval"
    sleep "$interval"
done
```

Key rules:
- Reset arrays with `rows=()`, never `declare -a rows=()` inside a loop.
- `[ "$once" -eq 1 ] && break` at the bottom — not `if [ interval -gt 0 ]`.
- Use `clear` (not ANSI escape) for screen clearing.
- Loop control is plain `if/else` + `break`/`continue` — no `&&`/`||` chains involving `continue`.

---

## Frequency → band helper

Reuse this in any tool that deals with frequencies (kHz input):

```bash
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
```

---

## Existing tools

| File | Data source | Refresh |
|---|---|---|
| `band_conditions.sh` | hamqsl.com XML | one-shot |
| `pota_spots.sh` | api.pota.app JSON | 300s loop |
