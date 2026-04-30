#!/bin/bash
# Fluid Kiosk Launch Script
# Runs inside startx — sets up X environment and launches Chromium in kiosk mode

export DISPLAY=:0

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Hide cursor (requires unclutter)
command -v unclutter >/dev/null 2>&1 && unclutter -idle 1 -root &

# Kill any existing Chromium instances
pkill -f chromium 2>/dev/null || true
sleep 1

# Remove Chromium crash flags that prevent kiosk from starting
PREFS_DIR="/home/fluid/.config/chromium/Default"
mkdir -p "$PREFS_DIR"
if [ -f "$PREFS_DIR/Preferences" ]; then
  # Reset "exited_cleanly" to prevent the "Chromium didn't shut down correctly" banner
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g' "$PREFS_DIR/Preferences" 2>/dev/null || true
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/g' "$PREFS_DIR/Preferences" 2>/dev/null || true
fi

# Server URL - using localhost since display runs on the Pi by default
SERVER_PORT="${SERVER_PORT:-3000}"
SERVER_URL="${SERVER_URL:-http://localhost:${SERVER_PORT}/display.html}"

CHROMIUM_BIN="${CHROMIUM_BIN:-}"
if [ -z "$CHROMIUM_BIN" ]; then
  CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
fi

if [ -z "$CHROMIUM_BIN" ]; then
  echo "Fluid kiosk could not find chromium-browser or chromium." >&2
  exit 1
fi

# Launch Chromium in kiosk mode
exec "$CHROMIUM_BIN" \
  --kiosk \
  --no-sandbox \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-restore-session-state \
  --autoplay-policy=no-user-gesture-required \
  --disable-background-timer-throttling \
  --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  --disable-features=TranslateUI \
  --no-first-run \
  --fast \
  --fast-start \
  --disable-default-apps \
  --disable-popup-blocking \
  --disable-prompt-on-repost \
  --disable-hang-monitor \
  --disable-client-side-phishing-detection \
  --disable-sync \
  --metrics-recording-only \
  --safebrowsing-disable-auto-update \
  --password-store=basic \
  --use-mock-keychain \
  --window-position=0,0 \
  --start-fullscreen \
  --app="$SERVER_URL"
