#!/usr/bin/env bash
# Fluid installer for Raspberry Pi OS.
# Run from a cloned repo: sudo bash install.sh

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/fluid"
SERVICE_USER="fluid"
CONFIG_DIR="/etc/fluid"
LOG_DIR="/var/log/fluid"
NODE_VERSION="20"
SERVER_PORT="3000"
APP_PORT=""
ADMIN_PIN=""
MAX_DEVICES="20"
WITH_HTTPS="true"
HTTPS_NAME=""
NO_REBOOT="false"
NO_START="false"
ASSUME_YES="false"

log()  { printf "%b[ok]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*"; }
info() { printf "%b[->]%b %s\n" "$CYAN" "$NC" "$*"; }
err()  { printf "%b[error]%b %s\n" "$RED" "$NC" "$*" >&2; exit 1; }
step() { printf "\n%b== %s ==%b\n" "$BOLD$BLUE" "$*" "$NC"; }

usage() {
  cat <<'USAGE'
Fluid installer

Usage:
  sudo bash install.sh [options]

Options:
  --admin-pin PIN       Admin dashboard PIN. Prompts if omitted.
  --port PORT           Server port. Default: 3000.
  --app-port PORT       Internal Node.js port when HTTPS is enabled. Auto-picked if omitted.
  --max-devices N       Max client devices. Default: 20.
  --install-dir PATH    Install directory. Default: /opt/fluid.
  --user NAME           Service user. Default: fluid.
  --with-https          Install nginx reverse proxy with a self-signed cert. Default.
  --no-https            Skip HTTPS reverse proxy setup.
  --https-name NAME     Certificate name/CN. Default: fluid.local.
  --no-reboot           Do not prompt for reboot.
  --no-start            Install only; do not start services.
  -y, --yes             Use safe defaults for prompts.
  -h, --help            Show this help.

Examples:
  sudo bash install.sh
  sudo bash install.sh --admin-pin 8432 --port 3000
  sudo bash install.sh --admin-pin "$PIN" --yes --no-reboot
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-pin) ADMIN_PIN="${2:-}"; shift 2 ;;
    --port) SERVER_PORT="${2:-}"; shift 2 ;;
    --app-port) APP_PORT="${2:-}"; shift 2 ;;
    --max-devices) MAX_DEVICES="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --user) SERVICE_USER="${2:-}"; shift 2 ;;
    --with-https) WITH_HTTPS="true"; shift ;;
    --no-https) WITH_HTTPS="false"; shift ;;
    --https-name) HTTPS_NAME="${2:-}"; shift 2 ;;
    --no-reboot) NO_REBOOT="true"; shift ;;
    --no-start) NO_START="true"; shift ;;
    -y|--yes) ASSUME_YES="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || err "Run as root: sudo bash install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/server.js" ]] || err "Run this installer from the Fluid repository root."
[[ -f "$SCRIPT_DIR/package.json" ]] || err "package.json is missing."
[[ -d "$SCRIPT_DIR/public" ]] || err "public/ directory is missing."

is_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

prompt_if_needed() {
  if [[ -z "$ADMIN_PIN" ]]; then
    if [[ "$ASSUME_YES" == "true" ]]; then
      ADMIN_PIN="0000"
    else
      read -r -p "Admin PIN [0000]: " ADMIN_PIN
      ADMIN_PIN="${ADMIN_PIN:-0000}"
    fi
  fi

  if [[ "$ASSUME_YES" != "true" && "$SERVER_PORT" == "3000" ]]; then
    read -r -p "Server port [3000]: " input_port
    SERVER_PORT="${input_port:-3000}"
  fi
}

validate_config() {
  is_number "$SERVER_PORT" || err "Port must be a number."
  (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 )) || err "Port must be between 1 and 65535."
  if [[ -n "$APP_PORT" ]]; then
    is_number "$APP_PORT" || err "App port must be a number."
    (( APP_PORT >= 1 && APP_PORT <= 65535 )) || err "App port must be between 1 and 65535."
    [[ "$APP_PORT" != "$SERVER_PORT" ]] || err "App port must be different from the public HTTPS port."
  fi
  is_number "$MAX_DEVICES" || err "Max devices must be a number."
  (( MAX_DEVICES >= 1 && MAX_DEVICES <= 250 )) || err "Max devices must be between 1 and 250."
  [[ -n "$ADMIN_PIN" ]] || err "Admin PIN cannot be empty."

  if [[ "$ADMIN_PIN" == "0000" ]]; then
    warn "Default admin PIN is enabled. Change it after install in ${CONFIG_DIR}/fluid.env."
  fi
}

