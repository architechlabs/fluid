#!/usr/bin/env bash
# Quick Fluid health checks for local development and installed Pi systems.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0

green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
nc='\033[0m'

ok() { printf "%b[ok]%b %s\n" "$green" "$nc" "$*"; }
warn() { printf "%b[warn]%b %s\n" "$yellow" "$nc" "$*"; }
fail() { printf "%b[fail]%b %s\n" "$red" "$nc" "$*"; FAILURES=$((FAILURES + 1)); }

check_file() {
  if [[ -e "$ROOT_DIR/$1" ]]; then
    ok "$1 exists"
  else
    fail "$1 is missing"
  fi
}

printf "\nFluid doctor\n"
printf "Repo: %s\n\n" "$ROOT_DIR"

check_file "server.js"
check_file "package.json"
check_file "public/index.html"
check_file "public/client.html"
check_file "public/admin.html"
check_file "public/display.html"
check_file "install.sh"
check_file "systemd/fluid-server.service"
check_file "systemd/fluid-display.service"

printf "\nRuntime\n"
if command -v node >/dev/null 2>&1; then
  node_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  if [[ "$node_major" =~ ^[0-9]+$ ]] && (( node_major >= 18 )); then
    ok "Node $(node --version)"
  else
    fail "Node 18+ required, found $(node --version)"
  fi
else
  fail "node is not installed"
fi

if [[ -d "$ROOT_DIR/node_modules" ]]; then
  ok "node_modules installed"
else
  warn "node_modules missing; run npm install"
fi

if command -v npm >/dev/null 2>&1; then
  ok "npm $(npm --version)"
else
  fail "npm is not installed"
fi

printf "\nConfiguration\n"
if [[ -f "$ROOT_DIR/.env" ]]; then
  ok ".env found for local development"
else
  warn ".env not found; local development will use built-in defaults"
fi

if [[ -f /etc/fluid/fluid.env ]]; then
  ok "/etc/fluid/fluid.env found"
else
  warn "/etc/fluid/fluid.env not found; this is normal before installing on the Pi"
fi

printf "\nServices\n"
if command -v systemctl >/dev/null 2>&1; then
  for service in fluid-server fluid-display; do
    if systemctl list-unit-files "${service}.service" >/dev/null 2>&1; then
      state="$(systemctl is-active "$service" 2>/dev/null || true)"
      if [[ "$state" == "active" ]]; then
        ok "${service} is active"
      else
        warn "${service} is installed but ${state:-not active}"
      fi
    else
      warn "${service} is not installed"
    fi
  done
else
  warn "systemctl not available on this machine"
fi

printf "\n"
if (( FAILURES > 0 )); then
  fail "${FAILURES} check(s) failed"
  exit 1
fi

ok "No blocking issues found"
