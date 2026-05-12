# Fluid

Fluid turns a Raspberry Pi into a browser-based screen sharing display for a room, lab, kiosk, classroom, or demo bench.

Users open one page from any laptop on the same network, share their screen, and an admin chooses what appears on the Pi HDMI output. The Pi runs the Node.js signaling server and a full-screen Chromium display automatically on boot.

## What You Get

- Browser screen sharing with no client app to install
- Admin dashboard with PIN access
- Full-screen HDMI display mode for the Pi
- Auto-display of every active shared screen on HDMI
- Responsive screen wall layout for multiple devices
- Optional native cast gateway status for AirPlay/Miracast/Cast receiver work
- WebRTC peer connection over LAN
- Systemd services that start on boot
- One installer that configures Node.js, Chromium, Xorg, logs, services, and HTTPS
- A doctor script for setup checks

## Architecture

```text
Laptop browser /client.html
        |
        | WebSocket signaling
        v
Raspberry Pi Node.js server :3000
        |
        | WebRTC media
        v
Chromium kiosk /display.html -> HDMI

Admin browser /admin.html controls which device is shown.
```

## Quick Install On Raspberry Pi

Use Raspberry Pi OS Lite 64-bit or Raspberry Pi OS with desktop disabled.

```bash
git clone https://github.com/architechlabs/fluid.git fluid
cd fluid
sudo bash install.sh
```

The installer asks for the admin PIN and port, then handles the rest:

- Installs system packages
- Installs Node.js 20 if needed
- Installs npm dependencies
- Creates the `fluid` service user
- Writes `/etc/fluid/fluid.env`
- Installs systemd services
- Configures Chromium kiosk startup
- Tunes basic Raspberry Pi HDMI/GPU settings
- Starts services and offers a reboot

For unattended installs:

```bash
sudo bash install.sh --admin-pin 8432 --port 3000 --yes --no-reboot
```

Optional native cast gateway helpers:

```bash
sudo bash install.sh --admin-pin 8432 --with-native-cast --cast-name Fluid
```

This is the one-command setup path for the native cast gateway. It installs discovery/receiver helpers when they are available in Raspberry Pi OS repositories, preserves an already configured Miracast link on reinstall, tries to auto-detect Miracast when possible, and exposes receiver status in the admin dashboard. Native casting is not one protocol; see [docs/NATIVE_CAST.md](docs/NATIVE_CAST.md).

If native cast is already enabled, a later installer run keeps it enabled by default. Use `--no-native-cast` only when you intentionally want to turn those receiver services off.

HTTPS is installed by default because browser screen sharing is blocked on plain HTTP from another device. The port you choose becomes the public HTTPS port. Fluid moves the Node.js app behind nginx on an internal local port automatically.

```bash
sudo bash install.sh --admin-pin 8432
```

To skip HTTPS for a lab-only setup:

```bash
sudo bash install.sh --admin-pin 8432 --no-https
```

Most browsers require HTTPS for screen capture on non-localhost pages. The installer handles this automatically unless you pass `--no-https`.

## Use It

Open these from a device on the same network:

```text
https://<pi-ip>:3000/client.html
https://<pi-ip>:3000/admin.html
```

If you installed with `--port 3123`, use:

```text
https://<pi-ip>:3123/client.html
https://<pi-ip>:3123/admin.html
```

If you installed with `--no-https` for local testing:

```text
http://<pi-ip>:3000/client.html
http://<pi-ip>:3000/admin.html
```

The display view normally launches automatically on the Pi HDMI output. You can also open:

```text
http://<pi-ip>:3000/display.html
```

## HDMI Display

After installation and reboot, the TV connected to the Raspberry Pi HDMI port should show the Fluid standby screen instead of the terminal. When laptops start sharing, Fluid automatically shows every live screen on HDMI in a responsive wall. One live device fills the screen, two devices split side-by-side, four devices become a 2x2 wall, sixteen devices become a 4x4 wall, and larger groups continue fitting into a grid.

