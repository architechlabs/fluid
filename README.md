# Fluid

Fluid turns a Raspberry Pi into a browser-based screen sharing display for a room, lab, kiosk, classroom, or demo bench.

Users open one page from any laptop on the same network, share their screen, and an admin chooses what appears on the Pi HDMI output. The Pi runs the Node.js signaling server and a full-screen Chromium display automatically on boot.

## What You Get

- Browser screen sharing with no client app to install
- Admin dashboard with PIN access
- Full-screen HDMI display mode for the Pi
- WebRTC peer connection over LAN
- Systemd services that start on boot
- One installer that configures Node.js, Chromium, Xorg, logs, services, and optional HTTPS
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
- Creates the `Fluid` service user
- Writes `/etc/fluid/fluid.env`
- Installs systemd services
- Configures Chromium kiosk startup
- Tunes basic Raspberry Pi HDMI/GPU settings
- Starts services and offers a reboot

For unattended installs:

```bash
sudo bash install.sh --admin-pin 8432 --port 3000 --yes --no-reboot
```

For HTTPS with a self-signed local certificate:

```bash
sudo bash install.sh --admin-pin 8432 --with-https
```

Most browsers require HTTPS for screen capture on non-localhost pages. If HTTP screen sharing fails from another laptop, reinstall with `--with-https` or put Fluid behind your own HTTPS reverse proxy.

## Use It

Open these from a device on the same network:

```text
http://<pi-ip>:3000/client.html
http://<pi-ip>:3000/admin.html
```

If HTTPS was enabled:

```text
https://<pi-ip>/client.html
https://<pi-ip>/admin.html
```

The display view normally launches automatically on the Pi HDMI output. You can also open:

```text
http://<pi-ip>:3000/display.html
```

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
CHROMIUM_BIN=/usr/bin/chromium-browser
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

sudo systemctl restart fluid-server
sudo systemctl restart fluid-display

sudo journalctl -u fluid-server -f
sudo journalctl -u fluid-display -f
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
--port PORT           Server port, default 3000
--max-devices N       Max client devices, default 20
--install-dir PATH    Install directory, default /opt/fluid
--user NAME           Service user, default Fluid
--with-https          Install nginx reverse proxy with a self-signed cert
--https-name NAME     Certificate name/CN, default fluid.local
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
| Display stays on standby | Open admin panel and select a connected device. |
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

## Security Notes

- Change the default admin PIN before real use.
- Prefer HTTPS for anything beyond quick local testing.
- Do not expose Fluid directly to the public internet without authentication, TLS, firewalling, and a proper access model.
- The built-in WebRTC setup is intended for trusted LAN use.

## License

MIT
