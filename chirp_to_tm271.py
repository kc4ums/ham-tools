#!/usr/bin/env python3
# Convert a CHIRP-format CSV to an RT-Systems Kenwood TM-271 binary (.TM271) file.
#
# Binary format reverse-engineered from a known-good original.TM271:
#
#   File header  :  94 bytes  (preserved from template, or defaults used)
#   Channel block: 200 × 295 = 59,000 bytes
#     Per-channel record (295 bytes):
#       +0       0x01 flag
#       +1..+4   RX frequency, Hz, LE uint32
#       +5..+8   TX frequency, Hz, LE uint32
#       +9..+11  offset, Hz, LE 3-byte unsigned
#       +12      0x00
#       +13      direction: 0=simplex  1=minus  2=plus
#       +14      0x00
#       +15..+28 name, UTF-16 LE, null-terminated, padded to 14 bytes (max 6 chars)
#       +29..+44 0x00 × 16 (unknown fields)
#       +45      tone mode: 0=off  1=encode
#       +46      encode CTCSS index (1-40); 8 = 88.5 Hz / none
#       +47      decode CTCSS index (1-40); 8 = 88.5 Hz / none
#       +48..+294 0x00 (scan/power/color/unknown)
#   File footer  : 3,489 bytes (preserved from template)

import csv
import os
import struct
import sys
import argparse

# ── Constants ──────────────────────────────────────────────────────────────────

HEADER_SIZE   = 94
CHANNEL_COUNT = 200
RECORD_SIZE   = 295
FOOTER_OFFSET = HEADER_SIZE + CHANNEL_COUNT * RECORD_SIZE   # 59094

BAND_MIN_MHZ = 144.0
BAND_MAX_MHZ = 148.0
MAX_NAME_LEN = 6

# Standard Kenwood CTCSS table (1-indexed, index 8 = 88.5 Hz = "none")
CTCSS_TONES = [
    0.0,                                                                        # 0 (unused)
    67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8,              # 1-10
    97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8,     # 11-20
    136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9, 186.2,    # 21-30
    192.8, 203.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8, 250.3, 254.1,    # 31-40
]
CTCSS_INDEX = {round(f, 1): i for i, f in enumerate(CTCSS_TONES) if i > 0}

DIR_PLUS    = 0x02
DIR_MINUS   = 0x01
DIR_SIMPLEX = 0x00

# ── Record builder ─────────────────────────────────────────────────────────────

def build_record(rx_hz: int, tx_hz: int, off_hz: int, direction: int,
                 name: str, ctcss_hz: float) -> bytes:
    rec = bytearray(RECORD_SIZE)
    rec[0] = 0x01
    struct.pack_into('<I', rec, 1, rx_hz)
    struct.pack_into('<I', rec, 5, tx_hz)
    off3 = struct.pack('<I', off_hz)[:3]
    rec[9:12] = off3
    rec[12] = 0x00
    rec[13] = direction
    rec[14] = 0x00
    # Name: UTF-16 LE, max 6 chars, padded to 14 bytes
    name = name[:MAX_NAME_LEN].upper()
    name_utf16 = name.encode('utf-16-le')
    rec[15 : 15 + len(name_utf16)] = name_utf16
    # CTCSS
    ctcss_key = round(ctcss_hz, 1) if ctcss_hz else 0.0
    if ctcss_key and ctcss_key != 88.5 and ctcss_key in CTCSS_INDEX:
        idx = CTCSS_INDEX[ctcss_key]
        rec[45] = 0x01
        rec[46] = idx
        rec[47] = 0x08  # decode off
    else:
        rec[45] = 0x00
        rec[46] = 0x08
        rec[47] = 0x08
    return bytes(rec)

# ── Converter ──────────────────────────────────────────────────────────────────

