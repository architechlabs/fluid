#!/usr/bin/env bash
# Native Cast Gateway helper for Fluid.
# This manages optional OS-level receiver backends without touching the browser wall.

set -Eeuo pipefail

MODE="${1:-status}"
CONFIG_FILE="${FLUID_CONFIG:-/etc/fluid/fluid.env}"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

NATIVE_CAST_ENABLED="${NATIVE_CAST_ENABLED:-false}"
CAST_NAME="${CAST_NAME:-Fluid}"
NATIVE_CAST_MODE="${NATIVE_CAST_MODE:-all}"
AIRPLAY_ENABLED="${AIRPLAY_ENABLED:-true}"
AIRPLAY_PIN="${AIRPLAY_PIN:-}"
AIRPLAY_EXTRA_ARGS="${AIRPLAY_EXTRA_ARGS:--p}"
MIRACAST_ENABLED="${MIRACAST_ENABLED:-true}"
MIRACAST_LINK="${MIRACAST_LINK:-auto}"
MIRACAST_RTSP_PORT="${MIRACAST_RTSP_PORT:-7236}"
MIRACAST_SCALE="${MIRACAST_SCALE:-1920x1080}"
MIRACAST_DISCOVERY_TIMEOUT="${MIRACAST_DISCOVERY_TIMEOUT:-12s}"

have() {
  command -v "$1" >/dev/null 2>&1
}

json_bool() {
  [[ "${1:-false}" == "true" ]] && printf "true" || printf "false"
}

status_json() {
  local airplay="missing"
  local miracast="not-installed"
  local airplay_service="unavailable"
  local miracast_service="unavailable"
  local wifi_ifaces=""

  have uxplay && airplay="available"
  if have miracle-sinkctl && have miracle-wifid; then
    miracast="detected"
  fi
  if have systemctl; then
    airplay_service="$(systemctl is-active fluid-native-cast.service 2>/dev/null || true)"
    miracast_service="$(systemctl is-active fluid-miracast.service 2>/dev/null || true)"
    [[ -n "$airplay_service" ]] || airplay_service="inactive"
    [[ -n "$miracast_service" ]] || miracast_service="inactive"
  fi
  if have iw; then
    wifi_ifaces="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | paste -sd, -)"
  fi

  cat <<EOF
{
  "enabled": $(json_bool "$NATIVE_CAST_ENABLED"),
  "name": "$(printf "%s" "$CAST_NAME" | sed 's/"/\\"/g')",
  "mode": "$NATIVE_CAST_MODE",
  "services": {
    "airplay": "$airplay_service",
    "miracast": "$miracast_service"
  },
  "wifiInterfaces": "$wifi_ifaces",
  "protocols": {
    "airplay": "$airplay",
    "miracast": "$miracast",
    "googleCast": "external"
  }
}
EOF
}

doctor() {
  local airplay_service="unavailable"
  local miracast_service="unavailable"
  if have systemctl; then
    airplay_service="$(systemctl is-active fluid-native-cast.service 2>/dev/null || true)"
    miracast_service="$(systemctl is-active fluid-miracast.service 2>/dev/null || true)"
    [[ -n "$airplay_service" ]] || airplay_service="inactive"
    [[ -n "$miracast_service" ]] || miracast_service="inactive"
  fi

  echo "Fluid Native Cast Gateway"
  echo "Name: ${CAST_NAME}"
  echo "Enabled: ${NATIVE_CAST_ENABLED}"
  echo "Mode: ${NATIVE_CAST_MODE}"
  echo "Config: ${CONFIG_FILE}"
  echo "AirPlay service: ${airplay_service}"
  echo "Miracast service: ${miracast_service}"
  if have uxplay; then
    echo "[ok] uxplay found for AirPlay"
  else
    echo "[warn] uxplay missing; AirPlay receiver will not start"
  fi
  if have gst-inspect-1.0 && gst-inspect-1.0 videoparsersbad >/dev/null 2>&1; then
    echo "[ok] GStreamer videoparsersbad plugin found for AirPlay"
  else
    echo "[warn] GStreamer videoparsersbad plugin missing; install gstreamer1.0-plugins-bad for AirPlay"
  fi
  if have miracle-sinkctl && have miracle-wifid; then
    echo "[ok] miraclecast sink tooling detected"
  else
    echo "[warn] miraclecast sink tooling not installed"
  fi
  if have iw; then
    echo "[info] Wi-Fi interfaces: $(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | paste -sd, -)"
  fi
  if [[ "$MIRACAST_LINK" == "auto" ]]; then
    echo "[warn] MIRACAST_LINK is auto; Windows Miracast may not become discoverable until a numeric link id is detected"
  else
    echo "[ok] MIRACAST_LINK=${MIRACAST_LINK}"
  fi
  echo "[info] iPhone/macOS look in Screen Mirroring/AirPlay, not Chrome Cast"
  echo "[info] Windows uses Wireless Display/Miracast, not Chrome Cast"
  echo "[info] Many Android phones use Google Cast, not Miracast"
  echo "[info] Google Cast receiver support requires an external Cast receiver implementation"
}

