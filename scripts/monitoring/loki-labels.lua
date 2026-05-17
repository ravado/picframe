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

    -- unit
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
