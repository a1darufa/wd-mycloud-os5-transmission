// settings.js — Transmission 4's settings page: shows the app's state and
// saves the login, port and allowed addresses through api.php. Saving
// restarts the daemon in the background; the page polls until it's back.
"use strict";

(() => {
    const POLL_INTERVAL_MS = 2000;
    const APPLY_TIMEOUT_MS = 150000;

    const page = {
        state: document.getElementById("state"),
        banner: document.getElementById("banner"),
        webUi: document.getElementById("web-ui"),
        rpcUrl: document.getElementById("rpc-url"),
        form: document.getElementById("settings"),
        initialPassword: document.getElementById("initial-password"),
        save: document.getElementById("save"),
        saveStatus: document.getElementById("save-status"),
    };
    let lastStatus = null;

    // Transmission serves plain HTTP on its own port, on whatever name or
    // address this dashboard was opened with.
    function showAddresses(port) {
        const base = `http://${location.hostname}:${port}/transmission/`;
        page.webUi.href = `${base}web/`;
        page.rpcUrl.textContent = `${base}rpc`;
    }

    // [badge text, badge kind]
    function describeState(status) {
        if (!status.set_up) {
            return status.wd_running ? ["WD's Transmission is running", "warn"] : ["Not set up yet", "warn"];
        }
        switch (status.daemon) {
            case "running":
                return [`Running on port ${status.port}`, "ok"];
            case "starting":
                return ["Starting...", "warn"];
            default:
                return status.should_run ? ["Not running", "error"] : ["Switched off", ""];
        }
    }

    // [banner text or "", banner kind]
    function describeProblem(status) {
        if (status.wd_running) {
            return ["WD's own Transmission app is running. Switch it OFF in Apps, then switch "
                + "this app OFF and ON: it takes over WD's settings and torrents once.", "warn"];
        }
        if (!status.set_up) {
            return ["Switch the app ON in the dashboard first. Its first start sets Transmission "
                + "up; then you can change the settings here.", "info"];
        }
        if (status.daemon === "stopped" && status.should_run) {
            return ["Transmission should be running but isn't. See the log in "
                + "/mnt/HD/HD_a2/.transmission4/log.", "error"];
        }
        return ["", ""];
    }

    function render(status) {
        lastStatus = status;
        Settings.setText(page.state, ...describeState(status));
        Settings.showBanner(page.banner, ...describeProblem(status));
        showAddresses(status.port);
        page.initialPassword.hidden = !status.initial_password;
        for (const element of page.form.elements) {
            element.disabled = !status.set_up;
        }
    }

    function fillForm(status) {
        const fields = page.form.elements;
        fields.username.value = status.username;
        fields.password.value = "";
        fields.password2.value = "";
        fields.port.value = String(status.port);
        fields.allowed.value = status.allowed.join("\n");
    }

    async function loadStatus() {
        const reply = await Settings.call("status");
        if (!reply.ok) {
            Settings.setText(page.state, "Unknown", "error");
            Settings.showBanner(page.banner, reply.error, "error");
            return null;
        }
        render(reply.status);
        return reply.status;
    }

    // Poll until ctl.sh has finished applying; null if it takes too long.
    async function waitForApply() {
        const deadline = Date.now() + APPLY_TIMEOUT_MS;
        while (Date.now() < deadline) {
            await Settings.sleep(POLL_INTERVAL_MS);
            const reply = await Settings.call("status");
            if (reply.ok && reply.status.apply.state !== "applying") {
                return reply.status;
            }
        }
        return null;
    }

    async function save(event) {
        event.preventDefault();
        const fields = page.form.elements;
        if (fields.password.value !== fields.password2.value) {
            Settings.showFieldErrors(page.form, { password: "The two passwords don't match." });
            return;
        }
        Settings.showFieldErrors(page.form);
        page.save.disabled = true;
        Settings.setText(page.saveStatus, "Saving...");

        const reply = await Settings.call("save", {
            username: fields.username.value.trim(),
            password: fields.password.value,
            port: fields.port.value.trim(),
            allowed: Settings.lines(fields.allowed.value),
        });
        if (!reply.ok) {
            Settings.showFieldErrors(page.form, reply.fields);
            Settings.setText(page.saveStatus, reply.error, "error");
            page.save.disabled = false;
            return;
        }

        Settings.setText(page.saveStatus, "Restarting Transmission...");
        const status = await waitForApply();
        if (status === null) {
            Settings.setText(page.saveStatus, "No result yet. Reload this page in a minute to see the current settings.", "error");
            page.save.disabled = !(lastStatus && lastStatus.set_up);
            return;
        }
        render(status);
        fillForm(status);
        Settings.setText(page.saveStatus, status.apply.message, status.apply.state === "done" ? "ok" : "error");
    }

    Settings.start(async () => {
        page.form.addEventListener("submit", save);
        const status = await loadStatus();
        if (status) {
            fillForm(status);
        }
    });
})();
