#!/usr/bin/env python3
# Route Loader — pick a saved repeater route on a touchscreen and write it to a
# Kenwood TM-271A over its serial programming cable, using CHIRP's TM-271 driver.
#
# Reads two CSV formats from the routes folder:
#   - CHIRP CSV          (header starts "Location,Name,Frequency,...")
#   - RT Systems export  (header starts "Channel Number,Receive Frequency,...")
# Channel numbers in the file become channel numbers in the radio.
#
# Usage:
#   route_loader.py                        touchscreen app (windowed)
#   route_loader.py --fullscreen           touchscreen app (kiosk)
#   route_loader.py --list                 list routes found
#   route_loader.py --check FILE           validate a route against the TM-271
#   route_loader.py --upload FILE          write a route to the radio from the shell
#   --port /dev/ttyUSB0                    serial port (default: auto-detect)
#   --routes DIR                           routes folder (default: $ROUTES_DIR or ~/routes)
#   --keep-others                          don't erase radio channels the route doesn't use
#   --simulate                             fake radio, for trying the app without one

import argparse
import csv
import glob
import logging
import os
import queue
import re
import subprocess
import sys
import threading
import time

try:
    from chirp import chirp_common, directory, errors, import_logic
    from chirp.drivers import generic_csv
except ImportError:
    sys.exit('CHIRP is not installed. Run install.sh, or: pip install '
             'https://github.com/kk7ds/chirp/archive/refs/heads/master.tar.gz')

import serial
import serial.tools.list_ports

# ── Constants ──────────────────────────────────────────────────────────────────

DEFAULT_ROUTES = os.environ.get('ROUTES_DIR', os.path.expanduser('~/routes'))
# USB sticks: /media/usb-sda1 (install.sh auto-mount) or /media/<user>/<label> (desktop),
# either the stick's top folder or a "routes" folder on it
USB_GLOBS = ['/media/*', '/media/*/routes', '/media/*/*', '/media/*/*/routes']
RADIO_VENDOR, RADIO_MODEL = 'Kenwood', 'TM-271'

logging.basicConfig(level=logging.WARNING, format='%(levelname)s %(message)s')
LOG = logging.getLogger('route_loader')

# ── Routes ─────────────────────────────────────────────────────────────────────

class Route:
    def __init__(self, path):
        self.path = path
        self.base = os.path.splitext(os.path.basename(path))[0]
        self.title, self.band = pretty_name(self.base)
        self._mems = None
        self.error = None
        self.skipped = 0            # CSV rows CHIRP couldn't read

    @property
    def memories(self):
        if self._mems is None:
            try:
                self._mems = load_memories(self.path)
                self.skipped = count_rows(self.path) - len(self._mems)
            except Exception as e:          # bad file shouldn't kill the app
                self.error = str(e)
                self._mems = []
        return self._mems


def pretty_name(base):
    """tifton_to_jekyll_island_to_flagler_beach_2m -> ('Tifton → Jekyll Island → Flagler Beach', '2m')"""
    band = ''
    m = re.search(r'_(10m|6m|2m|1\.25m|70cm|33cm|23cm)(_|$)', base)
    if m:
        band = m.group(1)
        base = base[:m.start()] + base[m.end() - (1 if m.group(2) else 0):]
    base = base.strip('_')
    parts = [p.replace('_', ' ').strip().title() for p in base.split('_to_')]
    title = ' → '.join(p for p in parts if p)
    title = re.sub(r'\b(\d+)Mi\b', r'\1 mi', title)
    title = re.sub(r'\b[A-Z][a-z]\b', lambda m: m.group().upper() if m.group().upper() in STATES else m.group(), title)
    return title or base, band


STATES = set('AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM '
             'NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY'.split())


def count_rows(path):
    with open(path, newline='', encoding='utf-8-sig') as fh:
        return sum(1 for row in csv.reader(fh) if row) - 1