The kiosk auto-detects the active HDMI resolution by default. Only force a size if your TV reports the wrong mode:

```bash
sudo bash install.sh --kiosk-size 3840x2160
```

Or edit `/etc/fluid/fluid.env` to force a known mode:

```text
KIOSK_WIDTH=1920
KIOSK_HEIGHT=1080
```

Then restart the display:

```bash
sudo systemctl restart fluid-display
```

If the TV still shows the Raspberry Pi terminal:

```bash
sudo systemctl status fluid-display
sudo journalctl -u fluid-display -n 80 --no-pager
sudo systemctl restart fluid-display
```

The installer configures Xorg kiosk permissions for Pi OS Lite using `/etc/X11/Xwrapper.config`.

## Native Cast Gateway

Fluid's browser wall is the reliable multi-screen path. Native casting uses OS-level receiver protocols:

- Apple/iPhone/macOS screen mirroring uses AirPlay.
- Windows wireless display commonly uses Miracast.
- Android may use Miracast or Google Cast depending on the phone/vendor.
- Chrome's Cast picker discovers Cast receivers, not normal LAN web apps.

Run the installer with `--with-native-cast` to enable the managed gateway layer and status dashboard. See [docs/NATIVE_CAST.md](docs/NATIVE_CAST.md) for the exact support matrix.

## Configuration

Production configuration lives in:

```text
/etc/fluid/fluid.env
```

Example:

```env
PORT=3000
SERVER_PORT=3000
ADMIN_PIN=8432
MAX_DEVICES=20
LOG_FILE=/var/log/fluid/server.log
CHROMIUM_BIN=/usr/bin/chromium
HTTPS_REDIRECT=true
```

After changing config:

```bash
sudo systemctl restart fluid-server fluid-display
```

For local development, copy `.env.example` to `.env` and run `npm start`.

## Service Commands

```bash
sudo systemctl status fluid-server
sudo systemctl status fluid-display
sudo systemctl status fluid-native-cast
sudo systemctl status fluid-miracast

sudo systemctl restart fluid-server
sudo systemctl restart fluid-display
sudo systemctl restart fluid-native-cast
sudo systemctl restart fluid-miracast

sudo journalctl -u fluid-server -f
sudo journalctl -u fluid-display -f
sudo journalctl -u fluid-native-cast -f
sudo journalctl -u fluid-miracast -f
```

## Local Development

```bash
npm install
cp .env.example .env
npm run dev
```

Then open:

```text
http://localhost:3000
```

Run setup checks:

```bash
npm run doctor
```

## Installer Options

```text
--admin-pin PIN       Admin dashboard PIN
--port PORT           Public HTTPS port, default 3000
--app-port PORT       Internal Node.js port when HTTPS is enabled, auto-picked
--max-devices N       Max client devices, default 20
--install-dir PATH    Install directory, default /opt/fluid
--user NAME           Service user, default Fluid
--with-https          Install nginx reverse proxy with a self-signed cert, default
--no-https            Skip HTTPS reverse proxy setup
--https-name NAME     Certificate name/CN, default fluid.local
--with-native-cast    Install optional native cast gateway helpers
--no-native-cast      Disable optional native cast gateway helpers
--cast-name NAME      Native cast receiver name, default Fluid
--cast-mode MODE      Native receiver mode: all, airplay, or miracast
--airplay-pin PIN     Optional 4-digit AirPlay PIN
--miracast-link N     MiracleCast link id, default auto tries safe discovery
--no-reboot           Do not prompt for reboot
--no-start            Install only; do not start services
-y, --yes             Use safe defaults for prompts
```

## Repository Layout

