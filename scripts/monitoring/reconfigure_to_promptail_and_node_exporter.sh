#!/usr/bin/env bash
set -euo pipefail

# =======================================================
# SECTION 1: INSTALL (download & place binaries)
# =======================================================

install_promtail() {
  echo "📥 Installing Promtail..."

  VERSION="3.2.0"  # 🔄 Update if needed from https://github.com/grafana/loki/releases
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
  elif [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
  elif [[ "$ARCH" == "armv7l" ]]; then
    ARCH="armv7"
  fi

  # Download promtail binary
  curl -L -o /tmp/promtail.zip \
    "https://github.com/grafana/loki/releases/download/v${VERSION}/promtail-linux-${ARCH}.zip"

  # Extract into /opt/promtail
  mkdir -p /opt/promtail
  apt-get update -qq && apt-get install -y unzip
  unzip -o /tmp/promtail.zip -d /opt/promtail
  rm /tmp/promtail.zip

  # Create system user (no login, no home)
  useradd --system --no-create-home --shell /sbin/nologin promtail || true
  chown -R promtail:promtail /opt/promtail

  echo "✅ Promtail installed to /opt/promtail/"
}

install_node_exporter() {
  echo "📥 Installing Node Exporter..."

  VERSION="1.8.2"  # 🔄 Update if needed from https://prometheus.io/download/
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
  elif [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
  elif [[ "$ARCH" == "armv7l" ]]; then
    ARCH="armv7"
  fi

  # Download node_exporter
  curl -L -o /tmp/node_exporter.tar.gz \
    "https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${ARCH}.tar.gz"

  tar -xzf /tmp/node_exporter.tar.gz -C /tmp
  mkdir -p /opt/node_exporter
  cp "/tmp/node_exporter-${VERSION}.linux-${ARCH}/node_exporter" /opt/node_exporter/
  rm -rf /tmp/node_exporter*

  # Create system user (no login, no home)
  useradd --system --no-create-home --shell /sbin/nologin nodeusr || true
  chown -R nodeusr:nodeusr /opt/node_exporter

  echo "✅ Node Exporter installed to /opt/node_exporter/"
}

# =======================================================
# SECTION 2: CONFIGURE (configs + systemd services)
# =======================================================

configure_promtail() {
  echo "⚙️  Configuring Promtail..."

  # Create config directory
  mkdir -p /etc/promtail

  # Promtail config file (journal → Loki)
  cat >/etc/promtail/promtail.yaml <<'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://loghub.lan:3100/loki/api/v1/push

scrape_configs:
  - job_name: journal_logs
    journal:
      max_age: 24h
      labels:
        job: journal_logs
    relabel_configs:
      - source_labels: ['__journal__syslog_identifier']
        regex: '(picframe|picframe-backup)'
        target_label: app
        replacement: picframe
      - source_labels: ['__journal__systemd_unit']
        regex: '(picframe|photo-sync)\.service'
        target_label: app
        replacement: picframe
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal__boot_id']
        target_label: boot_id
      - source_labels: ['__journal__transport']
        target_label: transport
      - source_labels: ['__journal__hostname']
        target_label: instance
      - source_labels: ['__journal_priority_keyword']
        target_label: level
EOF

  # Create state directory
  mkdir -p /var/lib/promtail
  chown -R promtail:promtail /etc/promtail /var/lib/promtail

  # Systemd unit
  cat >/etc/systemd/system/promtail.service <<EOF
[Unit]
Description=📜 Promtail (Loki log shipper)
After=network.target

[Service]
User=promtail
Group=promtail
ExecStart=/opt/promtail/promtail-linux-${ARCH} -config.file=/etc/promtail/promtail.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl enable promtail
  echo "✅ Promtail configured"
}

configure_node_exporter() {
  echo "⚙️  Configuring Node Exporter..."

  # Systemd unit
  cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=📊 Prometheus Node Exporter
After=network.target

[Service]
User=nodeusr
Group=nodeusr
ExecStart=/opt/node_exporter/node_exporter \
  --web.listen-address=":9100" \
  --collector.disable-defaults \
  --collector.cpu \
  --collector.meminfo \
  --collector.filesystem \
  --collector.netdev \
  --collector.netclass \
  --collector.filesystem.ignored-fs-types="autofs,binfmt_misc,cgroup,cgroup2,configfs,debugfs,devpts,devtmpfs,fusectl,overlay,proc,pstore,rpc_pipefs,securityfs,selinuxfs,sysfs,tracefs" \
  --collector.filesystem.ignored-mount-points="^/(dev|proc|sys|run|var/lib/docker/.+|var/lib/containers/.+)"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reexec
  systemctl enable node_exporter
  echo "✅ Node Exporter configured"
}

# =======================================================
# MAIN SCRIPT EXECUTION
# =======================================================
echo "🚀 Starting installation & configuration..."

install_promtail
install_node_exporter
configure_promtail
configure_node_exporter

echo ""
echo "🎉 Done!"
echo "👉 Start services with:  systemctl start promtail node_exporter"
echo "👉 Check status:         systemctl status promtail node_exporter"
echo "👉 Logs:                 journalctl -u promtail -f"