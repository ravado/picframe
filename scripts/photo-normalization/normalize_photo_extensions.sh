#!/bin/bash
#
# === normalize_photo_extensions.sh ===
# Скрипт для приведення розширень файлів у вказаній теці до нижнього регістру.
#
# Використання:
#   ./normalize_photo_extensions.sh /шлях/до/текі           # реальне перейменування
#   ./normalize_photo_extensions.sh /шлях/до/текі --dry-run # лише показати зміни, без перейменування
#   ./normalize_photo_extensions.sh --dry-run /шлях/до/текі # те саме, прапорець може бути першим
#
# Додатково:
# - Логує всі зміни у файл rename.log
# - У разі конфлікту імен файл пропускається і логуються ⚠️ WARNING

DIR="."
DRYRUN=0
LOGFILE="rename.log"
COUNT=0

# розбір аргументів
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRYRUN=1 ;;
        *) DIR="$arg" ;;
    esac
done

# очистимо лог перед запуском
> "$LOGFILE"

while read -r file; do
    ext="${file##*.}"
    base="${file%.*}"
    lower_ext=$(echo "$ext" | tr 'A-Z' 'a-z')

    if [[ "$ext" != "$lower_ext" ]]; then
        newfile="${base}.${lower_ext}"

        if [[ -e "$newfile" ]]; then
            msg="⚠️ WARNING: Конфлікт! $file -> $newfile (пропущено)"
            echo "$msg" | tee -a "$LOGFILE"
            continue
        fi

        if [[ $DRYRUN -eq 1 ]]; then
            echo "[DRY-RUN] $file -> $newfile"
            ((COUNT++))
        else
            if mv -v "$file" "$newfile"; then
                echo "$file -> $newfile" >> "$LOGFILE"
                ((COUNT++))
            fi
        fi
    fi
done < <(find "$DIR" -type f)

if [[ $DRYRUN -eq 0 ]]; then
    echo "Загалом перейменовано: $COUNT файлів"
    echo "Лог збережено у $LOGFILE"
else
    echo "Це був dry-run. Реальних змін не зроблено."
    echo "Було б перейменовано: $COUNT файлів"
fi