def find_routes(routes_dir):
    dirs = [routes_dir]
    for g in USB_GLOBS:
        dirs += [d for d in glob.glob(g) if os.path.isdir(d)]
    seen, routes = set(), []
    for d in dirs:
        files = sorted(glob.glob(os.path.join(d, '*.csv')))
        names = {os.path.basename(f) for f in files}
        for f in files:
            b = os.path.basename(f)
            # foo_chirp.csv is the CHIRP twin of an RT Systems foo.csv — show one entry
            if b.endswith('_chirp.csv') and b[:-len('_chirp.csv')] + '.csv' in names:
                continue
            if b in seen or not is_route_csv(f):
                continue
            seen.add(b)
            routes.append(Route(f))
    return sorted(routes, key=lambda r: r.title.lower())


def is_route_csv(path):
    try:
        with open(path, newline='', encoding='utf-8-sig') as fh:
            head = fh.readline()
    except OSError:
        return False
    return head.startswith('Location,') or head.startswith('Channel Number,')


def load_memories(path):
    """Return a list of chirp Memory objects, numbered as in the file."""
    with open(path, newline='', encoding='utf-8-sig') as fh:
        head = fh.readline()
    if head.startswith('Channel Number,'):
        return load_rt_systems(path)
    radio = generic_csv.CSVRadio(path)
    lo, hi = radio.get_features().memory_bounds
    mems = [radio.get_memory(n) for n in range(lo, hi + 1)]
    return [m for m in mems if not m.empty]


def load_rt_systems(path):
    mems = []
    with open(path, newline='', encoding='utf-8-sig') as fh:
        for row in csv.DictReader(fh):
            try:
                m = chirp_common.Memory()
                m.number = int(row['Channel Number'])
                m.freq = chirp_common.parse_freq(row['Receive Frequency'])
                direction = row.get('Offset Direction', 'Simplex')
                m.duplex = {'Plus': '+', 'Minus': '-'}.get(direction, '')
                off = re.match(r'\s*([\d.]+)\s*(kHz|MHz)', row.get('Offset Frequency', ''))
                if m.duplex and off:
                    m.offset = int(float(off.group(1)) * (1000 if off.group(2) == 'kHz' else 1000000))
                tone = re.match(r'\s*([\d.]+)', row.get('CTCSS', ''))
                if tone:
                    m.rtone = float(tone.group(1))
                m.tmode = {'Tone': 'Tone', 'T Sql': 'TSQL', 'DCS': 'DTCS'}.get(row.get('Tone Mode', ''), '')
                m.mode = 'NFM' if row.get('Operating Mode', 'FM').upper() in ('NFM', 'FM-N') else 'FM'
                m.name = row.get('Name', '')
                m.comment = row.get('Comment', '')
                m.skip = 'S' if row.get('Skip', 'Off') not in ('Off', '') else ''
                mems.append(m)
            except (KeyError, ValueError) as e:
                LOG.warning('%s: skipped row %s (%s)', path, row.get('Channel Number'), e)
    return mems

# ── Radio ──────────────────────────────────────────────────────────────────────

def radio_class():
    directory.import_drivers()
    for cls in directory.DRV_TO_RADIO.values():
        if cls.VENDOR == RADIO_VENDOR and cls.MODEL == RADIO_MODEL:
            return cls
    raise RuntimeError('CHIRP has no %s %s driver' % (RADIO_VENDOR, RADIO_MODEL))


def find_port():
    ports = [p.device for p in serial.tools.list_ports.comports()]
    for pat in ('ttyUSB', 'ttyACM', 'COM'):
        for p in ports:
            if pat in p:
                return p
    return None


def check_route(memories, cls=None):
    """Convert every memory for the TM-271 without touching a radio.
    Returns (ok_list, problems) where problems is [(number, message)]."""
    cls = cls or radio_class()
    radio = cls(None)                     # no pipe: features only
    rf = radio.get_features()
    src_rf = generic_csv.CSVRadio(None).get_features()
    lo, hi = rf.memory_bounds
    ok, problems = [], []
    for m in memories:
        if not lo <= m.number <= hi:
            problems.append((m.number, 'channel %d is past the radio\'s last channel (%d)' % (m.number, hi)))
            continue
        try:
            ok.append(import_logic.import_mem(radio, src_rf, m, {'number': m.number}))
        except Exception as e:
            problems.append((m.number, '%s %s: %s' % (m.name, chirp_common.format_freq(m.freq), e)))
    return ok, problems


