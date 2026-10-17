#!/bin/bash
# ============================================================================
# prepare_vm_for_picframe.sh
# Підготовка Ubuntu 24 Server ARM64 (Parallels VM) до середовища,
# максимально наближеного до Raspberry Pi OS Bookworm + Wayland.
#
# Запускати ПЕРЕД скриптом встановлення PicFrame.
# Після виконання — reboot, потім запускати picframe install script.
#
# Використання:
#   chmod +x prepare_vm_for_picframe.sh
#   ./prepare_vm_for_picframe.sh
# ============================================================================

set -e

LOG_FILE="$HOME/prepare_vm_log.txt"
CURRENT_USER=$(whoami)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "❌ ERROR: $1"
    exit 1
}

# ----------------------------------------------------------------------------
# Перевірки
# ----------------------------------------------------------------------------
log "=== Підготовка VM для PicFrame ==="
log "Користувач: $CURRENT_USER"
log "Система: $(uname -m) / $(lsb_release -ds 2>/dev/null || cat /etc/os-release | head -1)"

if [ "$CURRENT_USER" = "root" ]; then
    error_exit "Не запускайте від root. Використовуйте звичайного користувача."
fi

if [ "$(uname -m)" != "aarch64" ]; then
    log "⚠️  УВАГА: Архітектура $(uname -m), очікувалась aarch64 (ARM64)."
    log "   Скрипт продовжить роботу, але можуть бути проблеми з OpenGL ES."
fi

# ----------------------------------------------------------------------------
# Крок 1: Оновлення системи
# ----------------------------------------------------------------------------
log "Крок 1: Оновлення системи..."
sudo apt update && sudo apt upgrade -y

# ----------------------------------------------------------------------------
# Крок 2: Встановлення Wayland compositor та залежностей
# ----------------------------------------------------------------------------
log "Крок 2: Встановлення labwc (Wayland compositor) та залежностей..."
sudo apt install -y \
    labwc \
    seatd \
    xwayland \
    wlr-randr \
    mesa-utils \
    libgl1-mesa-dri \
    libgles-dev \
    libegl-dev \
    libgl-dev \
    libdrm2 \
    libgbm1

# ----------------------------------------------------------------------------
# Крок 3: Встановлення Python та залежностей для PicFrame
# ----------------------------------------------------------------------------
log "Крок 3: Встановлення Python залежностей..."
sudo apt install -y \
    python3-pip \
    python3-venv \
    python3-numpy \
    python3-pil \
    mosquitto \
    mosquitto-clients \
    git

# ----------------------------------------------------------------------------
# Крок 4: Увімкнення та запуск seatd
# ----------------------------------------------------------------------------
log "Крок 4: Налаштування seatd..."
sudo systemctl enable seatd
sudo systemctl start seatd || log "⚠️  seatd вже запущений або помилка старту"

# ----------------------------------------------------------------------------
# Крок 5: Додавання користувача до потрібних груп
# ----------------------------------------------------------------------------
log "Крок 5: Додавання $CURRENT_USER до груп video, render, input..."
sudo usermod -aG video,render,input "$CURRENT_USER"

# Перевірка, чи існує група seat (для seatd)
if getent group seat > /dev/null 2>&1; then
    sudo usermod -aG seat "$CURRENT_USER"
    log "   Додано до групи seat."
fi

# ----------------------------------------------------------------------------
# Крок 6: Налаштування auto-login на TTY1
# ----------------------------------------------------------------------------
log "Крок 6: Налаштування auto-login на tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $CURRENT_USER --noclear %I \$TERM
EOF

# ----------------------------------------------------------------------------
# Крок 7: Налаштування auto-start labwc на TTY1 login
# ----------------------------------------------------------------------------
log "Крок 7: Налаштування auto-start labwc..."

# Додаємо запуск labwc при логіні на tty1 (якщо ще немає)
PROFILE_MARKER="# AUTO-START labwc for picframe"
if ! grep -q "$PROFILE_MARKER" "$HOME/.profile" 2>/dev/null; then
    cat >> "$HOME/.profile" << 'EOF'