def convert(in_path: str, out_path: str, template_path: str, verbose: bool):
    # Load template header + footer
    if template_path and os.path.isfile(template_path):
        tmpl = open(template_path, 'rb').read()
        if len(tmpl) < FOOTER_OFFSET:
            print(f'Warning: template too short ({len(tmpl)} bytes), using default header.',
                  file=sys.stderr)
            header = _default_header()
            footer = b''
        else:
            header = tmpl[:HEADER_SIZE]
            footer = tmpl[FOOTER_OFFSET:]
    else:
        if template_path:
            print(f'Warning: template not found: {template_path} — using default header.',
                  file=sys.stderr)
        header = _default_header()
        footer = b''

    with open(in_path, newline='', encoding='utf-8') as f:
        rows = list(csv.DictReader(f))

    records = []
    skipped = []

    for row in rows:
        name = row.get('Name', '').strip()
        try:
            rx_mhz = float(row['Frequency'])
        except (KeyError, ValueError):
            skipped.append(f'  {name}: missing/invalid frequency')
            continue

        if not (BAND_MIN_MHZ <= rx_mhz <= BAND_MAX_MHZ):
            skipped.append(f'  {name} {rx_mhz:.6f} MHz — out of 2m band, skipped')
            continue

        if len(records) >= CHANNEL_COUNT:
            skipped.append(f'  {name} — channel limit ({CHANNEL_COUNT}) reached, skipped')
            continue

        rx_hz = round(rx_mhz * 1_000_000)
        duplex = row.get('Duplex', '').strip()
        off_mhz = float(row.get('Offset', '0') or '0')

        if duplex == '+':
            tx_hz = rx_hz + round(off_mhz * 1_000_000)
            direction = DIR_PLUS
        elif duplex == '-':
            tx_hz = rx_hz - round(off_mhz * 1_000_000)
            direction = DIR_MINUS
        else:
            tx_hz = rx_hz
            direction = DIR_SIMPLEX
            off_mhz = 0.0

        off_hz = round(abs(off_mhz) * 1_000_000)

        # CTCSS: use rToneFreq if Tone is set
        ctcss_hz = 0.0
        if row.get('Tone', '').strip() == 'Tone':
            try:
                ctcss_hz = float(row.get('rToneFreq', '0') or '0')
            except ValueError:
                pass

        records.append(build_record(rx_hz, tx_hz, off_hz, direction, name, ctcss_hz))

    # Pad with empty records to fill 200 channels
    empty = bytes(RECORD_SIZE)
    while len(records) < CHANNEL_COUNT:
        records.append(empty)

    with open(out_path, 'wb') as f:
        f.write(header)
        for rec in records:
            f.write(rec)
        f.write(footer)

    written = sum(1 for r in records[:len(records)] if r != empty)
    print(f'Wrote {written} channels to {out_path}')
    if skipped:
        print(f'Skipped {len(skipped)}:')
        for s in skipped:
            print(s)

    if verbose:
        print()
        print(f'  {"Ch":>3}  {"Name":<6}  {"RX MHz":<10}  {"Dir":<7}  {"CTCSS":<8}  Comment')
        print(f'  {"--":>3}  {"----":<6}  {"------":<10}  {"---":<7}  {"-----":<8}  -------')
        for i, row in enumerate(rows):
            name = row.get('Name', '').strip()
            freq_s = row.get('Frequency', '')
            try:
                rx_mhz = float(freq_s)
            except ValueError:
                continue
            if not (BAND_MIN_MHZ <= rx_mhz <= BAND_MAX_MHZ):
                continue
            if i >= written:
                break
            dup = row.get('Duplex', '').strip()
            dir_s = {'': 'Simplex', '+': 'Plus', '-': 'Minus'}.get(dup, dup)
            ctcss_s = ''
            if row.get('Tone', '').strip() == 'Tone':
                ctcss_s = row.get('rToneFreq', '') + ' Hz'
            print(f'  {i:>3}  {name[:6]:<6}  {rx_mhz:<10.6f}  {dir_s:<7}  {ctcss_s:<8}  '
                  f'{row.get("Comment","")[:40]}')

def _default_header() -> bytes:
    hdr = bytearray(HEADER_SIZE)
    title = b'^Kenwood TM-271\x00'
    hdr[:len(title)] = title
    model = b'TM271\x00'
    hdr[0x26:0x26+len(model)] = model
    struct.pack_into('<I', hdr, 0x30, HEADER_SIZE)    # channel block offset
    struct.pack_into('<I', hdr, 0x34, CHANNEL_COUNT)  # channel count
    return bytes(hdr)

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description='Convert a CHIRP CSV to an RT-Systems TM-271 binary (.TM271) file.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''\
Examples:
  python chirp_to_tm271.py chirp-files/tifton_to_st_augustine_2m.csv
  python chirp_to_tm271.py chirp-files/tifton_50mi_2m.csv --verbose
  python chirp_to_tm271.py input.csv --template chirp-files/original.TM271 --out my_channels.TM271

The --template file provides the file header and footer that identify the radio model
and RT-Systems version. If not supplied, a minimal default header is used, which may
not be recognized by all RT-Systems versions.
''')
    parser.add_argument('input',             help='CHIRP CSV file to convert')
    parser.add_argument('--out',             help='Output .TM271 path (default: <input>.TM271)')
    parser.add_argument('--template', '-t',
                        default=r'chirp-files\original.TM271',
                        help='RT-Systems .TM271 file to copy header/footer from '
                             '(default: chirp-files/original.TM271)')
    parser.add_argument('--verbose', '-v',   action='store_true',
                        help='Print channel table after conversion')
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f'Error: file not found: {args.input}', file=sys.stderr)
        sys.exit(1)

    if args.out:
        out_path = args.out
    else:
        base, _ = os.path.splitext(args.input)
        out_path = base + '.TM271'

    convert(args.input, out_path, template_path=args.template, verbose=args.verbose)

if __name__ == '__main__':
    main()
