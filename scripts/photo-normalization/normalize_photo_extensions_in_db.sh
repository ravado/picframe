#!/bin/bash
#
# === normalize_photo_extensions_in_db.sh ===
# Скрипт для нормалізації розширень у базі SQLite (таблиця file, поле extension).
# 1. Створює резервну копію
# 2. Видаляє дублікати (залишає рядок з мінімальним file_id)
# 3. Приводить розширення до нижнього регістру
#
# Використання:
#   ./normalize_photo_extensions_in_db.sh pictureframe.db3           # реальне оновлення
#   ./normalize_photo_extensions_in_db.sh pictureframe.db3 --dry-run # показати, без змін
#

DB=""
DRYRUN=0

# розбір аргументів
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRYRUN=1 ;;
        *) DB="$arg" ;;
    esac
done

if [[ -z "$DB" ]]; then
    echo "❌ Помилка: потрібно вказати шлях до бази даних"
    exit 1
fi

if [[ ! -f "$DB" ]]; then
    echo "❌ Помилка: база даних $DB не існує"
    exit 1
fi

# --- Перевірка наявності sqlite3 ---
if ! command -v sqlite3 &>/dev/null; then
    echo "ℹ️ sqlite3 не знайдено. Спроба встановлення..."

    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y sqlite3
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y sqlite
    elif command -v apk &>/dev/null; then
        sudo apk add sqlite
    elif command -v brew &>/dev/null; then
        brew install sqlite
    else
        echo "❌ Не вдалося автоматично встановити sqlite3. Встанови вручну."
        exit 1
    fi
fi

# === Dry-run режим ===
if [[ $DRYRUN -eq 1 ]]; then
    echo "🔍 Dry-run: пошук дублікатів..."

    DUP_COUNT=$(sqlite3 "$DB" "
        SELECT COUNT(*) FROM (
          SELECT folder_id, basename, lower(extension), COUNT(*) AS cnt
          FROM file
          GROUP BY folder_id, basename, lower(extension)
          HAVING cnt > 1
        );")
    echo "🗑️ Було б видалено дублікатів груп: $DUP_COUNT"

    if [[ "$DUP_COUNT" -gt 0 ]]; then
        sqlite3 "$DB" "
            SELECT folder_id, basename, group_concat(extension), COUNT(*) 
            FROM file
            GROUP BY folder_id, basename, lower(extension)
            HAVING COUNT(*) > 1
            LIMIT 50;" | sed 's/|/  |  /g'
        echo "ℹ️ Показані перші 50 груп дублікатів"
    fi

    TO_UPDATE=$(sqlite3 "$DB" \
        "SELECT COUNT(*) FROM file WHERE extension != lower(extension);")
    echo "🔍 Рядків для оновлення: $TO_UPDATE"

    if [[ "$TO_UPDATE" -gt 0 ]]; then
        sqlite3 "$DB" "
            SELECT file_id, extension, lower(extension) AS new_ext 
            FROM file 
            WHERE extension != lower(extension) 
            LIMIT 50;" | sed 's/|/  |  /g'
        echo "ℹ️ Показані перші 50 рядків для оновлення"
    fi

    echo "👉 Це був dry-run. Реальних змін не зроблено."
    exit 0
fi

# === Реальний режим ===
# резервна копія
BACKUP="${DB}.bak.$(date +%Y%m%d%H%M%S)"
cp "$DB" "$BACKUP"
echo "📦 Резервну копію створено: $BACKUP"

# видалення дублікатів
DELETED=$(sqlite3 "$DB" "
    DELETE FROM file 
    WHERE file_id NOT IN (
      SELECT MIN(file_id)
      FROM file
      GROUP BY folder_id, basename, lower(extension)
    );
    SELECT changes();")
echo "🗑️ Видалено рядків: $DELETED"

# нормалізація розширень
UPDATED=$(sqlite3 "$DB" "
    UPDATE file 
    SET extension = lower(extension) 
    WHERE extension != lower(extension);
    SELECT changes();")
echo "✅ Оновлено рядків: $UPDATED"