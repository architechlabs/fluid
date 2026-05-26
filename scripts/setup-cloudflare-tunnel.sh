#!/usr/bin/env bash
# Configure a Cloudflare Tunnel for Fluid.
# Run on the Raspberry Pi:
#   sudo bash scripts/setup-cloudflare-tunnel.sh

set -Eeuo pipefail

HOSTNAME_DEFAULT="fluid.vipsy.in"
TUNNEL_NAME_DEFAULT="fluid"
CONFIG_DIR="/etc/cloudflared"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
SERVICE_FILE="/etc/systemd/system/cloudflared.service"
FLUID_ENV="/etc/fluid/fluid.env"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
bold='\033[1m'
nc='\033[0m'

ok() { printf "%b[ok]%b %s\n" "$green" "$nc" "$*"; }
warn() { printf "%b[!]%b %s\n" "$yellow" "$nc" "$*"; }
info() { printf "%b[->]%b %s\n" "$blue" "$nc" "$*"; }
die() { printf "%b[error]%b %s\n" "$red" "$nc" "$*" >&2; exit 1; }
step() { printf "\n%b== %s ==%b\n" "$bold$blue" "$*" "$nc"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo bash scripts/setup-cloudflare-tunnel.sh"

have() {
  command -v "$1" >/dev/null 2>&1
}

read_env_value() {
  local key="$1"
  [[ -f "$FLUID_ENV" ]] || return 0
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$FLUID_ENV" 2>/dev/null || true
}

install_cloudflared() {
  if have cloudflared; then
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null || true)"
    return 0
  fi

  step "Installing cloudflared"
  local arch deb_arch url tmpdir deb
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) deb_arch="amd64" ;;
    aarch64|arm64) deb_arch="arm64" ;;
    armv7l|armv6l|armhf) deb_arch="arm" ;;
    *) die "Unsupported architecture for automatic cloudflared install: ${arch}" ;;
  esac

  tmpdir="$(mktemp -d)"
  deb="${tmpdir}/cloudflared.deb"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${deb_arch}.deb"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
  curl -fsSL "$url" -o "$deb"
  apt-get install -y -qq "$deb"
  rm -rf "$tmpdir"
  ok "Installed $(cloudflared --version)"
}

write_service_for_named_tunnel() {
  local bin_path
  bin_path="$(command -v cloudflared)"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel for Fluid
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin_path} --config ${CONFIG_FILE} tunnel run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared.service
}

validate_public_url() {
  local hostname="$1"
  step "Validating public URL"
  info "Checking https://${hostname}/api/health"
  local attempt status
  for attempt in $(seq 1 30); do
    status="$(curl -kfsS --max-time 8 "https://${hostname}/api/health" 2>/dev/null | awk -F\" '/"status"/ {print $4; exit}' || true)"
    if [[ "$status" == "ok" ]]; then
      ok "Public tunnel is working: https://${hostname}"
      return 0
    fi
    sleep 2
  done
  warn "Tunnel service is installed, but public validation did not return status=ok yet."
  warn "DNS/Cloudflare propagation can take a little while. Check: journalctl -u cloudflared -f"
}

read_fluid_env_value() {
  local key="$1"
  [[ -f "$FLUID_ENV" ]] || return 0
  awk -F= -v key="$key" '$1 == key {print substr($0, length(key) + 2); exit}' "$FLUID_ENV" 2>/dev/null || true
}

set_fluid_env_value() {
  local key="$1" value="$2" tmp
  [[ -f "$FLUID_ENV" ]] || die "${FLUID_ENV} was not found. Run the Fluid installer first."
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { written = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      written = 1
      next
    }
    { print }
    END {
      if (!written) print key "=" value
    }
  ' "$FLUID_ENV" > "$tmp"
  install -m 0640 -o root -g fluid "$tmp" "$FLUID_ENV" 2>/dev/null || install -m 0640 "$tmp" "$FLUID_ENV"
  rm -f "$tmp"
}

configure_turn_for_tunnel() {
  local existing_urls answer urls username credential policy
  existing_urls="$(read_fluid_env_value RTC_TURN_URLS)"
  if [[ -n "$existing_urls" ]]; then
    ok "TURN relay already configured for WebRTC: ${existing_urls}"
    return 0
  fi

  printf "\n"
  warn "Cloudflare Tunnel proxies the Fluid website and WebSocket signaling."
  warn "Remote browser sharing also needs a TURN relay for the WebRTC video path."
  read -r -p "Configure TURN relay now? [y/N]: " answer
  [[ "${answer,,}" == "y" ]] || {
    warn "Skipping TURN. Local sharing will work; off-LAN tunnel sharing may connect but show black video."
    return 0
  }

  read -r -p "TURN URLs, comma-separated (example: turn:turn.example.com:3478,turns:turn.example.com:5349): " urls
  [[ -n "$urls" ]] || die "TURN URLs cannot be empty when configuring TURN."
  read -r -p "TURN username: " username
  read -r -s -p "TURN credential/password: " credential
  printf "\n"
  read -r -p "ICE transport policy [all]: " policy
  policy="${policy:-all}"
  [[ "$policy" =~ ^(all|relay)$ ]] || die "ICE transport policy must be all or relay."

  set_fluid_env_value RTC_INCLUDE_DEFAULT_STUN true
  set_fluid_env_value RTC_TURN_URLS "$urls"
  set_fluid_env_value RTC_TURN_USERNAME "$username"
  set_fluid_env_value RTC_TURN_CREDENTIAL "$credential"
  set_fluid_env_value RTC_ICE_TRANSPORT_POLICY "$policy"

  systemctl restart fluid-server.service
  systemctl restart fluid-display.service >/dev/null 2>&1 || true
  ok "TURN relay saved to ${FLUID_ENV} and Fluid services restarted"
}

