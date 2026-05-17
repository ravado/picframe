#!/usr/bin/env bash
set -euo pipefail

# Verbose mode: ON by default — narrates every shell command with a timestamp
# and line number to the console (stderr). To disable, run with VERBOSE=0.
#
# To also persist the trace to a file that survives an SSH drop:
#   sudo script -q -c "bash install_fluentbit_and_node_exporter.sh" /tmp/install.log
if [ "${VERBOSE:-1}" = "1" ]; then
  export PS4='+ [\D{%H:%M:%S}] line ${LINENO}: '
  set -x
fi

# Make apt narrate its progress (download/install steps) instead of -qq silence.
APT_FLAGS="${APT_FLAGS:-}"

# =======================================================
# Fluent Bit + Node Exporter installer for Raspberry Pi
# Replaces Grafana Alloy with ~20MB RAM footprint
# =======================================================

NODE_EXPORTER_VERSION="1.8.2"
FLUENT_BIT_LOKI_PORT="3100"
NODE_EXPORTER_PORT="9100"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}✅ $1${NC}"; }
log_warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_step()  { echo -e "${GREEN}📦 $1${NC}"; }

# Determine sudo usage
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"

  # Pre-flight: prove sudo works and warm the credential cache up-front so
  # later prompts don't appear mid-install (and don't get visually buried in
  # xtrace output). With this in place, the rest of the script runs without
  # interactive sudo prompts as long as the install completes inside the
  # sudoers timeout (~15 min on most Debian-based systems).
  if ! command -v sudo >/dev/null 2>&1; then
    log_error "sudo is required but not installed. Either install sudo, or run this script as root."
    exit 1
  fi

  echo ""
  log_warn "This script needs sudo. You may be asked for your password now."
  if ! sudo -v; then
    log_error "sudo authentication failed. Aborting."
    exit 1
  fi
  log_info "sudo credentials cached — install will proceed without further prompts."
fi

detect_arch() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armhf" ;;
    armv6l)  echo "armhf" ;;
    *) log_error "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

detect_arch_node_exporter() {
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv7" ;;
    armv6l)  echo "armv6" ;;
    *) log_error "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

# =======================================================
# PHASE 1: Interactive prompts
# =======================================================

echo ""
echo "=========================================="
echo " Fluent Bit + Node Exporter Installer"
echo " (Lightweight replacement for Alloy)"
echo "=========================================="
echo ""

while true; do
  echo -e "${YELLOW}🌐 Enter your Loki host IP or domain (e.g. 192.168.91.10):${NC}"
  read -r monitor_host

  if [[ -z "$monitor_host" ]]; then
    log_error "Host cannot be empty. Please try again."
  else
    break
  fi
done

LOKI_URL="http://${monitor_host}:${FLUENT_BIT_LOKI_PORT}"

echo ""
log_info "Loki endpoint: ${LOKI_URL}/loki/api/v1/push"
log_info "Node Exporter will listen on :${NODE_EXPORTER_PORT} (Prometheus scrapes this)"
echo ""

# Connectivity check (non-fatal)
if curl --silent --connect-timeout 5 --max-time 10 -o /dev/null "http://${monitor_host}:${FLUENT_BIT_LOKI_PORT}/ready" 2>/dev/null; then
  log_info "Loki is reachable"
else
  log_warn "Cannot reach Loki at ${monitor_host}:${FLUENT_BIT_LOKI_PORT} — continuing anyway"
fi

# =======================================================
# PHASE 2: Install Fluent Bit
# =======================================================

log_step "Installing Fluent Bit..."

if ! command -v curl &>/dev/null; then
  $SUDO apt-get update
  $SUDO apt-get install -y curl
fi

if ! dpkg -l fluent-bit &>/dev/null; then
  # Add Fluent Bit repository
  if [ ! -f /usr/share/keyrings/fluentbit-keyring.gpg ]; then
    curl --connect-timeout 10 --max-time 60 -fsSL https://packages.fluentbit.io/fluentbit.key | \
      $SUDO gpg --dearmor -o /usr/share/keyrings/fluentbit-keyring.gpg
  fi

  CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")

  echo "deb [signed-by=/usr/share/keyrings/fluentbit-keyring.gpg] https://packages.fluentbit.io/debian/${CODENAME} ${CODENAME} main" | \
    $SUDO tee /etc/apt/sources.list.d/fluent-bit.list >/dev/null

  $SUDO apt-get update
  $SUDO apt-get install -y fluent-bit
else
  log_info "Fluent Bit is already installed"
fi

# Add fluent-bit user to systemd-journal group for journal access
if id "_fluent-bit" &>/dev/null; then
  $SUDO usermod -aG systemd-journal _fluent-bit 2>/dev/null || true
