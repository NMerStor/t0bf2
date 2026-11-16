export function setCors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, X-API-Key, Authorization");
  res.setHeader("Access-Control-Max-Age", "86400");
  res.setHeader("Cache-Control", "no-store");
}

/**
 * Runs the common preamble for every endpoint:
 *  - CORS headers
 *  - OPTIONS preflight short-circuit
 *  - method check
 *  - API key check
 * Returns false if the request was already handled (and the caller should stop).
 */
export function guard(req, res, { method = "POST" } = {}) {
  setCors(res);

  if (req.method === "OPTIONS") {
    res.status(204).end();
    return false;
  }

  if (req.method !== method) {
    res.setHeader("Allow", `${method}, OPTIONS`);
    res.status(405).json({ success: false, error: `Method not allowed. Use ${method}.` });
    return false;
  }

  return true;
}