def same_memory(a, b):
    if a.empty or b.empty:
        return False
    keys = ('freq', 'duplex', 'offset', 'tmode', 'rtone', 'ctone', 'mode', 'name', 'skip')
    return all(getattr(a, k) == getattr(b, k) for k in keys)


def upload(port, memories, erase_others=True, progress=None, cancel=None, simulate=False):
    """Write @memories to the radio. progress(done, total, text) is called as it goes.
    Returns a summary dict."""
    progress = progress or (lambda d, t, s: None)
    cancel = cancel or threading.Event()
    cls = radio_class()

    progress(0, 1, 'Connecting to radio…')
    if simulate:
        pipe = FakeTM271()
    else:
        pipe = serial.Serial(baudrate=cls.BAUD_RATE, rtscts=cls.HARDWARE_FLOW, timeout=0.25)
        pipe.port = port
        pipe.open()
    try:
        radio = cls(pipe)                 # identifies the radio, probes channel layout
        rf = radio.get_features()
        lo, hi = rf.memory_bounds
        src_rf = generic_csv.CSVRadio(None).get_features()

        wanted = {m.number: m for m in memories}
        erase = [n for n in range(lo, hi + 1) if n not in wanted] if erase_others else []
        total = len(wanted) + len(erase)
        done, written, unchanged, erased = 0, 0, 0, 0
        failed = []

        for n in sorted(wanted):
            if cancel.is_set():
                break
            m = wanted[n]
            progress(done, total, 'Ch %d  %s  %s' % (n, chirp_common.format_freq(m.freq), m.name))
            try:
                if not lo <= n <= hi:
                    raise errors.InvalidMemoryLocation('past last channel %d' % hi)
                cur = radio.get_memory(n)     # driver needs the current memory cached
                dst = import_logic.import_mem(radio, src_rf, m, {'number': n})
                if same_memory(cur, dst):
                    unchanged += 1
                else:
                    radio.set_memory(dst)
                    written += 1
            except Exception as e:
                failed.append((n, '%s %s: %s' % (m.name, chirp_common.format_freq(m.freq), e)))
            done += 1

        for n in erase:
            if cancel.is_set():
                break
            progress(done, total, 'Clearing unused channel %d' % n)
            try:
                if not radio.get_memory(n).empty:
                    radio.erase_memory(n)
                    erased += 1
            except Exception as e:
                failed.append((n, 'clear: %s' % e))
            done += 1

        progress(done, total, 'Cancelled' if cancel.is_set() else 'Done')
        return dict(written=written, unchanged=unchanged, erased=erased, failed=failed,
                    cancelled=cancel.is_set(), channels=(lo, hi))
    finally:
        pipe.close()


class FakeTM271:
    """Answers the TM-271's ID/AI/ME/MN commands so the app runs without a radio.
    Behaves like a radio in 100-channel + name mode."""
    def __init__(self):
        self.baudrate, self.timeout = 9600, 0.1
        self.mem, self.names, self.out = {}, {}, b''

    def write(self, data):
        cmd = data.decode('cp1252').strip()
        time.sleep(0.01)
        if not cmd:
            return
        op, _, arg = cmd.partition(' ')
        num, is_set, val = arg.partition(',')
        if op == 'ID':
            r = 'ID TM-271'
        elif op == 'AI':
            r = 'AI 0'
        elif op in ('ME', 'MN') and num.isdigit():
            n = int(num)
            if n > 99:                                  # 100-channel + name mode
                r = 'N'
            elif op == 'ME' and not is_set:             # read memory
                r = 'ME %s,%s' % (num, self.mem[n]) if n in self.mem else 'N'
            elif op == 'ME' and not val:                # erase memory
                self.mem.pop(n, None)
                self.names.pop(n, None)
                r = cmd
            elif op == 'ME':                            # write memory
                self.mem[n] = val
                r = cmd
            elif not is_set:                            # read name
                r = 'MN %s,%s' % (num, self.names.get(n, ''))
            else:                                       # write name
                self.names[n] = val
                r = cmd
        else:
            r = '?'
        self.out += (r + '\r').encode('cp1252')

    def read(self, n):
        chunk, self.out = self.out[:n], self.out[n:]
        return chunk

    def close(self):
        pass

# ── Touchscreen app ────────────────────────────────────────────────────────────

