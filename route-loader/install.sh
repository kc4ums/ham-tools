#!/usr/bin/env bash
# Route Loader installer — turns a BeagleBone (Debian 12) with a touchscreen into a
# TM-271A route loader that starts full-screen at boot. Re-run to update.
#
#   sudo ./install.sh [user] [--no-desktop]
#
#   user          account that runs the app (default: the sudo user, else "debian")
#   --no-desktop  disable an existing desktop login (lightdm etc.) so the app owns the screen

set -e

APP_DIR=/opt/route-loader
CHIRP_URL=https://github.com/kk7ds/chirp/archive/refs/heads/master.tar.gz
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Args ───────────────────────────
run_user="${SUDO_USER:-debian}"
no_desktop=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-desktop) no_desktop=1; shift;;
        -*)           echo "Unknown option: $1" >&2; exit 1;;
        *)            run_user="$1"; shift;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./install.sh [user]" >&2; exit 1; }
id "$run_user" >/dev/null 2>&1 || { echo "No such user: $run_user" >&2; exit 1; }
home_dir=$(getent passwd "$run_user" | cut -d: -f6)
routes_dir="$home_dir/routes"

step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }

# ── Packages ───────────────────────
step "Installing packages"
apt-get update
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-tk curl \
    xserver-xorg-core xserver-xorg-legacy xserver-xorg-video-fbdev \
    xserver-xorg-input-libinput xserver-xorg-input-evdev \
    xinit x11-xserver-utils xinput xinput-calibrator fonts-dejavu-core

python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
    echo "CHIRP needs Python 3.10 or newer (Debian 12). Flash a newer BeagleBone image." >&2; exit 1; }

# ── App + CHIRP ────────────────────
step "Installing Route Loader and CHIRP into $APP_DIR"
mkdir -p "$APP_DIR"
install -m 755 "$SRC_DIR/route_loader.py" "$APP_DIR/route_loader.py"
[ -x "$APP_DIR/venv/bin/python" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip wheel
"$APP_DIR/venv/bin/pip" install --quiet --upgrade "$CHIRP_URL"
"$APP_DIR/venv/bin/python" -c 'from chirp.drivers import kenwood_live; print("CHIRP TM-271 driver OK")'

cat > "$APP_DIR/kiosk.sh" <<EOF
#!/bin/sh
# Started by xinit: keep the screen awake, then run the app full-screen
xset s off
xset s noblank
xset -dpms
exec $APP_DIR/venv/bin/python $APP_DIR/route_loader.py --fullscreen --routes "$routes_dir"
EOF
chmod 755 "$APP_DIR/kiosk.sh"

# ── Routes ─────────────────────────
step "Routes folder: $routes_dir"
mkdir -p "$routes_dir"
if ls "$SRC_DIR"/../chirp-files/*.csv >/dev/null 2>&1; then
    cp -n "$SRC_DIR"/../chirp-files/*.csv "$routes_dir"/
    echo "Copied route files from chirp-files (existing files kept)"
fi
chown -R "$run_user": "$routes_dir"

# ── Permissions ────────────────────
step "Permissions for $run_user"
for g in dialout video input tty render; do
    getent group "$g" >/dev/null && usermod -aG "$g" "$run_user"
done
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
echo "$run_user ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff" > /etc/sudoers.d/route-loader
chmod 440 /etc/sudoers.d/route-loader
visudo -cf /etc/sudoers.d/route-loader >/dev/null

# ── USB sticks ─────────────────────
# Mount any USB stick at /media/usb-<dev> so routes can be loaded from it
step "USB stick auto-mount"
cat > /etc/udev/rules.d/90-route-loader-usb.rules <<'EOF'
ACTION=="add", SUBSYSTEMS=="usb", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", RUN{program}+="/usr/bin/systemd-mount --no-block --automount=yes --collect --options=ro $devnode /media/usb-%k"
EOF
udevadm control --reload-rules 2>/dev/null \
    || echo "udev isn't running right now; the USB rule takes effect after a reboot"

# ── Service ────────────────────────
step "Boot service"
cat > /etc/systemd/system/route-loader.service <<EOF
[Unit]
Description=Route Loader touchscreen (Kenwood TM-271A)
After=systemd-user-sessions.service
Conflicts=getty@tty7.service

[Service]
User=$run_user
WorkingDirectory=$home_dir
Environment=ROUTES_DIR=$routes_dir
ExecStart=/usr/bin/xinit $APP_DIR/kiosk.sh -- :0 vt7 -nolisten tcp -nocursor -s 0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

if systemctl is-enabled display-manager >/dev/null 2>&1; then
    if [ "$no_desktop" -eq 1 ]; then
        systemctl disable display-manager
        systemctl set-default multi-user.target
        echo "Desktop login disabled"
    else
        echo "NOTE: a desktop login is enabled and will fight the app for the screen."
        echo "      Re-run with --no-desktop to turn it off."
    fi
fi

if [ -d /run/systemd/system ]; then
    systemctl daemon-reload
    systemctl enable route-loader.service
    systemctl restart route-loader.service
else
    # No running systemd (container, WSL, chroot): enable for next boot only
    systemctl enable route-loader.service 2>/dev/null \
        || echo "NOTE: systemd isn't running here, so the app won't start at boot on this system."
fi

step "Done"
echo "  Routes:   $routes_dir  (or a USB stick, root or a 'routes' folder)"
echo "  Logs:     journalctl -u route-loader -f"
echo "  Test:     $APP_DIR/venv/bin/python $APP_DIR/route_loader.py --list --routes $routes_dir"
echo "  Touch off? run 'DISPLAY=:0 xinput_calibrator' as $run_user"
echo
