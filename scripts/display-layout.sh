#!/usr/bin/env bash
# Fluid HDMI display layout manager.
# Keeps the browser wall and OS-level cast receiver windows arranged together.

set -Eeuo pipefail

ACTION="${1:-status}"
REQUESTED_MODE="${2:-}"
CONFIG_FILE="${FLUID_CONFIG:-/etc/fluid/fluid.env}"

if [[ -r "$CONFIG_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

DISPLAY="${DISPLAY:-:0}"
XAUTHORITY="${XAUTHORITY:-/home/${USER:-fluid}/.Xauthority}"
STATE_DIR="${FLUID_STATE_DIR:-/var/lib/fluid}"
MODE_FILE="${DISPLAY_LAYOUT_MODE_FILE:-${STATE_DIR}/display-layout.mode}"
STATUS_FILE="${DISPLAY_LAYOUT_STATUS_FILE:-${STATE_DIR}/display-layout.status.json}"
SIGNATURE_FILE="${DISPLAY_LAYOUT_SIGNATURE_FILE:-${STATE_DIR}/display-layout.signature}"
DEFAULT_MODE="${DISPLAY_LAYOUT_MODE:-auto}"
POLL_SECONDS="${DISPLAY_LAYOUT_POLL_SECONDS:-1}"
MIN_NATIVE_WIDTH="${DISPLAY_LAYOUT_MIN_NATIVE_WIDTH:-360}"
MIN_NATIVE_HEIGHT="${DISPLAY_LAYOUT_MIN_NATIVE_HEIGHT:-240}"

export DISPLAY XAUTHORITY

have() {
  command -v "$1" >/dev/null 2>&1
}

json_escape() {
  printf "%s" "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

valid_mode() {
  [[ "${1:-}" =~ ^(auto|browser|native|split)$ ]]
}

prepare_state_dir() {
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    return 0
  fi
  STATE_DIR="/tmp/fluid"
  MODE_FILE="${STATE_DIR}/display-layout.mode"
  STATUS_FILE="${STATE_DIR}/display-layout.status.json"
  SIGNATURE_FILE="${STATE_DIR}/display-layout.signature"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

read_mode() {
  local mode="$DEFAULT_MODE"
  if [[ -f "$MODE_FILE" ]]; then
    mode="$(tr -d '\r\n\t ' < "$MODE_FILE" 2>/dev/null || true)"
  fi
  valid_mode "$mode" || mode="auto"
  printf "%s\n" "$mode"
}

write_mode() {
  local mode="$1"
  valid_mode "$mode" || {
    echo "Invalid layout mode: ${mode}" >&2
    exit 2
  }
  prepare_state_dir
  printf "%s\n" "$mode" > "$MODE_FILE"
}

display_ready() {
  have xset || return 1
  xset q >/dev/null 2>&1
}

screen_size() {
  local dimensions
  if have xdpyinfo; then
    dimensions="$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}' || true)"
    if [[ "$dimensions" =~ ^[0-9]+x[0-9]+$ ]]; then
      printf "%s %s\n" "${dimensions%x*}" "${dimensions#*x}"
      return 0
    fi
  fi
  if have xrandr; then
    dimensions="$(xrandr --query 2>/dev/null | awk '/\*/ {print $1; exit}' || true)"
    if [[ "$dimensions" =~ ^[0-9]+x[0-9]+$ ]]; then
      printf "%s %s\n" "${dimensions%x*}" "${dimensions#*x}"
      return 0
    fi
  fi
  printf "%s %s\n" "${KIOSK_WIDTH:-1920}" "${KIOSK_HEIGHT:-1080}"
}

window_pid() {
  xdotool getwindowpid "$1" 2>/dev/null || true
}

window_name() {
  xdotool getwindowname "$1" 2>/dev/null || true
}

window_class() {
  xprop -id "$1" WM_CLASS 2>/dev/null | sed -n 's/.*= //p' || true
}

window_cmd() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ && -r "/proc/${pid}/cmdline" ]] || return 0
  tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true
}

window_geometry() {
  xdotool getwindowgeometry --shell "$1" 2>/dev/null || true
}

window_area_large_enough() {
  local wid="$1" width height
  width="$(window_geometry "$wid" | awk -F= '$1=="WIDTH"{print $2; exit}')"
  height="$(window_geometry "$wid" | awk -F= '$1=="HEIGHT"{print $2; exit}')"
  [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || return 1
  (( width >= MIN_NATIVE_WIDTH && height >= MIN_NATIVE_HEIGHT ))
}

is_browser_window() {
  local wid="$1" pid name class cmd
  pid="$(window_pid "$wid")"
  name="$(window_name "$wid")"
  class="$(window_class "$wid")"
  cmd="$(window_cmd "$pid")"
  printf "%s\n%s\n%s\n" "$name" "$class" "$cmd" | grep -Eiq 'display\.html|fluid.*display|chromium|chrome' || return 1
  printf "%s\n%s\n" "$name" "$cmd" | grep -Eiq 'admin\.html|client\.html' && return 1
  return 0
}

is_ignored_window() {
  local wid="$1" name class
  name="$(window_name "$wid")"
  class="$(window_class "$wid")"
  [[ -z "$name" ]] && return 0
  printf "%s\n%s\n" "$name" "$class" | grep -Eiq 'openbox|desktop|panel|unclutter|chromium clipboard' && return 0
  return 1
}

is_native_cast_window() {
  local wid="$1" pid name class cmd
  is_browser_window "$wid" && return 1
  is_ignored_window "$wid" && return 1
  window_area_large_enough "$wid" || return 1
  pid="$(window_pid "$wid")"
  name="$(window_name "$wid")"
  class="$(window_class "$wid")"
  cmd="$(window_cmd "$pid")"
  printf "%s\n%s\n%s\n" "$name" "$class" "$cmd" | grep -Eiq 'uxplay|airplay|gstreamer|gst-|miracle|miracast|wireless display|wlroots' && return 0
  return 0
}

visible_windows() {
  have xdotool || return 0
  xdotool search --onlyvisible --name '.*' 2>/dev/null || true
}

browser_windows() {
  local wid
  for wid in $(visible_windows); do
    is_browser_window "$wid" && printf "%s\n" "$wid"
  done
}

native_windows() {
  local wid
  for wid in $(visible_windows); do
    is_native_cast_window "$wid" && printf "%s\n" "$wid"
  done
}

remove_fullscreen() {
  local wid="$1"
  if have wmctrl; then
    wmctrl -ir "$wid" -b remove,fullscreen,maximized_vert,maximized_horz 2>/dev/null || true
  fi
}

add_fullscreen() {
  local wid="$1"
  if have wmctrl; then
    wmctrl -ir "$wid" -b add,fullscreen 2>/dev/null || true
  fi
}

place_window() {
  local wid="$1" x="$2" y="$3" w="$4" h="$5"
  [[ -n "$wid" ]] || return 0
  xdotool windowmap "$wid" 2>/dev/null || true
  remove_fullscreen "$wid"
  xdotool windowmove "$wid" "$x" "$y" 2>/dev/null || true
  xdotool windowsize "$wid" "$w" "$h" 2>/dev/null || true
}

raise_window() {
  local wid="$1"
  [[ -n "$wid" ]] || return 0
  xdotool windowmap "$wid" 2>/dev/null || true
  xdotool windowraise "$wid" 2>/dev/null || true
}

apply_layout() {
  local force="${1:-false}"
  prepare_state_dir
  display_ready || {
    write_status "$(read_mode)" "waiting-for-display" "" ""
    return 0
  }
  have xdotool || {
    write_status "$(read_mode)" "missing-xdotool" "" ""
    return 0
  }

  local mode effective width height browser native_count native_list
  mapfile -t browsers < <(browser_windows)
  mapfile -t natives < <(native_windows)
  mode="$(read_mode)"
  effective="$mode"
  read -r width height < <(screen_size)
  browser="${browsers[0]:-}"
  native_count="${#natives[@]}"
  native_list="$(IFS=,; printf "%s" "${natives[*]:-}")"

  if [[ "$mode" == "auto" ]]; then
    if (( native_count > 0 )); then
      effective="split"
    else
      effective="browser"
    fi
  elif [[ "$mode" =~ ^(split|native)$ && $native_count -eq 0 ]]; then
    effective="browser"
  fi

  local signature previous_signature
  signature="${mode}|${effective}|${width}x${height}|${browser}|${native_list}"
  previous_signature="$(cat "$SIGNATURE_FILE" 2>/dev/null || true)"
  if [[ "$force" != "true" && "$signature" == "$previous_signature" ]]; then
    write_status "$mode" "$effective" "$browser" "$native_list"
    return 0
  fi

  case "$effective" in
    browser)
      if [[ -n "$browser" ]]; then
        place_window "$browser" 0 0 "$width" "$height"
        add_fullscreen "$browser"
        raise_window "$browser"
      fi
      ;;
    native)
      if (( native_count > 0 )); then
        place_window "${natives[0]}" 0 0 "$width" "$height"
        add_fullscreen "${natives[0]}"
        raise_window "${natives[0]}"
      elif [[ -n "$browser" ]]; then
        place_window "$browser" 0 0 "$width" "$height"
        add_fullscreen "$browser"
        raise_window "$browser"
      fi
      ;;
    split)
      if [[ -n "$browser" && $native_count -gt 0 ]]; then
        local left_w right_w each_h idx
        left_w=$(( width / 2 ))
        right_w=$(( width - left_w ))
        place_window "$browser" 0 0 "$left_w" "$height"
        each_h=$(( height / native_count ))
        (( each_h < 1 )) && each_h="$height"
        for idx in "${!natives[@]}"; do
          local y h
          y=$(( idx * each_h ))
          h="$each_h"
          if (( idx == native_count - 1 )); then
            h=$(( height - y ))
          fi
          place_window "${natives[$idx]}" "$left_w" "$y" "$right_w" "$h"
          raise_window "${natives[$idx]}"
        done
        raise_window "$browser"
      elif (( native_count > 0 )); then
        place_window "${natives[0]}" 0 0 "$width" "$height"
        raise_window "${natives[0]}"
      elif [[ -n "$browser" ]]; then
        place_window "$browser" 0 0 "$width" "$height"
        add_fullscreen "$browser"
        raise_window "$browser"
      fi
      ;;
  esac

  printf "%s\n" "$signature" > "$SIGNATURE_FILE" 2>/dev/null || true
  write_status "$mode" "$effective" "$browser" "$native_list"
}

