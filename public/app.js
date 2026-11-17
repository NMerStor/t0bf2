const ENGINES = [
  {
    id: "luaegis",
    group: "built-in",
    name: "luaegis",
    tag: null,
    desc: "API chính (AST obfuscate: rename, encrypt strings/members, control-flow, minify, vmWrap).",
    endpoint: "/api/luaegis/obfuscate",
    field: "source",
    presets: ["light", "medium", "heavy", "maximum"],
  },
  {
    id: "luaegis-vm",
    group: "built-in",
    name: "luaegis · VM mode",
    tag: null,
    desc: "Bytecode VM (stack/register) nhiều lớp + DTC anti-dump probe.",
    endpoint: "/api/luaegis/vm",
    field: "source",
    extraFields: [
      { key: "vmType", label: "VM type", options: ["none", "stack", "register"] },
      { key: "vmLevel", label: "VM level", options: ["debug", "normal", "max"] },
    ],
  },
  {
    id: "clyde",
    group: "built-in",
    name: "Clyde Protection",
    tag: null,
    desc: "Obfuscate (rename/encode strings/scramble/VM) + validate cú pháp Luau. Mặc định của chính Clyde là TẮT hết các cờ encode/scramble (giống server.ts gốc) — 2 ô dưới đây được tick sẵn trên trang test này để bạn thấy obfuscate thật ngay, bỏ tick nếu muốn xem hành vi mặc định gốc.",
    endpoint: "/api/clyde/obfuscate",
    field: "code",
    wrapOptionsKey: "options",
    checkboxFields: [
      { key: "encodeStrings", label: "Encode strings", default: true },
      { key: "scramble", label: "Scramble control flow", default: true },
      { key: "oneLine", label: "One-line output", default: false },
      { key: "noRename", label: "Tắt rename locals", default: false },
      { key: "noPreserve", label: "Tắt preserve globals", default: false },
    ],
    extraFields: [
      { key: "vmType", label: "VM type", options: ["none", "stack", "register"] },
      { key: "vmLevel", label: "VM level", options: ["debug", "normal", "max"] },
    ],
  },
  {
    id: "veil",
    group: "built-in",
    name: "veil",
    tag: null,
    desc: "Preset light/medium/heavy/maximum, tự leak bởi null (free to use).",
    endpoint: "/api/veil/obfuscate",
    field: "source",
    presets: ["light", "medium", "heavy", "maximum"],
  },
  {
    id: "lumora",
    group: "built-in",
    name: "Lumora",
    tag: null,
    desc: "Numerical VM 3 lớp XOR, thuần JS, không cần Lua runtime.",
    endpoint: "/api/lumora/obfuscate",
    field: "source",
  },
  {
    id: "wearedev",
    group: "external",
    name: "WeAreDevs (proxy)",
    tag: null,
    desc: "Forward thẳng sang API công khai của wearedevs.net.",
    endpoint: "/api/wearedev/obfuscate",
    field: "script",
  },
  {
    id: "25ms-obf",
    group: "experimental",
    name: "25ms-obf",
    tag: "old",
    desc: "Fork của Prometheus (không phải bản gốc). Chạy qua wasmoon — thử nghiệm.",
    endpoint: "/api/25ms-obf/obfuscate",
    field: "source",
    presets: ["ol", "Normal", "Vmify", "Minify", "me", "Weak", "doubled", "Medium", "Strong"],
  },
  {
    id: "hercules",
    group: "experimental",
    name: "Hercules",
    tag: "exp",
    desc: "Preset light/balanced/heavy/maximum. Chạy qua wasmoon — thử nghiệm.",
    endpoint: "/api/hercules/obfuscate",
    field: "source",
    presets: ["light", "balanced", "heavy", "maximum"],
  },
  {
    id: "moonsecv2",
    group: "experimental",
    name: "moonsec v2",
    tag: "exp",
    desc: "Dùng string.dump (bytecode) — rủi ro lệch version Lua dưới wasmoon. Thử nghiệm.",
    endpoint: "/api/moonsecv2/obfuscate",
    field: "source",
  },
  {
    id: "voltfuscator",
    group: "external",
    name: "Voltfuscator",
    tag: "proxy",
    desc: "Proxy sang voltils.cc (dịch vụ trả phí bên ngoài) — cần API key Voltfuscator riêng của bạn, có quota theo plan (xem /docs).",
    endpoint: "/api/voltfuscator/obfuscate",
    field: "code",
    presets: ["normal", "ultra"],
    extraFields: [
      { key: "runtime", label: "Runtime", options: ["luau", "lua51", "roblox", "studio", "executor"] },
    ],
    textFields: [{ key: "voltKey", label: "Voltfuscator API key (để trống nếu đã set VOLTFUSCATOR_API_KEY trên server)" }],
  },
  {
    id: "xayz",
    group: "external",
    name: "Xayz",
    tag: "proxy",
    desc: "Proxy sang luaob.vercel.app (dịch vụ bên ngoài, không cần key, ~100 req/IP/giờ).",
    endpoint: "/api/xayz/obfuscate",
    field: "code",
    extraFields: [{ key: "targetMode", label: "Target mode", options: ["roblox", "standard"] }],
  },
  {
    id: "luna-moon",
    group: "experimental",
    name: "Luna Moon",
    tag: "exp",
    desc: "Không reimplement logic — điều khiển headless browser thật trên bản mirror tự host (/luna-moon-mirror). Rất thử nghiệm, chưa test thật, có thể cần chỉnh selector qua env var sau khi tự kiểm tra DOM.",
    endpoint: "/api/luna-moon/obfuscate",
    field: "source",
  },
];