```text
.
├── public/
│   ├── index.html
│   ├── client.html
│   ├── admin.html
│   └── display.html
├── scripts/
│   └── doctor.sh
├── systemd/
│   ├── fluid-server.service
│   └── fluid-display.service
├── install.sh
├── server.js
├── start-kiosk.sh
├── package.json
├── .env.example
└── README.md
```

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Screen share button fails | Use HTTPS, Chrome/Edge/Firefox, and allow screen capture permission. |
| `ERR_SSL_PROTOCOL_ERROR` on `https://<pi-ip>:<port>` | Re-run the latest installer. The chosen port must be served by nginx HTTPS, with Node on an internal port. |
| nginx fails to start during install | Re-run the latest installer. It stops old Fluid services before nginx binds the public HTTPS port and prints any remaining port owner. |
| Page says screen sharing is blocked | Open `https://<pi-ip>:<port>/client.html`, not `http://<pi-ip>:<port>/client.html`. |
| Chrome Cast menu does not show Fluid | Chrome's Cast menu lists Chromecast/Miracast receivers, not ordinary LAN web apps. Use the Fluid client page, or install a separate OS-level cast receiver if you specifically need native Cast discovery. |
| Native Cast says AirPlay missing | Re-run `sudo bash install.sh --with-native-cast`; if `uxplay` is not in your Raspberry Pi OS repository, install it from a trusted package source for your OS release. |
| AirPlay log says `videoparsersbad` missing | Pull the latest code and re-run `sudo bash install.sh --with-native-cast --cast-name Fluid`; the installer now installs the GStreamer runtime packages that `uxplay` needs. |
| Miracast says needs-link | Re-run `sudo bash install.sh --with-native-cast --cast-name Fluid`. If auto-detection still cannot see the adapter link, run `sudo miracle-sinkctl`, copy the `[ADD] Link: N` number into `MIRACAST_LINK=N` in `/etc/fluid/fluid.env`, then restart `fluid-miracast`. |
| Miracast log says tools are not installed | Your Raspberry Pi OS apt repositories did not provide `miraclecast`, so Windows Wireless Display cannot appear yet. Use the browser client page, or install a compatible MiracleCast/Wi-Fi Direct sink stack for that OS release. |
| Miracast not discoverable | Miracast requires Wi-Fi Direct sink support. Check Raspberry Pi wireless hardware/driver support and `sudo journalctl -u fluid-miracast -n 80 --no-pager`. |
| Display stays on standby | Make sure at least one device is actively sharing, then click `Sync Wall` in the admin panel. |
| TV image is stuck on the left half | Re-run `sudo bash install.sh`, reboot once, then check `KIOSK_WIDTH` and `KIOSK_HEIGHT` in `/etc/fluid/fluid.env` match the TV mode. |
| Two laptops do not show together | Restart the display with `sudo systemctl restart fluid-display`, then click `Sync Wall`; every device with status `streaming` should appear as its own tile. |
| TV shows Raspberry Pi terminal | Restart the display service with `sudo systemctl restart fluid-display`, then check `sudo journalctl -u fluid-display -n 80 --no-pager`. |
| Admin PIN does not work | Check `/etc/fluid/fluid.env`, then restart `fluid-server`. |
| Kiosk does not launch | Run `sudo journalctl -u fluid-display -f` and confirm Chromium is installed. |
| Server does not start | Run `npm run doctor`, then check `sudo journalctl -u fluid-server -f`. |
| Port already in use | Change `PORT` and `SERVER_PORT` in `/etc/fluid/fluid.env`. |
| High latency | Use wired LAN or strong Wi-Fi; WebRTC quality depends heavily on local network stability. |

## API

Health:

```text
GET /api/health
```

PIN-protected device list:

```text
GET /api/devices?pin=<admin-pin>
```

PIN-protected native cast status:

```text
GET /api/cast/status?pin=<admin-pin>
```

## Security Notes

- Change the default admin PIN before real use.
- Prefer HTTPS for anything beyond quick local testing.
- Do not expose Fluid directly to the public internet without authentication, TLS, firewalling, and a proper access model.
- The built-in WebRTC setup is intended for trusted LAN use.

## License

MIT
