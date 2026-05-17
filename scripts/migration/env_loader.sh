#!/bin/bash
# env_loader.sh – Loads environment variables for PicFrame scripts and validates them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/backup.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "❌ Missing $ENV_FILE. Please create it (you can copy backup.env.example)."
    return 1
fi

# Load env file
# shellcheck disable=SC1090
source "$ENV_FILE"

###########################
# ✅ Validate required variables
###########################
REQUIRED_VARS=(
    SMB_HOST
    SMB_BACKUPS_SHARE
    SMB_BACKUPS_SUBDIR
    SMB_BACKUPS_PATH
    SMB_PICFRAMES_SHARE
    SMB_PICFRAMES_SUBDIR
    SMB_PICFRAMES_PATH
    USERNAME
    PASSWORD
    SMB_CRED_USER
    SMB_CRED_PASS
    REMOTE_USER
    REMOTE_HOST
    REMOTE_PATH
    LOCAL_PATH
    PICFRAME_USER
)

missing_vars=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
    echo "❌ Missing required variables in $ENV_FILE:"
    for var in "${missing_vars[@]}"; do
        echo "   - $var"
    done
    return 1
fi

###########################
# ⚠️ Placeholder sanity check
###########################
if [[ "$USERNAME" == "{username}" ]] || [[ "$PASSWORD" == "{password}" ]]; then
    echo "❌ It looks like you did not update your $ENV_FILE properly (USERNAME/PASSWORD still placeholders)."
    return 1
fi

# Optional success output
[[ "${PF_ENV_DEBUG:-0}" == "1" ]] && echo "✅ Environment loaded successfully from $ENV_FILE" || true