const TABS = [
  { id: "all", label: "Tất cả", description: "Toàn bộ engine hiện có." },
  { id: "built-in", label: "Engine tích hợp", description: "Các engine chạy trong ứng dụng, không qua dịch vụ proxy." },
  { id: "experimental", label: "Thử nghiệm", description: "Engine thử nghiệm; xem ghi chú của từng engine trước khi sử dụng." },
  { id: "external", label: "Dịch vụ bên ngoài", description: "Các engine proxy phụ thuộc vào dịch vụ bên thứ ba." },
];

const SAMPLE = `local function greet(name)\n  print("Hello, " .. name)\nend\n\ngreet("world")`;

function getKey() {
  return localStorage.getItem("t0api_key") || "";
}

function setKey(value) {
  localStorage.setItem("t0api_key", value);
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[character]);
}

function renderKeyBar() {
  const bar = document.getElementById("key-bar");
  bar.innerHTML = `
    <label class="sr-only" for="apikey">API Key</label>
    <input id="apikey" type="password" autocomplete="off" placeholder="Nhập API_KEY của server" value="${escapeHtml(getKey())}" />
  `;
  document.getElementById("apikey").addEventListener("input", (event) => setKey(event.target.value.trim()));
}

function renderEngineCard(engine) {
  const tagLabel = { old: "[old]", exp: "thử nghiệm", proxy: "proxy ngoài" }[engine.tag] || engine.tag;
  const tagHtml = engine.tag ? `<span class="tag ${engine.tag}">${tagLabel}</span>` : "";
  const presetHtml = engine.presets
    ? `<label class="field"><span>Preset</span><select data-role="preset" aria-label="${engine.name} preset">${engine.presets.map((preset) => `<option value="${preset}">${preset}</option>`).join("")}</select></label>`
    : "";
  const extraHtml = (engine.extraFields || [])
    .map((field) => `
      <label class="field"><span>${field.label}</span><select data-role="extra" data-key="${field.key}" aria-label="${field.label}">
        ${field.options.map((option) => `<option value="${option}">${field.label}: ${option}</option>`).join("")}
      </select></label>`)
    .join("");
  const textHtml = (engine.textFields || [])
    .map((field) => `<label class="field"><span>${field.label}</span><input type="password" autocomplete="off" data-role="text" data-key="${field.key}" placeholder="${field.label}" /></label>`)
    .join("");
  const checkboxHtml = (engine.checkboxFields || [])
    .map((field) => `
      <label class="check-field">
        <input type="checkbox" data-role="checkbox" data-key="${field.key}" ${field.default ? "checked" : ""} />
        <span>${field.label}</span>
      </label>`)
    .join("");

  return `
    <article class="card" data-engine="${engine.id}" data-group="${engine.group}">
      <div class="card-heading">
        <h3>${engine.name}${tagHtml}</h3>
        <span class="endpoint">${engine.endpoint}</span>
      </div>
      <p class="desc">${engine.desc}</p>
      <div class="row">
        <textarea data-role="input" aria-label="${engine.name} source code">${SAMPLE}</textarea>
      </div>
      ${(presetHtml || extraHtml) ? `<div class="row fields">${presetHtml}${extraHtml}</div>` : ""}
      ${checkboxHtml ? `<div class="row check-fields">${checkboxHtml}</div>` : ""}
      ${textHtml ? `<div class="row fields">${textHtml}</div>` : ""}
      <div class="row actions">
        <button type="button" data-role="run">${engine.disabled ? "Obfuscate (sẽ lỗi 501)" : "Obfuscate"}</button>
      </div>
      <section class="out" data-role="out" hidden aria-label="${engine.name} result">
        <div class="meta" data-role="meta" aria-live="polite"></div>
        <textarea data-role="result" aria-label="${engine.name} output" readonly></textarea>
        <div class="row actions">
          <button type="button" class="secondary" data-role="copy" disabled>Copy kết quả</button>
        </div>
        <p class="err" data-role="err" role="alert"></p>
      </section>
    </article>
  `;
}

