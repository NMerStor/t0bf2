const ENGINES = [
  {
    id: "luaegis",
    name: "luaegis",
    tag: null,
    desc: "API chính (AST obfuscate: rename, encrypt strings/members, control-flow, minify, vmWrap).",
    endpoint: "/api/luaegis/obfuscate",
    field: "source",
    presets: ["light", "medium", "heavy", "maximum"],
  },
  {
    id: "luaegis-vm",
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
    name: "veil",
    tag: null,
    desc: "Preset light/medium/heavy/maximum, tự leak bởi null (free to use).",
    endpoint: "/api/veil/obfuscate",
    field: "source",
    presets: ["light", "medium", "heavy", "maximum"],
  },
  {
    id: "lumora",
    name: "Lumora",
    tag: null,
    desc: "Numerical VM 3 lớp XOR, thuần JS, không cần Lua runtime.",
    endpoint: "/api/lumora/obfuscate",
    field: "source",
  },
  {
    id: "wearedev",
    name: "WeAreDevs (proxy)",
    tag: null,
    desc: "Forward thẳng sang API công khai của wearedevs.net.",
    endpoint: "/api/wearedev/obfuscate",
    field: "script",
  },
  {
    id: "25ms-obf",
    name: "25ms-obf",
    tag: "old",
    desc: "Fork của Prometheus (không phải bản gốc). Chạy qua wasmoon — thử nghiệm.",
    endpoint: "/api/25ms-obf/obfuscate",
    field: "source",
    presets: ["ol", "Normal", "Vmify", "Minify", "me", "Weak", "doubled", "Medium", "Strong"],
  },
  {
    id: "hercules",
    name: "Hercules",
    tag: "exp",
    desc: "Preset light/balanced/heavy/maximum. Chạy qua wasmoon — thử nghiệm.",
    endpoint: "/api/hercules/obfuscate",
    field: "source",
    presets: ["light", "balanced", "heavy", "maximum"],
  },
  {
    id: "moonsecv2",
    name: "moonsec v2",
    tag: "exp",
    desc: "Dùng string.dump (bytecode) — rủi ro lệch version Lua dưới wasmoon. Thử nghiệm.",
    endpoint: "/api/moonsecv2/obfuscate",
    field: "source",
  },
  {
    id: "voltfuscator",
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
    name: "Xayz",
    tag: "proxy",
    desc: "Proxy sang luaob.vercel.app (dịch vụ bên ngoài, không cần key, ~100 req/IP/giờ).",
    endpoint: "/api/xayz/obfuscate",
    field: "code",
    extraFields: [{ key: "targetMode", label: "Target mode", options: ["roblox", "standard"] }],
  },
  {
    id: "luna-moon",
    name: "Luna Moon",
    tag: "exp",
    desc: "Không reimplement logic — điều khiển headless browser thật trên bản mirror tự host (/luna-moon-mirror). Rất thử nghiệm, chưa test thật, có thể cần chỉnh selector qua env var sau khi tự kiểm tra DOM.",
    endpoint: "/api/luna-moon/obfuscate",
    field: "source",
  },
];

const SAMPLE = `local function greet(name)\n  print("Hello, " .. name)\nend\n\ngreet("world")`;

function getKey() {
  return localStorage.getItem("t0api_key") || "";
}
function setKey(v) {
  localStorage.setItem("t0api_key", v);
}

function renderKeyBar() {
  const bar = document.getElementById("key-bar");
  bar.innerHTML = `
    <label for="apikey">API Key</label>
    <input id="apikey" type="text" placeholder="Dán API key của bạn (đặt trong Vercel env API_KEY)" value="${getKey().replace(/"/g, "&quot;")}" />
    <span class="status">Chỉ lưu trong trình duyệt của bạn (localStorage), không gửi đi đâu khác.</span>
  `;
  document.getElementById("apikey").addEventListener("input", (e) => setKey(e.target.value.trim()));
}

