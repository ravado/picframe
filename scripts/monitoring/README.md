# 📊 Моніторинг та логування для Photo Frame

Збір логів (Loki) та метрик (Prometheus) з пристроїв Raspberry Pi.

## Варіанти встановлення

### 1. Fluent Bit + Node Exporter (рекомендовано)

Легковісна заміна Alloy — споживає ~20MB RAM замість ~250MB.
Ідеально для Raspberry Pi Zero 2 W (512MB RAM).

- **Fluent Bit** — збирає логи з systemd journal, пушить до Loki
- **Node Exporter** — експортує метрики на порту :9100 (Prometheus скрейпить)

```bash
sudo apt update && sudo apt install -y curl
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravado/picframe/refs/heads/develop/scripts/monitoring/install_fluentbit_and_node_exporter.sh)"
```

Після встановлення додайте target до конфігу Prometheus сервера:

```yaml
scrape_configs:
  - job_name: 'linux_node'
    scrape_interval: 15s
    static_configs:
      - targets: ['<pi-ip>:9100']
```

### 2. Grafana Alloy (важкий варіант)

All-in-one агент від Grafana. Споживає 200-300MB RAM — не рекомендується для Pi Zero 2 W.

```bash
sudo apt update && sudo apt install -y curl
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ravado/picframe/refs/heads/develop/scripts/monitoring/install_alloy.sh)"
```

## 📄 Файли в каталозі

| Файл | Призначення |
|------|-------------|
| `install_fluentbit_and_node_exporter.sh` | **Основний інсталер** — джерело істини. Запустити на новому Pi — це все. |
| `install_alloy.sh` | Альтернативний інсталер (важкий варіант з Alloy). |
| `fluent-bit.conf` | **Довідкова копія** конфігу Fluent Bit, який створює інсталер. Не потрібно деплоїти вручну. |
| `loki-labels.lua` | **Довідкова копія** Lua-фільтра. Не потрібно деплоїти вручну. |
| `default_config.alloy` | Довідкова копія Alloy конфігу. |

> ℹ️ `fluent-bit.conf` та `loki-labels.lua` зберігаються в репо як зручний референс (легше читати окремо, ніж розпаковувати heredoc у bash-скрипті). **Інсталер містить актуальний вміст обох файлів інлайн** і записує їх у `/etc/fluent-bit/` під час установки. Якщо змінюєш конфіг — редагуй у `install_fluentbit_and_node_exporter.sh`, тоді синхронізуй ці довідкові файли.

## ⚠️ Важливо

🐧 Підтримуються лише системи на базі Debian (Raspberry Pi OS, Ubuntu)

🌐 Під час встановлення потрібно буде ввести IP адресу вашого моніторинг-сервера (Loki/Prometheus)

🔑 Потрібні права sudo

📥 Необхідно мати встановлений curl