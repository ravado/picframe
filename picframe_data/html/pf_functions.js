const TYPES = {"bool": 5, "text": 15, "date": 10, "number": 5, "action": 5};

const GROUPS = {
    "nav":     {label: "Navigation",    danger: false},
    "display": {label: "Display",       danger: false},
    "text":    {label: "Text Overlays", danger: false},
    "filter":  {label: "Filters",       danger: false},
    "actions": {label: "Actions",       danger: true},
};


async function getData() {
    const response = await fetch("/?all");
    return response.json();
}


function createSpans() {
    const grouped = {};
    Object.entries(ids).forEach(([id, el]) => {
        const g = el.group || "other";
        if (!grouped[g]) grouped[g] = [];
        grouped[g].push([id, el]);
    });

    let html = "";
    Object.entries(GROUPS).forEach(([groupKey, groupInfo]) => {
        const items = grouped[groupKey];
        if (!items || items.length === 0) return;

        html += `<div class="card${groupInfo.danger ? " card--danger" : ""}">`;
        html += `<div class="card-title">${groupInfo.label}</div>`;
        html += `<div class="card-body">`;

        items.forEach(([id, el]) => {
            const label = (el.desc !== undefined) ? el.desc : id.replace(/_/g, " ");

            if (el.type === "bool" || el.type === "action") {
                const btnClass = el.type === "action"
                    ? (groupInfo.danger ? "pf-btn pf-btn--danger" : "pf-btn pf-btn--action")
                    : "pf-btn pf-btn--off";
                html += `<button class="${btnClass}" data-resting="${btnClass}" id="${id}" onclick="toggle('${id}')">${label}</button>`;
            } else {
                const widthAttr = el.type === "text" ? "" : ` style="width:${TYPES[el.type]}ch"`;
                html += `<div class="pf-field${el.type === "text" ? " pf-field--wide" : ""}">`;
                html += `<label for="${id}">${label}</label>`;
                html += `<input id="${id}"${widthAttr}>`;
                html += `</div>`;
            }
        });

        html += `</div></div>`;
    });

    const container = document.getElementById("controls");
    container.innerHTML = html;

    container.addEventListener("keyup", e => {
        if (e.key === "Enter") {
            e.preventDefault();
            uploadValues();
        }
    });
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
            elem.className = el.val ? "pf-btn pf-btn--on" : "pf-btn pf-btn--off";
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
    const restingClass = el.type === "bool"
        ? (el.val ? "pf-btn pf-btn--on" : "pf-btn pf-btn--off")
        : (elem.dataset.resting || "pf-btn pf-btn--action");

    elem.className = "pf-btn pf-btn--flash";
    fetch(cmd).then(() => { elem.className = restingClass; });
}


// Initialise
createSpans();
repeatRefresh();
