#!/bin/bash
set -e

# Determine sudo usage
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

echo "🔧 Updating package database..."
$SUDO apt update

# Check if curl is installed
if ! command -v curl &> /dev/null; then
  echo "📥 Installing curl..."
  $SUDO apt install curl -y
else
  echo "✅ curl is already installed."
fi

# Check if gpg is installed
if ! command -v gpg &> /dev/null; then
  echo "🔑 Installing GPG..."
  $SUDO apt install gpg -y
else
  echo "✅ GPG is already installed."
fi

# Check if Grafana repo is already added
if ! grep -q "apt.grafana.com" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  echo "📦 Adding Grafana repository..."

  $SUDO mkdir -p /etc/apt/keyrings/

  # Check if grafana.gpg exists
  if [ ! -f /etc/apt/keyrings/grafana.gpg ]; then
    echo "🔑 Adding Grafana GPG key..."
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | $SUDO tee /etc/apt/keyrings/grafana.gpg > /dev/null
  else
    echo "✅ Grafana GPG key already exists."
  fi

  echo "📂 Adding Grafana source list..."
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | $SUDO tee /etc/apt/sources.list.d/grafana.list

  echo "🔄 Updating package database after adding Grafana repo..."
  $SUDO apt update
else
  echo "✅ Grafana repository is already added."
fi

# Check if alloy is already installed
if ! command -v alloy &> /dev/null; then
  echo "📥 Installing Alloy..."
  $SUDO apt install alloy -y
else
  echo "✅ Alloy is already installed."
fi

# Prompt for Loki host
while true; do
  echo "🌐 Please enter your Loki and Prometheus IP or domain (e.g. 192.168.91.10):"
  read loki_and_prometheus_host

  if [[ -z "$loki_and_prometheus_host" ]]; then
    echo "❌ Loki and Prometheus host cannot be empty. Please try again."
  else
    break
  fi
done

# Build full URLs with fixed API paths
loki_url="http://${loki_and_prometheus_host}:3100/loki/api/v1/push"
prometheus_url="http://${loki_and_prometheus_host}:9090/api/v1/write"

echo "✅ Loki URL set to: $loki_url"
echo "✅ Prometheus URL set to: $prometheus_url"

echo "⬇️ Downloading Alloy config template..."
$SUDO curl -fsSL https://raw.githubusercontent.com/ravado/picframe/refs/heads/main/scripts/monitoring/default_config.alloy -o /etc/alloy/config.alloy

echo "✏️ Replacing placeholders in config..."
$SUDO sed -i "s|\${LOKI_URL}|${loki_url}|g" /etc/alloy/config.alloy
$SUDO sed -i "s|\${PROMETHEUS_URL}|${prometheus_url}|g" /etc/alloy/config.alloy

echo "🧪 Validating configuration..."
$SUDO alloy validate /etc/alloy/config.alloy

echo "🔄 Restarting and enabling Alloy service..."
$SUDO systemctl enable --now alloy

echo "✅ Alloy installation and configuration completed successfully!"