# AUTO-START labwc for picframe
if [ "$(tty)" = "/dev/tty1" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    exec labwc
fi
EOF
    log "   Додано auto-start labwc до .profile"
else
    log "   Auto-start labwc вже налаштований в .profile"
fi

# ----------------------------------------------------------------------------
# Крок 8: Створення labwc конфігурації
# ----------------------------------------------------------------------------
log "Крок 8: Створення labwc конфігурації..."
mkdir -p "$HOME/.config/labwc"

# labwc autostart — буде запускати picframe
# PicFrame install script створить свій сервіс, але як fallback:
if [ ! -f "$HOME/.config/labwc/autostart" ]; then
    cat > "$HOME/.config/labwc/autostart" << 'AUTOSTART'
# PicFrame буде запущений через systemd user service
# Цей файл — fallback для ручного запуску
AUTOSTART
    log "   Створено базовий labwc/autostart"
else
    log "   labwc/autostart вже існує, пропускаємо"
fi

# labwc environment — передаємо змінні середовища
cat > "$HOME/.config/labwc/environment" << 'ENV'
# Wayland/OpenGL environment for PicFrame
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=wlroots
ENV
log "   Створено labwc/environment"

# ----------------------------------------------------------------------------
# Крок 9: Налаштування linger для systemd user services
# ----------------------------------------------------------------------------
log "Крок 9: Увімкнення loginctl linger..."
loginctl enable-linger "$CURRENT_USER"

# ----------------------------------------------------------------------------
# Крок 10: Створення директорій для PicFrame (як на RPi)
# ----------------------------------------------------------------------------
log "Крок 10: Створення директорій..."
mkdir -p "$HOME/Pictures"
mkdir -p "$HOME/DeletedPictures"
log "   ~/Pictures та ~/DeletedPictures створено"

# ----------------------------------------------------------------------------
# Крок 11: Створення helper-скриптів
# ----------------------------------------------------------------------------
log "Крок 11: Створення helper-скриптів..."

# Скрипт для перевірки стану середовища
cat > "$HOME/check_picframe_env.sh" << 'CHECK'
#!/bin/bash
echo "=== PicFrame Environment Check ==="
echo ""
echo "--- Система ---"
echo "Arch: $(uname -m)"
echo "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | head -1)"
echo ""
echo "--- Wayland ---"
echo "labwc running: $(pgrep -c labwc 2>/dev/null || echo 'NO')"
echo "WAYLAND_DISPLAY: ${WAYLAND_DISPLAY:-not set}"
echo "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-not set}"
echo ""
echo "--- seatd ---"
systemctl is-active seatd 2>/dev/null || echo "seatd: not running"
echo ""
echo "--- Групи користувача ---"
groups
echo ""
echo "--- OpenGL ---"
if command -v eglinfo > /dev/null 2>&1; then
    eglinfo | head -20
else
    echo "eglinfo не встановлено (mesa-utils-extra)"
fi
echo ""
echo "--- PicFrame venv ---"
if [ -f "$HOME/venv_picframe/bin/activate" ]; then
    source "$HOME/venv_picframe/bin/activate"
    if command -v picframe > /dev/null 2>&1; then
        picframe -v
    else
        echo "picframe не встановлено у venv"
    fi
    deactivate
else
    echo "venv_picframe не знайдено (буде створено install скриптом)"
fi
echo ""
echo "--- Systemd user service ---"
systemctl --user status picframe.service 2>/dev/null || echo "picframe.service: не створено"
echo ""
echo "=== Перевірка завершена ==="
CHECK
chmod +x "$HOME/check_picframe_env.sh"
log "   Створено check_picframe_env.sh"

# ----------------------------------------------------------------------------
# Фінал
# ----------------------------------------------------------------------------
log ""
log "============================================"
log "✅ Підготовка VM завершена!"
log "============================================"
log ""
log "Наступні кроки:"
log "  1. sudo reboot"
log "  2. Після reboot підключитися по SSH"
log "  3. Запустити скрипт встановлення PicFrame"
log ""
log "Перевірка середовища після reboot:"
log "  ./check_picframe_env.sh"
log ""
log "⚠️  ВАЖЛИВО для PicFrame install script:"
log "  - Systemd user service повинен запускати:"
log "    ExecStart=/usr/bin/labwc"
log "  - labwc autostart (~/.config/labwc/autostart) повинен містити"
log "    команду запуску picframe"
log "  - НЕ потрібно встановлювати DISPLAY або EGL_PLATFORM"
log "    (labwc сам керує Wayland сесією)"
log ""
log "Лог збережено: $LOG_FILE"