function renderEngineCard(engine) {
  const tagLabel = { old: "[old]", exp: "thử nghiệm", proxy: "proxy ngoài" }[engine.tag] || engine.tag;
  const tagHtml = engine.tag ? `<span class="tag ${engine.tag}">${tagLabel}</span>` : "";
  const presetHtml = engine.presets
    ? `<select data-role="preset">${engine.presets.map((p) => `<option value="${p}">${p}</option>`).join("")}</select>`
    : "";
  const extraHtml = (engine.extraFields || [])
    .map(
      (f) => `
      <select data-role="extra" data-key="${f.key}">
        ${f.options.map((o) => `<option value="${o}">${f.label}: ${o}</option>`).join("")}
      </select>`
    )
    .join("");

  const textHtml = (engine.textFields || [])
    .map(
      (f) => `<input type="text" data-role="text" data-key="${f.key}" placeholder="${f.label}" />`
    )
    .join("");

  const checkboxHtml = (engine.checkboxFields || [])
    .map(
      (f) => `
      <label style="display:flex;align-items:center;gap:6px;font-size:0.85rem;flex:none;">
        <input type="checkbox" data-role="checkbox" data-key="${f.key}" ${f.default ? "checked" : ""} />
        ${f.label}
      </label>`
    )
    .join("");

  return `
    <div class="card" data-engine="${engine.id}">
      <h2>${engine.name}${tagHtml}</h2>
      <p class="desc">${engine.desc}</p>
      <div class="row">
        <textarea data-role="input">${SAMPLE}</textarea>
      </div>
      <div class="row">
        ${presetHtml}
        ${extraHtml}
      </div>
      ${checkboxHtml ? `<div class="row">${checkboxHtml}</div>` : ""}
      ${textHtml ? `<div class="row">${textHtml}</div>` : ""}
      <div class="row">
        <button data-role="run">${engine.disabled ? "Obfuscate (sẽ lỗi 501)" : "Obfuscate"}</button>
      </div>
      <div class="out" data-role="out" style="display:none;">
        <div class="meta" data-role="meta"></div>
        <textarea data-role="result" readonly></textarea>
        <div class="row">
          <button class="secondary" data-role="copy">Copy kết quả</button>
        </div>
        <div class="err" data-role="err"></div>
      </div>
    </div>
  `;
}

async function runEngine(engine, card) {
  const btn = card.querySelector('[data-role="run"]');
  const out = card.querySelector('[data-role="out"]');
  const meta = card.querySelector('[data-role="meta"]');
  const resultBox = card.querySelector('[data-role="result"]');
  const errBox = card.querySelector('[data-role="err"]');
  const input = card.querySelector('[data-role="input"]').value;

  const body = { [engine.field]: input };
  const presetSel = card.querySelector('[data-role="preset"]');
  if (presetSel) body.preset = presetSel.value;

  // Extra selects (e.g. vmType/vmLevel) and checkboxes either go flat on the
  // body, or nested under a key like "options" (Clyde's API shape), per
  // engine.wrapOptionsKey.
  const extras = {};
  card.querySelectorAll('[data-role="extra"]').forEach((sel) => {
    extras[sel.dataset.key] = sel.value;
  });
  card.querySelectorAll('[data-role="checkbox"]').forEach((cb) => {
    extras[cb.dataset.key] = cb.checked;
  });

  if (engine.wrapOptionsKey) {
    body[engine.wrapOptionsKey] = extras;
  } else {
    Object.assign(body, extras);
  }

  // Text fields (e.g. a per-request third-party API key) always go
  // top-level on the body, never nested under wrapOptionsKey.
  card.querySelectorAll('[data-role="text"]').forEach((input) => {
    if (input.value.trim()) body[input.dataset.key] = input.value.trim();
  });

  btn.disabled = true;
  btn.textContent = "Đang xử lý...";
  out.style.display = "block";
  errBox.textContent = "";
  resultBox.value = "";
  meta.textContent = "";

  try {
    const res = await fetch(engine.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": getKey() },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));

    if (!res.ok || data.success === false) {
      errBox.textContent = (data && (data.detail || data.error)) || `Lỗi HTTP ${res.status}`;
    } else {
      resultBox.value = data.output || JSON.stringify(data, null, 2);
      const bits = [];
      if (data.engine) bits.push(data.engine);
      if (data.preset) bits.push(`preset=${data.preset}`);
      if (data.seed !== undefined) bits.push(`seed=${JSON.stringify(data.seed)}`);
      if (data.experimental) bits.push("experimental");
      meta.textContent = bits.join(" · ");
    }
  } catch (e) {
    errBox.textContent = "Network error: " + e.message;
  } finally {
    btn.disabled = false;
    btn.textContent = "Obfuscate";
  }
}

function init() {
  renderKeyBar();
  const container = document.getElementById("engines");
  container.innerHTML = ENGINES.map(renderEngineCard).join("");

  container.querySelectorAll(".card").forEach((card) => {
    const engine = ENGINES.find((e) => e.id === card.dataset.engine);
    card.querySelector('[data-role="run"]').addEventListener("click", () => runEngine(engine, card));
    card.querySelector('[data-role="copy"]').addEventListener("click", () => {
      const txt = card.querySelector('[data-role="result"]').value;
      navigator.clipboard?.writeText(txt);
    });
  });
}

document.addEventListener("DOMContentLoaded", init);
