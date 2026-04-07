async function getData() {
    const response = await fetch("/?all");
    return response.json();
}

async function getQueueData() {
    const response = await fetch("/?queue_snapshot=1");
    return response.json();
}

function escapeHtml(value) {
    return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function queueThumbUrl(slot) {
    return `/?queue_thumb=${slot.slot_index}&v=${slot.thumb_version || 0}`;
}

function renderQueueSlot(slot, isCurrent = false) {
    const pairBadge = slot.is_pair ? '<span class="queue-badge">pair</span>' : "";
    const secondary = slot.secondary_label
        ? `<div class="queue-item__secondary">${escapeHtml(slot.secondary_label)}</div>`
        : "";
    const buttonLabel = isCurrent ? "Current" : "Show Next";

    return `
        <button class="queue-item${isCurrent ? " queue-item--current" : ""}" data-queue-index="${slot.slot_index}" ${isCurrent ? "disabled" : ""}>
            <img class="queue-item__thumb" src="${queueThumbUrl(slot)}" alt="" loading="lazy">
            <div class="queue-item__body">
                <div class="queue-item__title-row">
                    <span class="queue-item__index">${slot.slot_index + 1}.</span>
                    <span class="queue-item__title">${escapeHtml(slot.primary_label || "Unavailable")}</span>
                    ${pairBadge}
                </div>
                ${secondary}
            </div>
            <span class="queue-item__action">${buttonLabel}</span>
        </button>
    `;
}

function renderQueue(snapshot) {
    const summary = document.getElementById("queue-summary");
    const meta = document.getElementById("queue-meta");
    const current = document.getElementById("queue-current");
    const list = document.getElementById("queue-list");

    if (!summary || !meta || !current || !list) {
        return;
    }

    if (!snapshot || snapshot.total_slots === 0) {
        summary.textContent = "No queued images available";
        meta.textContent = "";
        current.innerHTML = "";
        list.innerHTML = '<div class="queue-empty">Queue will appear after images are loaded.</div>';
        return;
    }

    summary.textContent = snapshot.reload_pending ? "Queue refresh pending" : "Upcoming playlist slots";
    if (snapshot.displayed_index === null || snapshot.displayed_index === undefined) {
        meta.textContent = `next ${snapshot.next_index + 1} / ${snapshot.total_slots}`;
    } else {
        meta.textContent = `slot ${snapshot.displayed_index + 1} / ${snapshot.total_slots}`;
    }

    current.innerHTML = snapshot.current_slot
        ? renderQueueSlot(snapshot.current_slot, true)
        : '<div class="queue-empty">Current image will appear here after the first slide loads.</div>';

    if (!snapshot.upcoming_slots || snapshot.upcoming_slots.length === 0) {
        list.innerHTML = '<div class="queue-empty">No upcoming slots available right now.</div>';
        return;
    }

    list.innerHTML = snapshot.upcoming_slots.map(slot => renderQueueSlot(slot)).join("");
}

async function refreshQueue() {
    try {
        const snapshot = await getQueueData();
        renderQueue(snapshot);
    } catch (_error) {
        const list = document.getElementById("queue-list");
        const summary = document.getElementById("queue-summary");
        if (summary) summary.textContent = "Queue unavailable";
        if (list) list.innerHTML = '<div class="queue-empty">Unable to load queue preview.</div>';
    }
}

async function jumpToQueueIndex(index) {
    const response = await fetch(`/?queue_jump=${index}`);
    const result = await response.json();
    if (!result.ok) {
        await refreshQueue();
        return;
    }

    const img = document.getElementById("preview-img");
    setTimeout(() => {
        if (img) {
            img.src = "/current_image?t=" + Date.now();
        }
        refreshQueue();
    }, 500);
}


function isNumeric(num) {
    return (typeof num === "number" || (typeof num === "string" && num.trim() !== "")) && !isNaN(num);
}


function refreshPage() {
    Object.entries(ids).forEach(([id, el]) => {
        const elem = document.getElementById(id);
        if (!elem) return;
        let value = el.val;

        if (isNumeric(value)) {
            value = parseFloat(value);
            if (el.type === "number") {
                if (Math.floor(value) !== value) value = value.toFixed(2);
            } else if (el.type === "date") {
                const d = new Date(value * 1000);
                value = `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
            }
        } else if (el.type === "bool") {
            value = (value === true || value === "true" || value === "True" || value === "ON");
        }

        elem.value = value;
        el.val = value;

        if (el.type === "bool") {
            elem.className = elem.className.replace(/pf-btn--on|pf-btn--off/g, "")
                + (el.val ? " pf-btn--on" : " pf-btn--off");
            elem.className = elem.className.replace(/\s+/g, " ").trim();

            // Update power label if it's display_is_on
            if (id === "display_is_on") {
                const label = elem.querySelector(".power-label");
                if (label) label.textContent = el.val ? "ON" : "OFF";
            }

            // Update pause button text
            if (id === "paused") {
                elem.innerHTML = el.val ? "&#9646;&#9646; Paused" : "&#9654; Playing";
            }
        }

        // Sync brightness slider
        const slider = document.getElementById(id + "_slider");
        if (slider) {
            slider.value = value;
        }
    });
}


function refreshData() {
    getData().then(data => {
        let changed = false;
        Object.entries(data).forEach(([key, val]) => {
            if (key in ids && ids[key].val != val) {
                changed = true;
                ids[key].val = val;
            }
        });
        if (changed) refreshPage();
    }).catch(() => {});
}


function repeatRefresh() {
    refreshData();
    refreshQueue();
    setTimeout(repeatRefresh, 120000);
}


function uploadValues() {
    const fetches = [];
    Object.entries(ids).forEach(([id, el]) => {
        if (el.fn === "setter" && el.type !== "bool") {
            const elem = document.getElementById(id);
            if (!elem) return;
            if (elem.value != el.val) {
                el.val = elem.value;
                fetches.push(fetch(`/?${id}=${elem.value}`));
            }
        }
    });
    if (fetches.length > 0) {
        Promise.all(fetches).then(() => {
            refreshData();
            refreshQueue();
        });
    }
}


function toggle(id) {
    const el = ids[id];
    if (el.type === "bool") {
        el.val = !el.val;
    }

    let cmd = `/?${id}=${el.val}`;
    if (el.fn !== "setter") {
        cmd = `/?${el.fn}`.replace("$val", el.val);
    }

    const elem = document.getElementById(id);
    const restingClass = elem.dataset.resting || elem.className;

    // Flash
    const origClasses = elem.className;
    elem.className = origClasses.replace(/pf-btn--\w+/g, "") + " pf-btn--flash";
    elem.className = elem.className.replace(/\s+/g, " ").trim();

    fetch(cmd).then(() => {
        if (el.type === "bool") {
            const onOff = el.val ? "pf-btn--on" : "pf-btn--off";
            elem.className = origClasses.replace(/pf-btn--on|pf-btn--off/g, onOff);
            elem.className = elem.className.replace(/\s+/g, " ").trim();

            if (id === "display_is_on") {
                const label = elem.querySelector(".power-label");
                if (label) label.textContent = el.val ? "ON" : "OFF";
            }
            if (id === "paused") {
                elem.innerHTML = el.val ? "&#9646;&#9646; Paused" : "&#9654; Playing";
            }
        } else {
            elem.className = restingClass;
        }

        // Reload preview image after navigation actions
        if (id === "back" || id === "next") {
            const img = document.getElementById("preview-img");
            setTimeout(() => {
                if (img) {
                    img.src = "/current_image?t=" + Date.now();
                }
                refreshQueue();
            }, 500);
        }
    });
}


// Format initial values (dates, floats) and start polling
refreshPage();
refreshQueue();
repeatRefresh();
document.getElementById("controls").addEventListener("keyup", e => {
    if (e.key === "Enter") {
        e.preventDefault();
        uploadValues();
    }
});
document.getElementById("queue-card").addEventListener("click", e => {
    const button = e.target.closest("[data-queue-index]");
    if (!button || button.disabled) {
        return;
    }
    jumpToQueueIndex(button.dataset.queueIndex);
});