elif id "fluent-bit" &>/dev/null; then
  $SUDO usermod -aG systemd-journal fluent-bit 2>/dev/null || true
fi

# =======================================================
# PHASE 3: Configure Fluent Bit
# =======================================================

log_step "Deploying Fluent Bit configuration..."

$SUDO mkdir -p /etc/fluent-bit
$SUDO mkdir -p /var/lib/fluent-bit

$SUDO tee /etc/fluent-bit/fluent-bit.conf >/dev/null <<EOF
[SERVICE]
    flush           5
    daemon          off
    log_level       info
    parsers_file    parsers.conf

[INPUT]
    name              systemd
    tag               journal
    read_from_tail    on
    strip_underscores on
    db                /var/lib/fluent-bit/journal.db

[FILTER]
    name    lua
    match   journal
    script  /etc/fluent-bit/loki-labels.lua
    call    enrich

[OUTPUT]
    name              loki
    match             journal
    host              ${monitor_host}
    port              ${FLUENT_BIT_LOKI_PORT}
    labels            job=journal_logs
    label_keys        \$app,\$unit,\$instance,\$level
    structured_metadata_map_keys  \$BOOT_ID,\$TRANSPORT,\$PRIORITY,\$PID,\$UID,\$GID,\$COMM,\$EXE,\$CMDLINE,\$TID,\$CAP_EFFECTIVE,\$SYSLOG_IDENTIFIER,\$SYSLOG_FACILITY,\$SYSLOG_TIMESTAMP,\$SYSLOG_PID,\$SYSTEMD_UNIT,\$SYSTEMD_USER_UNIT,\$SYSTEMD_SLICE,\$SYSTEMD_CGROUP,\$SYSTEMD_INVOCATION_ID,\$CODE_FILE,\$CODE_LINE,\$CODE_FUNC,\$MACHINE_ID,\$MESSAGE_ID,\$INVOCATION_ID,\$TIMESTAMP_MONOTONIC,\$TIMESTAMP_BOOTTIME,\$SOURCE_REALTIME_TIMESTAMP,\$RUNTIME_SCOPE,\$JOB_ID,\$JOB_TYPE,\$JOB_RESULT,\$NM_LOG_DOMAINS,\$NM_LOG_LEVEL,\$NM_DEVICE
    line_format       key_value
    drop_single_key   on
    auto_kubernetes_labels off
EOF

$SUDO tee /etc/fluent-bit/loki-labels.lua >/dev/null <<'LUAEOF'
local priority_map = {
    ["0"] = "emerg",
    ["1"] = "alert",
    ["2"] = "crit",
    ["3"] = "err",
    ["4"] = "warning",
    ["5"] = "notice",
    ["6"] = "info",
    ["7"] = "debug"
}

-- Whitelist of journal/custom fields preserved as structured metadata.
-- Anything not here and not a label is dropped — keeps the line clean.
-- To preserve a new field, add its name here AND to structured_metadata_map_keys
-- in /etc/fluent-bit/fluent-bit.conf.
local meta_keys = {
    "BOOT_ID", "TRANSPORT", "PRIORITY", "PID", "UID", "GID",
    "COMM", "EXE", "CMDLINE", "TID", "CAP_EFFECTIVE",
    "SYSLOG_IDENTIFIER", "SYSLOG_FACILITY", "SYSLOG_TIMESTAMP", "SYSLOG_PID",
    "SYSTEMD_UNIT", "SYSTEMD_USER_UNIT", "SYSTEMD_SLICE",
    "SYSTEMD_CGROUP", "SYSTEMD_INVOCATION_ID",
    "CODE_FILE", "CODE_LINE", "CODE_FUNC",
    "MACHINE_ID", "MESSAGE_ID", "INVOCATION_ID",
    "TIMESTAMP_MONOTONIC", "TIMESTAMP_BOOTTIME",
    "SOURCE_REALTIME_TIMESTAMP", "RUNTIME_SCOPE",
    "JOB_ID", "JOB_TYPE", "JOB_RESULT",
    "NM_LOG_DOMAINS", "NM_LOG_LEVEL", "NM_DEVICE"
}

function enrich(tag, timestamp, record)
    local clean = {}

    -- Line content
    clean["MESSAGE"] = record["MESSAGE"] or ""

    -- ===== Labels (low cardinality, indexed) =====

    -- instance from hostname
    if record["HOSTNAME"] and record["HOSTNAME"] ~= "" then
        clean["instance"] = record["HOSTNAME"]
    end

    -- level from priority
    local priority = record["PRIORITY"] or "6"
    clean["level"] = priority_map[tostring(priority)] or "info"

    -- unit (prefer user unit if present)
    local systemd_unit = record["SYSTEMD_USER_UNIT"] or ""
    if systemd_unit == "" then
        systemd_unit = record["SYSTEMD_UNIT"] or ""
    end
    if systemd_unit ~= "" then
        clean["unit"] = systemd_unit
    end

    -- app: tag picframe-related units
    local syslog_id = record["SYSLOG_IDENTIFIER"] or ""
    if string.match(syslog_id, "^picframe") or
       string.match(systemd_unit, "^picframe") or
       string.match(systemd_unit, "^photo%-sync") then
        clean["app"] = "picframe"
    end

    -- ===== Structured metadata (preserved, searchable, not indexed) =====

    for _, key in ipairs(meta_keys) do
        if record[key] and record[key] ~= "" then
            clean[key] = record[key]
        end
    end

    return 1, timestamp, clean