async function runEngine(engine, card) {
  const button = card.querySelector('[data-role="run"]');
  const output = card.querySelector('[data-role="out"]');
  const meta = card.querySelector('[data-role="meta"]');
  const resultBox = card.querySelector('[data-role="result"]');
  const copyButton = card.querySelector('[data-role="copy"]');
  const errBox = card.querySelector('[data-role="err"]');
  const source = card.querySelector('[data-role="input"]').value;
  const body = { [engine.field]: source };
  const preset = card.querySelector('[data-role="preset"]');
  if (preset) body.preset = preset.value;

  const options = {};
  card.querySelectorAll('[data-role="extra"]').forEach((select) => {
    options[select.dataset.key] = select.value;
  });
  card.querySelectorAll('[data-role="checkbox"]').forEach((checkbox) => {
    options[checkbox.dataset.key] = checkbox.checked;
  });
  if (engine.wrapOptionsKey) {
    body[engine.wrapOptionsKey] = options;
  } else {
    Object.assign(body, options);
  }
  card.querySelectorAll('[data-role="text"]').forEach((input) => {
    if (input.value.trim()) body[input.dataset.key] = input.value.trim();
  });

  button.disabled = true;
  button.textContent = "Đang xử lý...";
  output.hidden = false;
  errBox.textContent = "";
  resultBox.value = "";
  copyButton.disabled = true;
  meta.textContent = "";

  try {
    const response = await fetch(engine.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": getKey() },
      body: JSON.stringify(body),
    });
    const data = await response.json().catch(() => ({}));

    if (!response.ok || data.success === false) {
      errBox.textContent = (data && (data.detail || data.error)) || `Lỗi HTTP ${response.status}`;
    } else {
      resultBox.value = data.output || JSON.stringify(data, null, 2);
      copyButton.disabled = !resultBox.value;
      const details = [];
      if (data.engine) details.push(data.engine);
      if (data.preset) details.push(`preset=${data.preset}`);
      if (data.seed !== undefined) details.push(`seed=${JSON.stringify(data.seed)}`);
      if (data.experimental) details.push("experimental");
      meta.textContent = details.join(" · ");
    }
  } catch (error) {
    errBox.textContent = `Network error: ${error.message}`;
  } finally {
    button.disabled = false;
    button.textContent = "Obfuscate";
  }
}