choose_app_port() {
  if [[ "$WITH_HTTPS" != "true" ]]; then
    APP_PORT="$SERVER_PORT"
    return
  fi

  if [[ -n "$APP_PORT" ]]; then
    return
  fi

  if (( SERVER_PORT < 65535 )); then
    APP_PORT=$((SERVER_PORT + 1))
  else
    APP_PORT=$((SERVER_PORT - 1))
  fi
}

stop_existing_services() {
  step "Stopping existing services"
  systemctl stop fluid-display.service >/dev/null 2>&1 || true
  systemctl stop fluid-server.service >/dev/null 2>&1 || true
  systemctl stop nginx.service >/dev/null 2>&1 || true
  log "Existing Fluid/nginx services stopped"
}

show_port_owner() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :${port}" 2>/dev/null || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  fi
}

install_packages() {
  step "Installing system packages"
  apt-get update -qq
  apt-get install -y -qq \
    ca-certificates \
    curl \
    fonts-liberation \
    git \
    gnupg \
    lsb-release \
    openbox \
    rsync \
    unclutter \
    wget \
    xdotool \
    xinit \
    xorg \
    xserver-xorg-legacy

  if ! command -v chromium-browser >/dev/null 2>&1 && ! command -v chromium >/dev/null 2>&1; then
    local chromium_package=""
    if apt-cache show chromium >/dev/null 2>&1; then
      chromium_package="chromium"
    elif apt-cache show chromium-browser >/dev/null 2>&1; then
      chromium_package="chromium-browser"
    else
      err "Could not find chromium or chromium-browser in apt. Run apt update and confirm Raspberry Pi OS repositories are enabled."
    fi
    apt-get install -y -qq "$chromium_package"
  fi

  log "System packages ready"
}

install_node() {
  step "Installing Node.js ${NODE_VERSION}"
  local current_major="0"
  if command -v node >/dev/null 2>&1; then
    current_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  fi

  if ! is_number "$current_major" || (( current_major < NODE_VERSION )); then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
    apt-get install -y -qq nodejs
  fi

  log "Node $(node --version) ready"
}

create_user_and_dirs() {
  step "Preparing service user and directories"
  if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --create-home --shell /bin/bash "$SERVICE_USER"
    log "Created user ${SERVICE_USER}"
  else
    log "User ${SERVICE_USER} already exists"
  fi

  usermod -aG video,audio,input,render "$SERVICE_USER" || true
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
  chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
  chmod 755 "$LOG_DIR"
}

configure_xorg_kiosk() {
  step "Configuring HDMI kiosk session"
  mkdir -p /etc/X11
  cat > /etc/X11/Xwrapper.config <<EOF
allowed_users=anybody
needs_root_rights=yes
EOF
  log "Xorg kiosk permissions configured"
}

install_app() {
  step "Installing application files"
  rsync -a \
    --exclude ".git" \
    --exclude ".env" \
    --exclude "node_modules" \
    --exclude "graphify-out" \
    "$SCRIPT_DIR/" "$INSTALL_DIR/"

  cd "$INSTALL_DIR"
  if [[ -f package-lock.json ]]; then
    npm ci --omit=dev --quiet
  else
    npm install --omit=dev --quiet
  fi

  chmod +x "$INSTALL_DIR/start-kiosk.sh"
  chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
  log "Installed to ${INSTALL_DIR}"
}

