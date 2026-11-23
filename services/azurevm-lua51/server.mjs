import { timingSafeEqual } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT || 8080);
const MAX_SOURCE_BYTES = 400_000;
const MAX_REQUEST_BYTES = MAX_SOURCE_BYTES + 32_000;
const MAX_OUTPUT_BYTES = 20_000_000;
const MAX_ERROR_BYTES = 64_000;
const RUN_TIMEOUT_MS = 240_000;
const PRESETS = new Set([
  "Minify", "Weak", "Vmify", "Medium", "Strong", "Luraph", "Luraph14",
  "Luraph15", "AzureGod", "AzureGod15", "AzureGodUltra", "Fast",
  "Balanced", "Hardened", "Research",
]);
const RUNNER_PATH = fileURLToPath(new URL("./runner.lua", import.meta.url));
const SERVICE_TOKEN = process.env.AZUREVM_LUA51_SERVICE_TOKEN;

if (!SERVICE_TOKEN) {
  throw new Error("AZUREVM_LUA51_SERVICE_TOKEN must be set.");
}
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  throw new Error("PORT must be a valid TCP port.");
}

function sendJson(response, status, value) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

function authorized(request) {
  const authorization = request.headers.authorization || "";
  const expected = Buffer.from(`Bearer ${SERVICE_TOKEN}`);
  const actual = Buffer.from(authorization);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

async function readJsonBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_REQUEST_BYTES) {
      const error = new Error("Request body is too large.");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("Request body must be valid JSON.");
    error.statusCode = 400;
    throw error;
  }
}

function runAzureVm(source, preset, seed) {
  return new Promise((resolve, reject) => {
    const child = spawn("lua5.1", [RUNNER_PATH, preset, String(seed)], {
      cwd: "/app",
      stdio: ["pipe", "pipe", "pipe"],
    });
    const output = [];
    const errors = [];
    let outputBytes = 0;
    let errorBytes = 0;
    let timedOut = false;
    let outputTooLarge = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, RUN_TIMEOUT_MS);

    child.stdout.on("data", (chunk) => {
      outputBytes += chunk.length;
      if (outputBytes > MAX_OUTPUT_BYTES) {
        outputTooLarge = true;
        child.kill("SIGKILL");
        return;
      }
      output.push(chunk);
    });
    child.stderr.on("data", (chunk) => {
      if (errorBytes >= MAX_ERROR_BYTES) return;
      const remaining = MAX_ERROR_BYTES - errorBytes;
      const limitedChunk = chunk.subarray(0, remaining);
      errors.push(limitedChunk);
      errorBytes += limitedChunk.length;
    });
    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code, signal) => {
      clearTimeout(timeout);
      if (timedOut) {
        reject(Object.assign(new Error("Lua 5.1 obfuscation timed out."), { statusCode: 504 }));
      } else if (outputTooLarge) {
        reject(Object.assign(new Error("Generated output exceeded the service limit."), { statusCode: 502 }));
      } else if (code !== 0) {
        const detail = Buffer.concat(errors).toString("utf8").trim();
        reject(Object.assign(new Error(detail || `Lua 5.1 process failed (${signal || code}).`), { statusCode: 422 }));
      } else {
        resolve(Buffer.concat(output).toString("utf8"));
      }
    });

    child.stdin.on("error", (error) => {
      if (error.code !== "EPIPE") child.kill("SIGKILL");
    });
    child.stdin.end(source);
  });
}

const server = createServer(async (request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    return sendJson(response, 200, { success: true, runtime: "Lua 5.1" });
  }
  if (request.method !== "POST" || request.url !== "/obfuscate") {
    return sendJson(response, 404, { success: false, error: "Not found." });
  }
  if (!authorized(request)) {
    return sendJson(response, 401, { success: false, error: "Unauthorized." });
  }

  try {
    const body = await readJsonBody(request);
    const source = body?.source;
    const preset = body?.preset || "Luraph";
    if (typeof source !== "string" || source.length === 0) {
      return sendJson(response, 400, { success: false, error: "source must be a non-empty string." });
    }
    if (Buffer.byteLength(source, "utf8") > MAX_SOURCE_BYTES) {
      return sendJson(response, 413, { success: false, error: `Source exceeds ${MAX_SOURCE_BYTES} bytes.` });
    }
    if (!PRESETS.has(preset)) {
      return sendJson(response, 400, { success: false, error: "Unsupported AzureVM preset." });
    }
    if (body.seed !== undefined && (!Number.isSafeInteger(body.seed) || body.seed < 1 || body.seed > 2147483647)) {
      return sendJson(response, 400, { success: false, error: "seed must be an integer between 1 and 2147483647." });
    }

    const seed = body.seed ?? Math.floor(Math.random() * 2147483647) + 1;
    const output = await runAzureVm(source, preset, seed);
    return sendJson(response, 200, { output });
  } catch (error) {
    const status = error.statusCode || 500;
    const detail = error instanceof Error ? error.message : String(error);
    return sendJson(response, status, { success: false, error: detail });
  }
});

server.requestTimeout = 30_000;
server.listen(PORT, "0.0.0.0");
