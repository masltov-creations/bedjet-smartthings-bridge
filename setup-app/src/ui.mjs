const commandBlock = (command) => `
<div class="cmd-row">
  <pre><code>${command.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</code></pre>
  <button class="copy" onclick="copyCmd(this)">Copy</button>
</div>`;

export const buildWizardHtml = () => `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>BedJet Install Guide</title>
    <style>
      :root {
        --bg: #f6f4ef;
        --card: #ffffff;
        --ink: #15202b;
        --muted: #5f6d78;
        --line: #dde3e8;
        --accent: #0e6c78;
        --accent-soft: #e8f3f4;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: "Segoe UI", "Aptos", sans-serif;
        color: var(--ink);
        background: linear-gradient(180deg, #faf8f4 0%, var(--bg) 100%);
      }
      main {
        max-width: 980px;
        margin: 0 auto;
        padding: 24px 16px 44px;
      }
      h1 {
        margin: 0 0 8px;
        font-size: clamp(1.8rem, 3vw, 2.4rem);
        letter-spacing: -0.02em;
      }
      .lede {
        margin: 0 0 20px;
        color: var(--muted);
        max-width: 760px;
      }
      .pill {
        display: inline-flex;
        align-items: center;
        padding: 7px 12px;
        border-radius: 999px;
        border: 1px solid var(--line);
        background: #fff;
        color: var(--muted);
        font-size: 0.86rem;
      }
      .grid {
        display: grid;
        gap: 14px;
      }
      .card {
        background: var(--card);
        border: 1px solid var(--line);
        border-radius: 16px;
        padding: 16px;
      }
      .card h2 {
        margin: 0 0 4px;
        font-size: 1.2rem;
      }
      .card p {
        margin: 0 0 12px;
        color: var(--muted);
      }
      .step-list {
        margin: 0;
        padding-left: 22px;
      }
      .step-list li {
        margin: 0 0 8px;
      }
      .verify {
        margin-top: 12px;
        padding: 10px 12px;
        border-radius: 12px;
        border: 1px solid var(--line);
        background: #fbfcfd;
      }
      .verify strong {
        display: block;
        margin-bottom: 6px;
      }
      .cmd-row {
        display: grid;
        grid-template-columns: 1fr auto;
        gap: 8px;
        margin: 8px 0;
      }
      pre {
        margin: 0;
        overflow: auto;
        padding: 11px 12px;
        border-radius: 10px;
        background: #111827;
        color: #f8fafc;
        border: 1px solid #0f172a;
      }
      code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
      .copy {
        border: 1px solid var(--line);
        background: #fff;
        border-radius: 10px;
        font: inherit;
        color: var(--ink);
        padding: 0 12px;
        cursor: pointer;
      }
      .copy:hover { border-color: #c8d1d9; }
      .copy.ok { background: var(--accent-soft); color: var(--accent); border-color: #c4e0e3; }
      .note {
        margin-top: 14px;
        border-radius: 12px;
        border: 1px solid #cfe1e3;
        background: #f0f8f9;
        padding: 11px 12px;
        color: #245d66;
      }
    </style>
  </head>
  <body>
    <main>
      <span class="pill">Guide mode • 3 pieces only • script-first</span>
      <h1>BedJet Install (No Wizard Automation)</h1>
      <p class="lede">
        This page is now a clean, deterministic install guide. Do the three pieces in order:
        Gateway firmware, Bridge deploy, SmartThings driver.
      </p>

      <section class="grid">
        <article class="card">
          <h2>1. Gateway (ESP32)</h2>
          <p>Flash firmware, join Wi-Fi, pair Left/Right, confirm version page.</p>
          <ol class="step-list">
            <li>Flash firmware and boot the ESP32.</li>
            <li>If first setup: join <code>BedJetGatewaySetup</code>, open <code>http://192.168.4.1</code>, save Wi-Fi, reboot.</li>
            <li>Open management page: <code>http://bedjet-gateway.local/manage</code>.</li>
            <li>Pair both devices: Left = Mas, Right = Wendy.</li>
          </ol>
          <div class="verify">
            <strong>Verify</strong>
            ${commandBlock("powershell -NoProfile -Command \"Invoke-RestMethod http://bedjet-gateway.local/api/v1/local/status | ConvertTo-Json -Depth 8\"")}
            <p>Check <code>firmware.buildId</code>, <code>smartthings.pollIntervalSeconds</code>, and both sides paired.</p>
          </div>
        </article>

        <article class="card">
          <h2>2. Bridge (Ubuntu VM)</h2>
          <p>Run one script that validates SSH, Docker, claim/auth, deploy, health, and integration.</p>
          <div class="verify">
            <strong>Install + Validate</strong>
            ${commandBlock("powershell -ExecutionPolicy Bypass -File D:\\\\Dev\\\\bedjet-smartthings-bridge\\\\scripts\\\\windows\\\\Setup-BedJetBridge.ps1 -AutoApprove -GatewayBaseUrl http://bedjet-gateway.local")}
          </div>
          <div class="verify">
            <strong>Quick status</strong>
            ${commandBlock("powershell -ExecutionPolicy Bypass -File D:\\\\Dev\\\\bedjet-smartthings-bridge\\\\scripts\\\\windows\\\\Get-BedJetBridgeStatus.ps1")}
          </div>
        </article>

        <article class="card">
          <h2>3. SmartThings Edge Driver</h2>
          <p>Package, install to hub, then use SmartThings app for control.</p>
          <div class="verify">
            <strong>Package + Install (WSL/bash)</strong>
            ${commandBlock("XDG_STATE_HOME=/tmp smartthings edge:drivers:package --channel <channel-id> --hub <hub-id> /mnt/d/Dev/bedjet-smartthings-bridge/smartthings-edge")}
          </div>
          <div class="verify">
            <strong>Set default polling preference (per device)</strong>
            ${commandBlock("XDG_STATE_HOME=/tmp smartthings devices:preferences <device-id> -j")}
            <p>Set <code>pollIntervalSeconds</code> to <code>15</code> (or use gateway portal override).</p>
          </div>
        </article>
      </section>

      <section class="note">
        Gateway portal now includes <strong>SmartThings Sync → Poll interval seconds</strong>.
        Start with 15s. The Edge driver uses gateway value first, then device preference fallback.
      </section>
    </main>

    <script>
      async function copyCmd(button) {
        const code = button.parentElement.querySelector("code").innerText;
        try {
          await navigator.clipboard.writeText(code);
          button.classList.add("ok");
          button.textContent = "Copied";
          setTimeout(() => {
            button.classList.remove("ok");
            button.textContent = "Copy";
          }, 1000);
        } catch {
          button.textContent = "Copy failed";
          setTimeout(() => (button.textContent = "Copy"), 1200);
        }
      }
      window.copyCmd = copyCmd;
    </script>
  </body>
</html>`;
