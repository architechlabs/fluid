#!/bin/bash
# Fluid Kiosk Launch Script
# Runs inside startx — sets up X environment and launches Chromium in kiosk mode

export DISPLAY=:0

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms

# Keep the X desktop and Chromium viewport pinned to the active HDMI panel.
# If KIOSK_WIDTH/HEIGHT are not configured, use the current X mode so 4K TVs
# do not end up with a tiny Chromium window stuck in the top-left corner.
# Fluid defaults to a 1080p HDMI surface because Raspberry Pi browser decode and
# repaint are much smoother at 60Hz than on many 4K TVs that expose only 30Hz.
KIOSK_WIDTH="${KIOSK_WIDTH:-}"
KIOSK_HEIGHT="${KIOSK_HEIGHT:-}"
KIOSK_MAX_WIDTH="${KIOSK_MAX_WIDTH:-1920}"
KIOSK_MAX_HEIGHT="${KIOSK_MAX_HEIGHT:-1080}"
KIOSK_TARGET_REFRESH="${KIOSK_TARGET_REFRESH:-60}"
if command -v xrandr >/dev/null 2>&1; then
  PRIMARY_OUTPUT="$(xrandr --query | awk '/ connected/{print $1; exit}')"
  if [ -n "$PRIMARY_OUTPUT" ]; then
    if [ -z "$KIOSK_WIDTH" ] || [ -z "$KIOSK_HEIGHT" ]; then
      PREFERRED_MODE="$(xrandr --query | awk -v maxw="$KIOSK_MAX_WIDTH" -v maxh="$KIOSK_MAX_HEIGHT" -v target="$KIOSK_TARGET_REFRESH" '
        $1 ~ /^[0-9]+x[0-9]+$/ {
          split($1, size, "x")
          width=size[1]+0
          height=size[2]+0
          if (width <= maxw && height <= maxh) {
            for (i=2; i<=NF; i++) {
              refresh=$i
              gsub(/[+*]/, "", refresh)
              hz=refresh+0
              score=(width * height * 10000)
              if (hz <= target) score += hz
              else score -= (hz - target)
              if (score > bestScore) {
                bestScore=score
                bestMode=$1
                bestRefresh=refresh
              }
            }
          }
        }
        END {
          if (bestMode != "") printf "%s %s\n", bestMode, bestRefresh
        }')"
      if [ -n "$PREFERRED_MODE" ]; then
        PREFERRED_SIZE="${PREFERRED_MODE%% *}"
        PREFERRED_RATE="${PREFERRED_MODE#* }"
        if [ "$PREFERRED_SIZE" != "$PREFERRED_RATE" ]; then
          xrandr --output "$PRIMARY_OUTPUT" --mode "$PREFERRED_SIZE" --rate "$PREFERRED_RATE" --pos 0x0 --scale 1x1 2>/dev/null || \
            xrandr --output "$PRIMARY_OUTPUT" --mode "$PREFERRED_SIZE" --pos 0x0 --scale 1x1 2>/dev/null || true
        else
          xrandr --output "$PRIMARY_OUTPUT" --mode "$PREFERRED_SIZE" --pos 0x0 --scale 1x1 2>/dev/null || true
        fi
      else
        xrandr --output "$PRIMARY_OUTPUT" --auto --pos 0x0 --scale 1x1 2>/dev/null || true
      fi
    else
      xrandr --output "$PRIMARY_OUTPUT" --mode "${KIOSK_WIDTH}x${KIOSK_HEIGHT}" --pos 0x0 --scale 1x1 2>/dev/null || \
        xrandr --output "$PRIMARY_OUTPUT" --auto --pos 0x0 --scale 1x1 2>/dev/null || true
    fi
  fi
  if [ -z "$KIOSK_WIDTH" ] || [ -z "$KIOSK_HEIGHT" ]; then
    CURRENT_MODE="$(xrandr --query | awk '/\*/{print $1; exit}')"
    if echo "$CURRENT_MODE" | grep -Eq '^[0-9]+x[0-9]+$'; then
      KIOSK_WIDTH="${CURRENT_MODE%x*}"
      KIOSK_HEIGHT="${CURRENT_MODE#*x}"
    fi
  fi
fi
KIOSK_WIDTH="${KIOSK_WIDTH:-1920}"
KIOSK_HEIGHT="${KIOSK_HEIGHT:-1080}"

# Hide cursor (requires unclutter)
command -v unclutter >/dev/null 2>&1 && unclutter -idle 1 -root &

# Run a tiny window manager so native receiver windows can be raised above the
# browser kiosk when a protocol such as AirPlay renders outside Fluid.
if command -v openbox >/dev/null 2>&1; then
  openbox >/tmp/fluid-openbox.log 2>&1 &
  sleep 1
fi

# Kill any existing Chromium instances
pkill -f chromium 2>/dev/null || true
sleep 1

# Remove Chromium crash flags that prevent kiosk from starting
PREFS_DIR="${HOME:-/home/fluid}/.config/chromium/Default"
mkdir -p "$PREFS_DIR"
if [ -f "$PREFS_DIR/Preferences" ]; then
  # Reset "exited_cleanly" to prevent the "Chromium didn't shut down correctly" banner
  sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g' "$PREFS_DIR/Preferences" 2>/dev/null || true
  sed -i 's/"exited_cleanly":false/"exited_cleanly":true/g' "$PREFS_DIR/Preferences" 2>/dev/null || true
fi

# Server URL - using localhost since display runs on the Pi by default
SERVER_PORT="${SERVER_PORT:-3000}"
SERVER_URL="${SERVER_URL:-http://localhost:${SERVER_PORT}/display.html}"
CHROMIUM_LOCKED_KIOSK="${CHROMIUM_LOCKED_KIOSK:-true}"

CHROMIUM_BIN="${CHROMIUM_BIN:-}"
if [ -z "$CHROMIUM_BIN" ]; then
  CHROMIUM_BIN="$(command -v chromium-browser || command -v chromium || true)"
fi

if [ -z "$CHROMIUM_BIN" ]; then
  echo "Fluid kiosk could not find chromium-browser or chromium." >&2
  exit 1
fi

# Launch Chromium as an app window. Strict Chromium kiosk mode resists resizing,
# so the default keeps the window manageable by Fluid's display layout service.
CHROMIUM_ARGS=()
if [ "$CHROMIUM_LOCKED_KIOSK" = "true" ]; then
  CHROMIUM_ARGS+=(--kiosk)
fi

exec "$CHROMIUM_BIN" \
  "${CHROMIUM_ARGS[@]}" \
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
  --window-size="${KIOSK_WIDTH},${KIOSK_HEIGHT}" \
  --force-device-scale-factor=1 \
  --high-dpi-support=1 \
  --start-fullscreen \
  --app="$SERVER_URL"
