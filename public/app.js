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
    desc: "Obfuscate (rename/encode strings/scramble/VM) + validate cú pháp Luau.",
    endpoint: "/api/clyde/obfuscate",
    field: "code",
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
  const tagHtml = engine.tag ? `<span class="tag ${engine.tag}">${engine.tag === "old" ? "[old]" : "thử nghiệm"}</span>` : "";
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
      <div class="row">
        <button data-role="run">Obfuscate</button>
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
  card.querySelectorAll('[data-role="extra"]').forEach((sel) => {
    body[sel.dataset.key] = sel.value;
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