def run_gui(args):
    import tkinter as tk
    from tkinter import font as tkfont
    from tkinter import ttk

    # dark, high-contrast palette for night driving
    C = dict(bg='#10171a', panel='#172124', card='#1c292d', line='#2b3b40', ink='#e6eeec',
             muted='#8fa3a6', go='#2f9e63', goh='#38b674', warn='#e0a100', bad='#d9534f', sel='#25424b')

    root = tk.Tk()
    root.title('Route Loader')
    root.configure(bg=C['bg'])
    if args.fullscreen:
        root.attributes('-fullscreen', True)
        root.config(cursor='none')
    else:
        root.geometry('800x480')
    sw = root.winfo_screenwidth() if args.fullscreen else 800
    S = max(0.8, min(2.0, sw / 800))           # scale fonts/padding to screen width

    fam = 'DejaVu Sans' if 'DejaVu Sans' in tkfont.families() else 'Segoe UI'
    mono = 'DejaVu Sans Mono' if 'DejaVu Sans Mono' in tkfont.families() else 'Consolas'
    F = lambda size, w='normal', f=fam: (f, int(size * S), w)

    state = dict(routes=[], sel=None, erase=not args.keep_others, busy=False,
                 port=args.port, q=queue.Queue(), cancel=threading.Event())

    # header
    top = tk.Frame(root, bg=C['bg'])
    top.pack(fill='x', padx=int(14 * S), pady=(int(10 * S), int(6 * S)))
    tk.Label(top, text='Route Loader', font=F(20, 'bold'), fg=C['ink'], bg=C['bg']).pack(side='left')
    tk.Label(top, text='  TM-271A', font=F(12), fg=C['muted'], bg=C['bg']).pack(side='left', pady=(int(6 * S), 0))
    status = tk.Label(top, text='', font=F(12, 'bold'), bg=C['bg'])
    status.pack(side='right')

    body = tk.Frame(root, bg=C['bg'])
    body.pack(fill='both', expand=True, padx=int(14 * S), pady=(0, int(12 * S)))
    body.columnconfigure(0, weight=11, uniform='c')
    body.columnconfigure(1, weight=9, uniform='c')
    body.rowconfigure(0, weight=1)

    # route list (drag to scroll)
    left = tk.Frame(body, bg=C['panel'], highlightthickness=1, highlightbackground=C['line'])
    left.grid(row=0, column=0, sticky='nsew', padx=(0, int(10 * S)))
    canvas = tk.Canvas(left, bg=C['panel'], highlightthickness=0, bd=0)
    canvas.pack(fill='both', expand=True)
    inner = tk.Frame(canvas, bg=C['panel'])
    win = canvas.create_window(0, 0, anchor='nw', window=inner)
    canvas.bind('<Configure>', lambda e: canvas.itemconfigure(win, width=e.width))
    inner.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
    drag = dict(y=0, moved=False)

    def press(e):
        drag['y'], drag['moved'] = e.y_root, False
        canvas.scan_mark(0, e.y_root)

    def motion(e):
        if abs(e.y_root - drag['y']) > 8:
            drag['moved'] = True
        if drag['moved']:
            canvas.scan_dragto(0, e.y_root, gain=1)

    # right: details
    right = tk.Frame(body, bg=C['card'], highlightthickness=1, highlightbackground=C['line'])
    right.grid(row=0, column=1, sticky='nsew')
    pad = int(14 * S)
    d_title = tk.Label(right, text='', font=F(16, 'bold'), fg=C['ink'], bg=C['card'], justify='left', anchor='w')
    d_title.pack(fill='x', padx=pad, pady=(pad, 0))
    d_sub = tk.Label(right, text='', font=F(12), fg=C['muted'], bg=C['card'], justify='left', anchor='w')
    d_sub.pack(fill='x', padx=pad)
    d_list = tk.Text(right, font=F(11, f=mono), fg=C['ink'], bg=C['card'], bd=0, highlightthickness=0,
                     height=6, wrap='none', cursor='none' if args.fullscreen else 'arrow')
    d_list.pack(fill='both', expand=True, padx=pad, pady=(int(8 * S), int(8 * S)))
    d_list.tag_configure('dim', foreground=C['muted'])
    d_list.tag_configure('bad', foreground=C['bad'])

    erase_btn = tk.Button(right, font=F(12), relief='flat', bd=0, activebackground=C['sel'],
                          fg=C['ink'], bg=C['line'], activeforeground=C['ink'])
    erase_btn.pack(fill='x', padx=pad, pady=(0, int(8 * S)), ipady=int(8 * S))
    send_btn = tk.Button(right, text='Send to radio', font=F(18, 'bold'), relief='flat', bd=0,
                         fg='#ffffff', bg=C['go'], activebackground=C['goh'], activeforeground='#ffffff',
                         disabledforeground='#9fb5b0')
    send_btn.pack(fill='x', padx=pad, pady=(0, pad), ipady=int(14 * S))

    # bottom bar
    bottom = tk.Frame(root, bg=C['bg'])
    bottom.pack(fill='x', padx=int(14 * S), pady=(0, int(10 * S)))
    small = dict(font=F(11), relief='flat', bd=0, fg=C['muted'], bg=C['bg'], activebackground=C['line'],
                 activeforeground=C['ink'])
    rescan_btn = tk.Button(bottom, text='⟳ Rescan routes', **small)
    rescan_btn.pack(side='left', ipadx=int(8 * S), ipady=int(4 * S))
    power_btn = tk.Button(bottom, text='⏻ Power off', **small)
    power_btn.pack(side='right', ipadx=int(8 * S), ipady=int(4 * S))
    note = tk.Label(bottom, text='', font=F(11), fg=C['muted'], bg=C['bg'])
    note.pack(side='left', padx=int(12 * S))

    # overlay for upload / confirm
    overlay = tk.Frame(root, bg=C['bg'])
    o_title = tk.Label(overlay, text='', font=F(20, 'bold'), fg=C['ink'], bg=C['bg'], wraplength=int(720 * S))
    o_title.pack(pady=(int(50 * S), int(10 * S)))
    o_text = tk.Label(overlay, text='', font=F(14), fg=C['muted'], bg=C['bg'], wraplength=int(720 * S), justify='center')
    o_text.pack(pady=(0, int(14 * S)))
    style = ttk.Style(root)
    style.theme_use('default')
    style.configure('R.Horizontal.TProgressbar', troughcolor=C['line'], background=C['go'], thickness=int(26 * S),
                    bordercolor=C['bg'], lightcolor=C['go'], darkcolor=C['go'])
    o_bar = ttk.Progressbar(overlay, style='R.Horizontal.TProgressbar', length=int(620 * S), maximum=1)
    o_bar.pack(pady=int(6 * S))
    o_btns = tk.Frame(overlay, bg=C['bg'])
    o_btns.pack(pady=int(24 * S))

    def overlay_buttons(*specs):
        for w in o_btns.winfo_children():
            w.destroy()
        for text, color, cmd in specs:
            tk.Button(o_btns, text=text, command=cmd, font=F(16, 'bold'), relief='flat', bd=0, fg='#ffffff',
                      bg=color, activebackground=color, activeforeground='#ffffff', width=12
                      ).pack(side='left', padx=int(10 * S), ipady=int(12 * S))

    def show_overlay(title, text, bar=None):
        o_title.config(text=title)
        o_text.config(text=text)
        if bar is None:
            o_bar.pack_forget()
        else:
            if not o_bar.winfo_ismapped():
                o_bar.pack(pady=int(6 * S), before=o_btns)
            o_bar.config(value=bar)
        overlay.place(x=0, y=0, relwidth=1, relheight=1)
        overlay.lift()

    def hide_overlay():
        overlay.place_forget()

    # ── behaviour
    def refresh_erase():
        erase_btn.config(text=('☑  Clear other channels in the radio' if state['erase']
                               else '☐  Keep other channels in the radio'))

    def toggle_erase():
        state['erase'] = not state['erase']
        refresh_erase()

    def select(route):
        state['sel'] = route
        for w in inner.winfo_children():
            r = getattr(w, 'route', None)
            bg = C['sel'] if r is route else C['panel']
            w.config(bg=bg)
            for c in w.winfo_children():
                c.config(bg=bg)
        mems = route.memories
        d_title.config(text=route.title, wraplength=right.winfo_width() - 2 * pad or 300)
        ok, problems = check_route(mems) if mems else ([], [])
        reps = sum(1 for m in mems if m.duplex in ('+', '-'))
        d_sub.config(text='%d channels · %d repeaters%s' % (len(mems), reps, ' · ' + route.band if route.band else ''))
        d_list.config(state='normal')
        d_list.delete('1.0', 'end')
        if route.error:
            d_list.insert('end', 'Could not read this file:\n%s\n' % route.error, 'bad')
        if route.skipped:
            d_list.insert('end', '! %d rows in this file could not be read\n' % route.skipped, 'bad')
        for m in mems:
            off = {'+': '+', '-': '−'}.get(m.duplex, ' ')
            tone = ('%.1f' % m.rtone) if m.tmode == 'Tone' else ''
            d_list.insert('end', '%3d ' % m.number, 'dim')
            d_list.insert('end', '%-8s%s %-6s ' % (chirp_common.format_freq(m.freq)[:7], off, m.name[:6]))
            d_list.insert('end', '%s\n' % tone, 'dim')
        for n, msg in problems:
            d_list.insert('end', '! %s\n' % msg, 'bad')
        d_list.config(state='disabled')
        send_btn.config(state='normal' if ok else 'disabled')

    def build_list():
        for w in inner.winfo_children():
            w.destroy()
        state['routes'] = find_routes(args.routes)
        if not state['routes']:
            tk.Label(inner, text='No routes found.\n\nCopy route .csv files to\n%s\nor plug in a USB stick '
                     'with a "routes" folder, then tap Rescan.' % args.routes,
                     font=F(13), fg=C['muted'], bg=C['panel'], justify='left').pack(padx=pad, pady=pad, anchor='w')
            send_btn.config(state='disabled')
            d_title.config(text='')
            d_sub.config(text='')
            return
        for r in state['routes']:
            row = tk.Frame(inner, bg=C['panel'], cursor='none' if args.fullscreen else 'hand2')
            row.route = r
            row.pack(fill='x')
            t = tk.Label(row, text=r.title, font=F(14, 'bold'), fg=C['ink'], bg=C['panel'], anchor='w',
                         justify='left', wraplength=int(400 * S))
            t.pack(fill='x', padx=pad, pady=(int(10 * S), 0))
            s = tk.Label(row, text=(r.band + ' · ' if r.band else '') + os.path.basename(r.path), font=F(10),
                         fg=C['muted'], bg=C['panel'], anchor='w')
            s.pack(fill='x', padx=pad, pady=(0, int(10 * S)))
            tk.Frame(inner, bg=C['line'], height=1).pack(fill='x')
            for w in (row, t, s):
                w.bind('<ButtonPress-1>', press)
                w.bind('<B1-Motion>', motion)
                w.bind('<ButtonRelease-1>', lambda e, r=r: None if drag['moved'] else select(r))
        canvas.yview_moveto(0)
        keep = state['sel'] and next((r for r in state['routes'] if r.path == state['sel'].path), None)
        root.after(50, lambda: select(keep or state['routes'][0]))

    def poll_port():
        if not state['busy']:
            p = args.port or find_port()
            state['port'] = p
            if args.simulate:
                status.config(text='● Simulated radio', fg=C['warn'])
            elif p:
                status.config(text='● Cable on %s' % p, fg=C['go'])
            else:
                status.config(text='● No programming cable', fg=C['bad'])
        root.after(3000, poll_port)

    def start_upload():
        r = state['sel']
        if not r or state['busy']:
            return
        if not (state['port'] or args.simulate):
            show_overlay('Programming cable not found',
                         'Plug the cable into the BeagleBone and the radio, then try again.')
            overlay_buttons(('OK', C['line'], hide_overlay))
            return
        state['busy'] = True
        state['cancel'].clear()
        show_overlay('Sending %s' % r.title, 'Connecting to radio…', bar=0)
        overlay_buttons(('Cancel', C['bad'], lambda: state['cancel'].set()))

        def work():
            try:
                res = upload(state['port'], r.memories, state['erase'],
                             progress=lambda d, t, s: state['q'].put(('p', d, t, s)),
                             cancel=state['cancel'], simulate=args.simulate)
                state['q'].put(('done', res))
            except Exception as e:
                state['q'].put(('err', e))
        threading.Thread(target=work, daemon=True).start()

    def pump():
        try:
            while True:
                msg = state['q'].get_nowait()
                if msg[0] == 'p':
                    _, d, t, s = msg
                    o_bar.config(maximum=max(t, 1), value=d)
                    o_text.config(text=s)
                elif msg[0] == 'done':
                    state['busy'] = False
                    res = msg[1]
                    lines = ['%d channels written, %d already matched' % (res['written'], res['unchanged'])]
                    if res['erased']:
                        lines.append('%d old channels cleared' % res['erased'])
                    for n, why in res['failed'][:4]:
                        lines.append('Ch %d failed: %s' % (n, why))
                    if len(res['failed']) > 4:
                        lines.append('…and %d more failures' % (len(res['failed']) - 4))
                    title = ('Stopped part way' if res['cancelled'] else
                             'Radio programmed' if not res['failed'] else 'Finished with problems')
                    show_overlay(title, '\n'.join(lines), bar=None)
                    overlay_buttons(('Done', C['go'], hide_overlay))
                    note.config(text='Last sent: %s  %s' % (state['sel'].title, time.strftime('%H:%M')))
                elif msg[0] == 'err':
                    state['busy'] = False
                    show_overlay('Could not talk to the radio',
                                 '%s\n\nCheck that the radio is on and the cable is plugged into the '
                                 'radio\'s data/mic jack.' % msg[1])
                    overlay_buttons(('OK', C['line'], hide_overlay))
        except queue.Empty:
            pass
        root.after(100, pump)

    def ask_power():
        show_overlay('Power off the BeagleBone?', 'Wait for the green light to stop blinking before '
                     'removing power.')
        overlay_buttons(('Power off', C['bad'], do_power), ('Cancel', C['line'], hide_overlay))

    def do_power():
        show_overlay('Shutting down…', '')
        overlay_buttons()
        subprocess.Popen(['sudo', '-n', 'systemctl', 'poweroff'])

    erase_btn.config(command=toggle_erase)
    send_btn.config(command=start_upload)
    rescan_btn.config(command=build_list)
    power_btn.config(command=ask_power)
    root.bind('<Escape>', lambda e: root.attributes('-fullscreen', False))
    refresh_erase()
    build_list()
    poll_port()
    pump()
    root.mainloop()

# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='Write saved repeater routes to a Kenwood TM-271A.')
    ap.add_argument('--routes', default=DEFAULT_ROUTES)
    ap.add_argument('--port')
    ap.add_argument('--fullscreen', action='store_true')
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--check', metavar='FILE')
    ap.add_argument('--upload', metavar='FILE')
    ap.add_argument('--keep-others', action='store_true')
    ap.add_argument('--simulate', action='store_true')
    ap.add_argument('--debug', action='store_true')
    args = ap.parse_args()
    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.list:
        for r in find_routes(args.routes):
            print('%-45s %3d ch%s  %s' % (r.title, len(r.memories),
                                          '  (%d rows unreadable)' % r.skipped if r.skipped else '', r.path))
        return

    if args.check or args.upload:
        path = args.check or args.upload
        mems = load_memories(path)
        ok, problems = check_route(mems)
        print('%s: %d channels, %d OK for the TM-271' % (path, len(mems), len(ok)))
        for n, msg in problems:
            print('  ch %d: %s' % (n, msg))
        if args.check:
            sys.exit(1 if problems else 0)
        port = args.port or find_port()
        if not port and not args.simulate:
            sys.exit('No serial port found; use --port')
        res = upload(port, mems, not args.keep_others, simulate=args.simulate,
                     progress=lambda d, t, s: print('\r  [%3d/%3d] %-50s' % (d, t, s[:50]), end='', flush=True))
        print('\n  %d written, %d unchanged, %d cleared, %d failed' %
              (res['written'], res['unchanged'], res['erased'], len(res['failed'])))
        for n, why in res['failed']:
            print('  ch %d: %s' % (n, why))
        sys.exit(1 if res['failed'] else 0)

    run_gui(args)


if __name__ == '__main__':
    main()