write_config() {
  step "Writing configuration"
  local chromium_bin
  chromium_bin="$(command -v chromium-browser || command -v chromium || true)"
  [[ -n "$chromium_bin" ]] || err "Chromium was not found after package installation."

  local app_host="0.0.0.0"
  local kiosk_url="http://127.0.0.1:${APP_PORT}/display.html"
  if [[ "$WITH_HTTPS" == "true" ]]; then
    app_host="127.0.0.1"
  fi

  cat > "$CONFIG_DIR/fluid.env" <<EOF
HOST=${app_host}
PORT=${APP_PORT}
SERVER_PORT=${SERVER_PORT}
ADMIN_PIN=${ADMIN_PIN}
MAX_DEVICES=${MAX_DEVICES}
LOG_FILE=${LOG_DIR}/server.log
CHROMIUM_BIN=${chromium_bin}
HTTPS_REDIRECT=${WITH_HTTPS}
# Override to force the kiosk to open a different address:
SERVER_URL=${kiosk_url}
EOF

  chmod 640 "$CONFIG_DIR/fluid.env"
  chown root:"$SERVICE_USER" "$CONFIG_DIR/fluid.env" || true
  log "Config written to ${CONFIG_DIR}/fluid.env"
}

install_services() {
  step "Installing systemd services"
  local server_tmp display_tmp
  server_tmp="$(mktemp)"
  display_tmp="$(mktemp)"

  sed \
    -e "s|User=fluid|User=${SERVICE_USER}|g" \
    -e "s|Group=fluid|Group=${SERVICE_USER}|g" \
    -e "s|WorkingDirectory=/opt/fluid|WorkingDirectory=${INSTALL_DIR}|g" \
    -e "s|ExecStart=/usr/bin/node /opt/fluid/server.js|ExecStart=/usr/bin/node ${INSTALL_DIR}/server.js|g" \
    "$SCRIPT_DIR/systemd/fluid-server.service" > "$server_tmp"

  sed \
    -e "s|User=fluid|User=${SERVICE_USER}|g" \
    -e "s|Group=fluid|Group=${SERVICE_USER}|g" \
    -e "s|/opt/fluid/start-kiosk.sh|${INSTALL_DIR}/start-kiosk.sh|g" \
    -e "s|/home/fluid/.Xauthority|/home/${SERVICE_USER}/.Xauthority|g" \
    "$SCRIPT_DIR/systemd/fluid-display.service" > "$display_tmp"

  install -m 0644 "$server_tmp" /etc/systemd/system/fluid-server.service
  install -m 0644 "$display_tmp" /etc/systemd/system/fluid-display.service
  rm -f "$server_tmp" "$display_tmp"

  systemctl daemon-reload
  systemctl enable fluid-server.service
  systemctl enable fluid-display.service
  log "Services enabled"
}

configure_boot() {
  step "Configuring Raspberry Pi display settings"
  raspi-config nonint do_boot_behaviour B2 >/dev/null 2>&1 || true

  local config_file="/boot/firmware/config.txt"
  [[ -f "$config_file" ]] || config_file="/boot/config.txt"
  if [[ -f "$config_file" ]]; then
    if grep -q "^gpu_mem=" "$config_file"; then
      sed -i 's/^gpu_mem=.*/gpu_mem=128/' "$config_file"
    else
      printf "\ngpu_mem=128\n" >> "$config_file"
    fi

    grep -q "^disable_overscan=1" "$config_file" || printf "disable_overscan=1\n" >> "$config_file"
    log "Updated ${config_file}"
  else
    warn "Could not find Raspberry Pi boot config; skipped GPU/overscan tuning."
  fi
}