run_airplay() {
  if [[ "$NATIVE_CAST_ENABLED" != "true" ]]; then
    echo "Native cast gateway disabled. Set NATIVE_CAST_ENABLED=true in /etc/fluid/fluid.env."
    exit 0
  fi
  if [[ "$AIRPLAY_ENABLED" != "true" || ! "$NATIVE_CAST_MODE" =~ ^(all|airplay)$ ]]; then
    echo "AirPlay receiver disabled by config."
    exit 0
  fi

  if ! have uxplay; then
    echo "uxplay is not installed; AirPlay receiver cannot start."
    echo "Re-run install.sh --with-native-cast, or install uxplay from your Raspberry Pi OS repositories."
    exit 0
  fi
  if ! have gst-inspect-1.0 || ! gst-inspect-1.0 videoparsersbad >/dev/null 2>&1; then
    echo "AirPlay receiver cannot start because GStreamer videoparsersbad is missing."
    echo "Run: sudo apt-get update && sudo apt-get install -y gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-plugins-good gstreamer1.0-plugins-base gstreamer1.0-tools"
    echo "Then run: sudo systemctl restart fluid-native-cast"
    exit 0
  fi

  echo "Starting AirPlay receiver as '${CAST_NAME}'"
  args=(-n "$CAST_NAME" -nh -fs)
  if [[ -n "$AIRPLAY_PIN" ]]; then
    args+=("-pin${AIRPLAY_PIN}")
  fi
  if [[ -n "$AIRPLAY_EXTRA_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra=($AIRPLAY_EXTRA_ARGS)
    args+=("${extra[@]}")
  fi
  exec uxplay "${args[@]}"
}

run_miracast() {
  if [[ "$NATIVE_CAST_ENABLED" != "true" ]]; then
    echo "Native cast gateway disabled. Set NATIVE_CAST_ENABLED=true in /etc/fluid/fluid.env."
    exit 0
  fi
  if [[ "$MIRACAST_ENABLED" != "true" || ! "$NATIVE_CAST_MODE" =~ ^(all|miracast)$ ]]; then
    echo "Miracast receiver disabled by config."
    exit 0
  fi
  if ! have miracle-wifid || ! have miracle-sinkctl; then
    echo "miraclecast tools are not installed; Miracast receiver cannot start."
    echo "Re-run install.sh --with-native-cast, or install miraclecast for your Raspberry Pi OS release."
    exit 0
  fi
  if [[ "$EUID" -ne 0 ]]; then
    echo "Miracast requires root because Wi-Fi Direct sink mode controls wireless devices."
    exit 1
  fi

  mkdir -p /run/fluid
  rm -f /run/fluid/miracle-wifid.pid
  echo "Starting MiracleCast Wi-Fi daemon"
  miracle-wifid --log-level info &
  wifid_pid="$!"
  trap 'kill "$wifid_pid" 2>/dev/null || true' EXIT
  sleep 2

  link="$MIRACAST_LINK"
  if [[ "$link" == "auto" ]]; then
    echo "MIRACAST_LINK=auto is set. Trying to discover a Wi-Fi Direct link id..."
    output="$(timeout "$MIRACAST_DISCOVERY_TIMEOUT" miracle-sinkctl 2>&1 || true)"
    link="$(printf "%s\n" "$output" | awk '/\[ADD\][[:space:]]+Link:/ {print $NF; exit}')"
    if [[ ! "$link" =~ ^[0-9]+$ ]]; then
      echo "No MiracleCast link id was detected automatically."
      echo "The browser wall and other Fluid services are still safe to use."
      echo "If Miracast is required, re-run: sudo bash install.sh --with-native-cast"
      echo "Or set MIRACAST_LINK=<number> in /etc/fluid/fluid.env and restart fluid-miracast."
      exit 0
    fi
    echo "Detected Miracast link ${link}"
  fi

  echo "Starting Miracast sink on link ${link}, RTSP port ${MIRACAST_RTSP_PORT}, scale ${MIRACAST_SCALE}"
  printf 'run %s\n' "$link" | miracle-sinkctl --scale "$MIRACAST_SCALE" --port "$MIRACAST_RTSP_PORT"
}

case "$MODE" in
  status) status_json ;;
  doctor) doctor ;;
  run|run-airplay) run_airplay ;;
  run-miracast) run_miracast ;;
  *)
    echo "Usage: $0 {status|doctor|run|run-miracast}" >&2
    exit 2
    ;;
esac