end
LUAEOF

log_info "Fluent Bit configuration deployed"

# =======================================================
# PHASE 4: Install Node Exporter
# =======================================================

log_step "Installing Node Exporter v${NODE_EXPORTER_VERSION}..."

ARCH=$(detect_arch_node_exporter)

if [ ! -f /opt/node_exporter/node_exporter ]; then
  curl --connect-timeout 10 --max-time 60 -L -o /tmp/node_exporter.tar.gz \
    "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"

  tar -xzf /tmp/node_exporter.tar.gz -C /tmp
  $SUDO mkdir -p /opt/node_exporter
  $SUDO cp "/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" /opt/node_exporter/
  rm -rf /tmp/node_exporter*

  log_info "Node Exporter binary installed to /opt/node_exporter/"
else
  log_info "Node Exporter binary already exists"
fi

# Create system user
if ! id nodeusr &>/dev/null; then
  $SUDO useradd --system --no-create-home --shell /sbin/nologin nodeusr
fi
$SUDO chown -R nodeusr:nodeusr /opt/node_exporter

# =======================================================
# PHASE 5: Configure Node Exporter systemd service
# =======================================================

log_step "Deploying Node Exporter service..."

$SUDO tee /etc/systemd/system/node_exporter.service >/dev/null <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=nodeusr
Group=nodeusr
ExecStart=/opt/node_exporter/node_exporter \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.meminfo \
  --collector.filesystem \
  --collector.netdev \
  --collector.netclass \
  --collector.filesystem.ignored-fs-types=^(autofs|binfmt_misc|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|overlay|proc|pstore|rpc_pipefs|securityfs|selinuxfs|sysfs|tracefs)$ \
  --collector.filesystem.ignored-mount-points=^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containers/.+)($|/) \
  --collector.netclass.ignored-devices=^(veth.*|cali.*|[a-f0-9]{15})$ \
  --collector.netdev.device-exclude=^(veth.*|cali.*|[a-f0-9]{15})$
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log_info "Node Exporter service configured"

# =======================================================
# PHASE 6: Enable and start services
# =======================================================

log_step "Starting services..."

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now fluent-bit
$SUDO systemctl enable --now node_exporter

# =======================================================
# PHASE 7: Verification
# =======================================================

# Disable command tracing for the rest of the script — from here on we are
# only printing user-facing summary text, where xtrace lines just add noise.
set +x

echo ""
echo "=========================================="
echo " Verification"
echo "=========================================="

sleep 2

if systemctl is-active --quiet fluent-bit; then
  log_info "Fluent Bit is running"
else
  log_error "Fluent Bit failed to start — check: journalctl -u fluent-bit -n 20"
fi

if systemctl is-active --quiet node_exporter; then
  log_info "Node Exporter is running"
else
  log_error "Node Exporter failed to start — check: journalctl -u node_exporter -n 20"
fi

if curl --silent --connect-timeout 5 "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" | head -1 | grep -q "HELP"; then
  log_info "Node Exporter responding on :${NODE_EXPORTER_PORT}"
else
  log_warn "Node Exporter not yet responding on :${NODE_EXPORTER_PORT}"
fi

# =======================================================
# Summary
# =======================================================

echo ""
echo "=========================================="
echo " Installation Complete"
echo "=========================================="
echo ""
echo "  Fluent Bit  → pushes logs to Loki at ${LOKI_URL}"
echo "  Node Exporter → exposes metrics on :${NODE_EXPORTER_PORT}"
echo ""
echo "  Estimated RAM: ~20MB total (vs Alloy's ~250MB)"
echo ""
echo "  Useful commands:"
echo "    journalctl -u fluent-bit -f"
echo "    journalctl -u node_exporter -f"
echo "    curl -s http://localhost:${NODE_EXPORTER_PORT}/metrics | head"
echo ""
echo -e "${YELLOW}  NOTE: Add this to your Prometheus server scrape config:${NC}"
echo ""
echo "    - job_name: 'linux_node'"
echo "      scrape_interval: 15s"
echo "      static_configs:"
echo "        - targets: ['<this-pi-ip>:${NODE_EXPORTER_PORT}']"
echo ""