write_status() {
  local mode="$1" effective="$2" browser="$3" native_list="$4"
  local browser_count native_count now
  browser_count=0
  native_count=0
  [[ -n "$browser" ]] && browser_count=1
  [[ -n "$native_list" ]] && native_count="$(awk -F, '{print NF}' <<< "$native_list")"
  now="$(date -Iseconds 2>/dev/null || date)"
  cat > "$STATUS_FILE" <<EOF
{
  "configuredMode": "$(json_escape "$mode")",
  "effectiveMode": "$(json_escape "$effective")",
  "browserWindows": ${browser_count},
  "nativeWindows": ${native_count},
  "browserWindow": "$(json_escape "$browser")",
  "nativeWindowIds": "$(json_escape "$native_list")",
  "updatedAt": "$(json_escape "$now")"
}
EOF
}

status_json() {
  prepare_state_dir
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    cat <<EOF
{
  "configuredMode": "$(json_escape "$(read_mode)")",
  "effectiveMode": "unknown",
  "browserWindows": 0,
  "nativeWindows": 0,
  "browserWindow": "",
  "nativeWindowIds": "",
  "updatedAt": ""
}
EOF
  fi
}

watch_layout() {
  prepare_state_dir
  printf "" > "$SIGNATURE_FILE" 2>/dev/null || true
  valid_mode "$(read_mode)" || write_mode "auto"
  while true; do
    apply_layout || true
    sleep "$POLL_SECONDS"
  done
}

case "$ACTION" in
  status) status_json ;;
  apply) apply_layout ;;
  set)
    write_mode "$REQUESTED_MODE"
    apply_layout true || true
    status_json
    ;;
  watch) watch_layout ;;
  *)
    echo "Usage: $0 {status|apply|watch|set MODE}" >&2
    exit 2
    ;;
esac
