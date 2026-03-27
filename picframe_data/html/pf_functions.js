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


// Format initial values (dates, floats) and start polling
refreshPage();
repeatRefresh();
document.getElementById("controls").addEventListener("keyup", e => {
    if (e.key === "Enter") {
        e.preventDefault();
        uploadValues();
    }
});
