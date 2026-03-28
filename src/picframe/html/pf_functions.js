async function getData() {
    const response = await fetch("/?all");
    return response.json();
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
        Promise.all(fetches).then(() => refreshData());
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
            if (img) {
                setTimeout(() => {
                    img.src = "/current_image?t=" + Date.now();
                }, 500);
            }
        }
    });
}


// Format initial values (dates, floats) and start polling
refreshPage();
repeatRefresh();
document.getElementById("controls").addEventListener("keyup", e => {
    if (e.key === "Enter") {
        e.preventDefault();
        uploadValues();
    }
});
