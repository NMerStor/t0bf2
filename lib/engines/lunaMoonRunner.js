// Drives the real Luna Moon web app with a headless browser instead of
// reimplementing its obfuscation logic. We tried reverse-engineering the
// minified client bundle (see lib/engines/luna-moon/NOTES.md) and hit a
// dead end: the extracted engine.js had no callable entry point. A fresh
// mirror of the live site (public/luna-moon-mirror/) shows why re-trying
// that path isn't worth it either -- the CURRENT build of the site doesn't
// even contain obfuscation logic in its JS bundle anymore; it talks to a
// real backend over WebSocket (Convex, at compassionate-ant-590.convex.cloud,
// found as a literal string in the bundle). So there is no "pure client
// logic" left to extract -- the actual work happens on a server we don't
// control, same dependency class as the wearedev/voltfuscator/xayz proxies.
//
// Given that, driving the real UI with a headless browser is the only
// approach that doesn't require guessing at that backend's private API.
// We navigate to OUR OWN hosted copy of the static frontend
// (public/luna-moon-mirror/, from the zip you provided) so this doesn't
// depend on obfuuscator.vercel.app staying reachable -- the JS still talks
// to the same real Convex backend over the network either way.
//
// *** UNVERIFIED / HIGH UNCERTAINTY ***
// This sandbox has no network and no real browser, so nothing below has
// been run end-to-end. The DOM selectors are *inferred* from strings found
// inside the minified bundle (e.g. a contenteditable-based code editor
// using a "data-placeholder-text" attribute, and "copy"/"download" as
// button labels) -- not confirmed against the real rendered page. Every
// selector is overridable via env vars so you can fix it without a code
// change once you've opened the real mirror page in a real browser and
// checked what's actually there (see README.md "Luna Moon — cần bạn tự
// kiểm tra DOM thật" for how).

import puppeteer from "puppeteer-core";

const DEFAULT_TIMEOUT_MS = 45_000;

if (process.env.VERCEL) {
  const nodeMajorVersion = Number.parseInt(process.versions.node.split(".")[0], 10);
  process.env.AWS_EXECUTION_ENV = nodeMajorVersion >= 20
    ? "AWS_Lambda_nodejs20.x"
    : "AWS_Lambda_nodejs18.x";
}

const chromium = (await import("@sparticuz/chromium")).default;

function mirrorUrl() {
  if (process.env.LUNA_MOON_MIRROR_URL) return process.env.LUNA_MOON_MIRROR_URL;
  const host = process.env.VERCEL_URL; // e.g. "t0api-yourname.vercel.app", set automatically by Vercel
  if (host) return `https://${host}/luna-moon-mirror/index.html`;
  // Local `vercel dev` fallback.
  return "http://localhost:3000/luna-moon-mirror/index.html";
}