find_tunnel_id() {
  local tunnel_name="$1"
  cloudflared tunnel list 2>/dev/null | awk -v name="$tunnel_name" '
    $1 ~ /^[0-9a-fA-F-]{36}$/ && $2 == name { print $1; exit }
  ' || true
}

configure_token_tunnel() {
  local token="$1"
  step "Installing token-based tunnel service"
  if systemctl list-unit-files cloudflared.service >/dev/null 2>&1; then
    warn "Existing cloudflared.service found. It will be replaced with the token service."
    systemctl stop cloudflared.service >/dev/null 2>&1 || true
    systemctl disable cloudflared.service >/dev/null 2>&1 || true
  fi
  cloudflared service install "$token"
  systemctl enable --now cloudflared.service
  ok "Token-based cloudflared service is running"
}

configure_named_tunnel() {
  local tunnel_name="$1" hostname="$2" origin="$3"
  step "Creating named tunnel"
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$CONFIG_DIR"

  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    warn "Cloudflare login is required once."
    warn "Copy the URL printed below into your browser, choose the vipsy.in zone, then return here."
    cloudflared tunnel login
  else
    ok "Cloudflare origin certificate already exists"
  fi

  local tunnel_id credentials_src credentials_dst create_output
  tunnel_id="$(find_tunnel_id "$tunnel_name")"

  if [[ -n "$tunnel_id" ]]; then
    ok "Using existing tunnel ${tunnel_name} (${tunnel_id})"
  else
    create_output="$(cloudflared tunnel create "$tunnel_name" 2>&1)"
    printf "%s\n" "$create_output"
    tunnel_id="$(printf "%s\n" "$create_output" | grep -Eo '[0-9a-fA-F-]{36}' | tail -n1 || true)"
    tunnel_id="${tunnel_id:-$(find_tunnel_id "$tunnel_name")}"
    [[ -n "$tunnel_id" ]] || die "Tunnel was created, but its id could not be detected. Run: cloudflared tunnel list"
    ok "Created tunnel ${tunnel_name} (${tunnel_id})"
  fi

  credentials_src=""
  for candidate in "/root/.cloudflared/${tunnel_id}.json" "/root/.cloudflared/${tunnel_id}"; do
    if [[ -f "$candidate" ]]; then
      credentials_src="$candidate"
      break
    fi
  done
  [[ -n "$credentials_src" ]] || die "Tunnel credentials were not found at /root/.cloudflared/${tunnel_id}[.json]"
  credentials_dst="${CONFIG_DIR}/${tunnel_id}.json"
  install -m 0600 "$credentials_src" "$credentials_dst"

  step "Writing tunnel config"
  cat > "$CONFIG_FILE" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${credentials_dst}

originRequest:
  noTLSVerify: true
  connectTimeout: 30s

ingress:
  - hostname: ${hostname}
    service: ${origin}
  - service: http_status:404
EOF
  chmod 0644 "$CONFIG_FILE"
  cloudflared tunnel ingress validate --config "$CONFIG_FILE"
  ok "Config written to ${CONFIG_FILE}"

  step "Routing DNS"
  if cloudflared tunnel route dns "$tunnel_id" "$hostname"; then
    ok "DNS route created for ${hostname}"
  else
    warn "DNS route command failed. If the record already exists, this may be okay."
  fi

  step "Installing service"
  systemctl stop cloudflared.service >/dev/null 2>&1 || true
  write_service_for_named_tunnel
  ok "cloudflared service is running"
}

main() {
  printf "\n%bFluid Cloudflare Tunnel setup%b\n" "$bold$blue" "$nc"
  printf "This exposes Fluid through Cloudflare without opening router ports.\n\n"

  local hostname tunnel_name server_port origin token
  server_port="$(read_env_value SERVER_PORT)"
  server_port="${server_port:-3123}"

  read -r -p "Public hostname [${HOSTNAME_DEFAULT}]: " hostname
  hostname="${hostname:-$HOSTNAME_DEFAULT}"
  read -r -p "Tunnel name [${TUNNEL_NAME_DEFAULT}]: " tunnel_name
  tunnel_name="${tunnel_name:-$TUNNEL_NAME_DEFAULT}"

  origin="https://127.0.0.1:${server_port}"
  read -r -p "Local Fluid origin [${origin}]: " input_origin
  origin="${input_origin:-$origin}"

  install_cloudflared

  printf "\n"
  warn "If you already created a Cloudflare Tunnel in the Zero Trust dashboard,"
  warn "paste its token below. Otherwise leave it blank and this script will"
  warn "open the Cloudflare login flow and create/route the tunnel for you."
  read -r -s -p "Cloudflare tunnel token (optional): " token
  printf "\n"

  if [[ -n "$token" ]]; then
    configure_token_tunnel "$token"
    warn "Token mode uses the hostname/public-hostname configured in Cloudflare Zero Trust."
    warn "Make sure it is set to ${hostname} -> ${origin}."
  else
    configure_named_tunnel "$tunnel_name" "$hostname" "$origin"
  fi

  validate_public_url "$hostname"
  configure_turn_for_tunnel

  printf "\n%bDone.%b\n" "$bold$green" "$nc"
  printf "Public URL: https://%s\n" "$hostname"
  printf "Logs:       sudo journalctl -u cloudflared -f\n"
}

main "$@"