function currentTabId() {
  const match = location.hash.match(/^#tab=([^&]+)/);
  const id = match ? match[1] : "all";
  return TABS.some((tab) => tab.id === id) ? id : "all";
}

function selectTab(tabId, updateUrl = true) {
  const selectedTab = TABS.find((tab) => tab.id === tabId) || TABS[0];
  const tabs = document.getElementById("engine-tabs");
  tabs.querySelectorAll('[role="tab"]').forEach((tab) => {
    const active = tab.dataset.tab === selectedTab.id;
    tab.setAttribute("aria-selected", String(active));
    tab.tabIndex = active ? 0 : -1;
  });
  document.querySelectorAll(".card").forEach((card) => {
    card.hidden = selectedTab.id !== "all" && card.dataset.group !== selectedTab.id;
  });
  document.getElementById("engines").setAttribute("aria-labelledby", `tab-${selectedTab.id}`);
  document.getElementById("tab-description").textContent = selectedTab.description;

  const count = selectedTab.id === "all"
    ? ENGINES.length
    : ENGINES.filter((engine) => engine.group === selectedTab.id).length;
  document.getElementById("engine-count").textContent = `${count} engines`;

  if (updateUrl) {
    history.replaceState(null, "", `${location.pathname}${location.search}#tab=${selectedTab.id}`);
  }
}

function renderTabs() {
  const tabs = document.getElementById("engine-tabs");
  tabs.innerHTML = TABS.map((tab) => {
    const count = tab.id === "all" ? ENGINES.length : ENGINES.filter((engine) => engine.group === tab.id).length;
    return `
      <button type="button" role="tab" id="tab-${tab.id}" aria-controls="engines" aria-selected="false" tabindex="-1" data-tab="${tab.id}">
        ${tab.label}<span class="tab-count">${count}</span>
      </button>`;
  }).join("");

  tabs.querySelectorAll('[role="tab"]').forEach((button) => {
    button.addEventListener("click", () => selectTab(button.dataset.tab));
    button.addEventListener("keydown", (event) => {
      const buttons = [...tabs.querySelectorAll('[role="tab"]')];
      const index = buttons.indexOf(button);
      const next = event.key === "ArrowRight" ? (index + 1) % buttons.length
        : event.key === "ArrowLeft" ? (index - 1 + buttons.length) % buttons.length
          : event.key === "Home" ? 0
            : event.key === "End" ? buttons.length - 1
              : -1;
      if (next !== -1) {
        event.preventDefault();
        buttons[next].focus();
        selectTab(buttons[next].dataset.tab);
      }
    });
  });
}

function init() {
  renderKeyBar();
  renderTabs();
  const container = document.getElementById("engines");
  container.innerHTML = ENGINES.map(renderEngineCard).join("");

  container.querySelectorAll(".card").forEach((card) => {
    const engine = ENGINES.find((entry) => entry.id === card.dataset.engine);
    card.querySelector('[data-role="run"]').addEventListener("click", () => runEngine(engine, card));
    card.querySelector('[data-role="copy"]').addEventListener("click", async () => {
      const text = card.querySelector('[data-role="result"]').value;
      const button = card.querySelector('[data-role="copy"]');
      try {
        if (!navigator.clipboard) throw new Error("Clipboard is unavailable");
        await navigator.clipboard.writeText(text);
        button.textContent = "Đã sao chép";
        window.setTimeout(() => { button.textContent = "Copy kết quả"; }, 1600);
      } catch {
        card.querySelector('[data-role="err"]').textContent = "Không thể truy cập clipboard. Hãy sao chép nội dung trong ô kết quả.";
      }
    });
  });

  selectTab(currentTabId(), false);
  window.addEventListener("hashchange", () => selectTab(currentTabId(), false));
}

document.addEventListener("DOMContentLoaded", init);