export async function lunaMoonObfuscate(source, { timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  if (typeof source !== "string" || source.length === 0) {
    throw new Error("source must be a non-empty string");
  }

  const url = mirrorUrl();
  const browser = await puppeteer.launch({
    args: chromium.args,
    executablePath: await chromium.executablePath(),
    headless: chromium.headless,
    defaultViewport: { width: 1280, height: 900 },
  });

  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(timeoutMs);

    await page.goto(url, { waitUntil: "networkidle2", timeout: timeoutMs });

    // Give the React app a moment to hydrate and (if applicable) establish
    // its anonymous Convex session before we start probing the DOM.
    await page.waitForFunction(
      () => document.querySelector("textarea, [contenteditable='true'], [data-placeholder-text]") !== null,
      { timeout: timeoutMs }
    );

    const inputSelector = process.env.LUNA_MOON_INPUT_SELECTOR || null;
    const typed = await page.evaluate(
      (sel, src) => {
        function pickEditor() {
          if (sel) return document.querySelector(sel);
          // Prefer a real <textarea>; otherwise the largest
          // contenteditable/data-placeholder-text element (heuristic: the
          // code editor is almost always the biggest such box on the page).
          const textareas = [...document.querySelectorAll("textarea")];
          if (textareas.length) {
            return textareas.sort((a, b) => b.clientHeight * b.clientWidth - a.clientHeight * a.clientWidth)[0];
          }
          const candidates = [...document.querySelectorAll("[contenteditable='true'], [data-placeholder-text]")];
          if (candidates.length) {
            return candidates.sort((a, b) => b.clientHeight * b.clientWidth - a.clientHeight * a.clientWidth)[0];
          }
          return null;
        }
        const el = pickEditor();
        if (!el) return { ok: false, reason: "no editor element found" };
        el.scrollIntoView({ block: "center" });
        el.focus();
        if ("value" in el) {
          // Plain <textarea>: set value via the native setter so React's
          // controlled-input tracking (which patches the value setter)
          // still sees the change, then dispatch a real input event.
          const proto = Object.getPrototypeOf(el);
          const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
          if (setter) setter.call(el, src);
          else el.value = src;
          el.dispatchEvent(new Event("input", { bubbles: true }));
        } else {
          el.textContent = src;
          el.dispatchEvent(new InputEvent("input", { bubbles: true, data: src }));
        }
        return { ok: true, tag: el.tagName, usedSelector: sel || "(auto-picked)" };
      },
      inputSelector,
      source
    );

    if (!typed.ok) {
      throw new Error(`Could not find the code editor on the page (${typed.reason}). Set LUNA_MOON_INPUT_SELECTOR after inspecting the real DOM.`);
    }

    // Click the button whose visible text matches (default: "obfuscate").
    const buttonText = (process.env.LUNA_MOON_BUTTON_TEXT || "obfuscate").toLowerCase();
    const clicked = await page.evaluate((text) => {
      const candidates = [...document.querySelectorAll("button, [role='button']")];
      const match = candidates.find((b) => b.textContent.trim().toLowerCase().includes(text));
      if (!match) return false;
      match.click();
      return true;
    }, buttonText);

    if (!clicked) {
      throw new Error(`Could not find a button containing text "${buttonText}". Set LUNA_MOON_BUTTON_TEXT after inspecting the real DOM.`);
    }

    // Wait for a result. Prefer an explicit output selector if given;
    // otherwise poll for a "copy"/"download" affordance appearing (the
    // bundle contains those as literal strings, suggesting they only show
    // up once there's a result) and then grab the largest new text block
    // on the page as the output.
    const outputSelector = process.env.LUNA_MOON_OUTPUT_SELECTOR || null;
    const result = await page.waitForFunction(
      (sel, inputLen) => {
        function biggestTextBlock() {
          const blocks = [...document.querySelectorAll("pre, code, textarea, [contenteditable='true'], [data-placeholder-text], div")];
          let best = null;
          for (const el of blocks) {
            const text = "value" in el ? el.value : el.textContent;
            if (!text || text.length < inputLen + 5) continue; // must be longer than the input we typed
            if (!best || text.length > best.length) best = text;
          }
          return best || null;
        }
        if (sel) {
          const el = document.querySelector(sel);
          const text = el ? ("value" in el ? el.value : el.textContent) : null;
          return text && text.length > 0 ? text : false;
        }
        const hasCopyOrDownload = [...document.querySelectorAll("button, [role='button']")]
          .some((b) => /copy|download/i.test(b.textContent));
        if (!hasCopyOrDownload) return false;
        const text = biggestTextBlock();
        return text || false;
      },
      { timeout: timeoutMs, polling: 500 },
      outputSelector,
      source.length
    );

    const output = await result.jsonValue();
    if (typeof output !== "string" || output.length === 0) {
      throw new Error("Obfuscation seemed to run but no output text could be extracted from the page.");
    }
    return { output };
  } finally {
    await browser.close();
  }
}
