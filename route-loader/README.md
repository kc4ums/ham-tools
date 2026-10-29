# Route Loader

A touchscreen box for the car: pick a saved repeater route and write it to a
Kenwood TM-271A over the programming cable. It runs on a BeagleBone with Debian 12
and uses CHIRP's own TM-271 driver to talk to the radio.

## What you need

- BeagleBone Black (or similar) running the **Debian 12** image. CHIRP needs Python 3.10+, so Debian 11 images won't work.
- A touchscreen. An LCD cape or an HDMI/USB touch display both work; the layout is made for 800×480 and scales up.
- The TM-271A programming cable you already use with CHIRP or RT Systems, plugged into a BeagleBone USB port.

## Install

On the BeagleBone:

```bash
git clone https://github.com/kc4ums/ham-tools.git
cd ham-tools/route-loader
sudo ./install.sh                 # or: sudo ./install.sh debian --no-desktop
```

The installer:

- installs X, Tk and CHIRP (from CHIRP's GitHub source) into `/opt/route-loader`
- copies the repo's `chirp-files/*.csv` into `~/routes`
- lets the app use the serial cable and power off the board
- starts the app full-screen at boot (`route-loader.service`)

If the image has a desktop login, add `--no-desktop` so the app gets the screen to itself.
Re-run the installer to update the app or CHIRP. Your routes folder is never overwritten.

## Using it

1. Turn the radio on and plug in the cable.
2. Tap a route. The right side lists every channel that will be written: channel number, frequency, offset, name and tone.
3. **Clear other channels** (on by default) erases radio channels the route doesn't use, so old routes don't linger. Tap it to keep them instead.
4. Tap **Send to radio**. A route of about 50 channels takes around 35 seconds. Channels that already match are skipped, so re-sending is quick.

Use **Power off** before pulling power from the BeagleBone.

## Routes

Any CHIRP CSV or RT Systems TM-271 CSV export works. Channel numbers in the file become
channel numbers in the radio. The app looks in:

- `~/routes` on the BeagleBone (copy files with `scp *.csv debian@beaglebone.local:routes/`)
- a USB stick: files at the top level or in a `routes` folder. Tap **Rescan routes** after plugging it in.

When a folder has both `name.csv` and `name_chirp.csv`, only `name.csv` is listed.

## Radio limits

The TM-271A stores either **100 channels with names** or **200 without**. CHIRP detects which
mode the radio is in. In the usual named mode, a route must fit in channels 0–99. The app flags
anything that won't fit, and anything outside 137–174 MHz, before you send.

## From the shell

```bash
cd /opt/route-loader
venv/bin/python route_loader.py --list   --routes ~/routes
venv/bin/python route_loader.py --check  ~/routes/tifton_to_jekyll_island_to_flagler_beach_2m.csv
venv/bin/python route_loader.py --upload ~/routes/tifton_to_jekyll_island_to_flagler_beach_2m.csv --port /dev/ttyUSB0
```

`--simulate` swaps in a fake radio, so you can try the app on any PC with CHIRP installed
(`pip install https://github.com/kk7ds/chirp/archive/refs/heads/master.tar.gz`).

## Troubleshooting

| Problem | Fix |
|---|---|
| "No programming cable" | Check `ls /dev/ttyUSB* /dev/ttyACM*`. Use `--port` in `/opt/route-loader/kiosk.sh` for an unusual device name. |
| "Could not talk to the radio" | Radio on and not in a menu; cable seated in the radio's jack. Run `--upload` with `--debug` to see the serial traffic. |
| Touch is offset or mirrored | `DISPLAY=:0 xinput_calibrator` as the app user, then save its output to `/etc/X11/xorg.conf.d/99-calibration.conf`. |
| Blank screen | `journalctl -u route-loader -f`. An LCD cape needs its overlay enabled in `/boot/uEnv.txt` first. |
| "N rows could not be read" | That CSV has rows CHIRP rejects (older files from before the tone fix). Regenerate the route. |