configure_https() {
  [[ "$WITH_HTTPS" == "true" ]] || return 0

  step "Configuring HTTPS reverse proxy"
  HTTPS_NAME="${HTTPS_NAME:-fluid.local}"
  apt-get install -y -qq nginx openssl

  rm -f \
    /etc/nginx/sites-enabled/fluid \
    /etc/nginx/sites-available/fluid \
    /etc/nginx/sites-enabled/default

  local ssl_listen_lines
  if [[ "$SERVER_PORT" == "443" ]]; then
    ssl_listen_lines="    listen 443 ssl;"
  else
    ssl_listen_lines="    listen ${SERVER_PORT} ssl;"
  fi

  local redirect_target
  if [[ "$SERVER_PORT" == "443" ]]; then
    redirect_target='https://$host$request_uri'
  else
    redirect_target="https://\$host:${SERVER_PORT}\$request_uri"
  fi

  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/ssl/fluid.key \
    -out /etc/ssl/fluid.crt \
    -subj "/CN=${HTTPS_NAME}" >/dev/null 2>&1

  cat > /etc/nginx/sites-available/fluid <<EOF
server {
${ssl_listen_lines}
    server_name _;

    ssl_certificate     /etc/ssl/fluid.crt;
    ssl_certificate_key /etc/ssl/fluid.key;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name _;
    return 301 ${redirect_target};
}
EOF

  ln -sf /etc/nginx/sites-available/fluid /etc/nginx/sites-enabled/fluid
  nginx -t
  systemctl enable nginx
  if ! systemctl restart nginx; then
    warn "nginx could not start. Port ${SERVER_PORT} or port 80 may already be in use."
    info "Port ${SERVER_PORT}:"
    show_port_owner "$SERVER_PORT"
    info "Port 80:"
    show_port_owner 80
    err "Fix the port conflict above, or re-run with a different --port."
  fi
  log "HTTPS ready with self-signed certificate CN=${HTTPS_NAME}"
}

start_services() {
  [[ "$NO_START" == "true" ]] && return 0

  step "Starting services"
  systemctl restart fluid-server.service
  systemctl restart fluid-display.service || warn "Display service did not start yet. It may need HDMI/Xorg and a reboot."
  log "Server service started"
}

print_summary() {
  local ips
  ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)"

  printf "\n%bFluid is installed.%b\n\n" "$BOLD$GREEN" "$NC"
  printf "Config:   %s\n" "$CONFIG_DIR/fluid.env"
  printf "App:      %s\n" "$INSTALL_DIR"
  printf "Logs:     %s/server.log\n\n" "$LOG_DIR"

  if [[ -n "$ips" ]]; then
    printf "Open from another device on the same network:\n"
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      if [[ "$WITH_HTTPS" == "true" ]]; then
        if [[ "$SERVER_PORT" == "443" ]]; then
          printf "  https://%s/client.html\n" "$ip"
          printf "  https://%s/admin.html\n" "$ip"
        else
          printf "  https://%s:%s/client.html\n" "$ip" "$SERVER_PORT"
          printf "  https://%s:%s/admin.html\n" "$ip" "$SERVER_PORT"
        fi
      else
        printf "  http://%s:%s/client.html\n" "$ip" "$SERVER_PORT"
        printf "  http://%s:%s/admin.html\n" "$ip" "$SERVER_PORT"
      fi
    done <<< "$ips"
  else
    if [[ "$WITH_HTTPS" == "true" && "$SERVER_PORT" != "443" ]]; then
      printf "Open: https://<pi-ip>:%s/client.html\n" "$SERVER_PORT"
    elif [[ "$WITH_HTTPS" == "true" ]]; then
      printf "Open: https://<pi-ip>/client.html\n"
    else
      printf "Open: http://<pi-ip>:%s/client.html\n" "$SERVER_PORT"
    fi
  fi

  printf "\nUseful commands:\n"
  printf "  sudo systemctl status fluid-server\n"
  printf "  sudo journalctl -u fluid-server -f\n"
  printf "  sudo nano %s/fluid.env\n" "$CONFIG_DIR"
  printf "  sudo systemctl restart fluid-server fluid-display\n"
}

maybe_reboot() {
  [[ "$NO_REBOOT" == "true" ]] && return 0
  [[ "$ASSUME_YES" == "true" ]] && return 0

  printf "\n"
  read -r -p "Reboot now so display settings take effect? [y/N]: " reboot_now
  if [[ "${reboot_now,,}" == "y" ]]; then
    reboot
  fi
}

main() {
  printf "\n%bFluid installer%b\n" "$BOLD$BLUE" "$NC"
  printf "Screen sharing hub for Raspberry Pi\n\n"

  prompt_if_needed
  validate_config
  choose_app_port
  stop_existing_services
  install_packages
  install_node
  create_user_and_dirs
  configure_xorg_kiosk
  install_app
  write_config
  install_services
  configure_boot
  configure_https
  start_services
  print_summary
  maybe_reboot
}

main "$@"
