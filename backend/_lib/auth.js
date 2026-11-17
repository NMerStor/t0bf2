// Shared API-key gate. Set the real key in the Vercel project's
// Environment Variables as API_KEY — nothing is hardcoded here.
//
// Accepts either header:
//   X-API-Key: <key>
//   Authorization: Bearer <key>

export function requireApiKey(req, res) {
  const configured = process.env.API_KEY;

  if (!configured) {
    // Fail closed: if you haven't set API_KEY in Vercel yet, every call
    // is rejected instead of silently running the API open to the public.
    res.status(500).json({
      success: false,
      error: "Server misconfigured: API_KEY is not set in the Vercel project environment variables.",
    });
    return false;
  }

  const header = req.headers["x-api-key"];
  const authHeader = req.headers["authorization"];
  const bearer = typeof authHeader === "string" && authHeader.toLowerCase().startsWith("bearer ")
    ? authHeader.slice(7).trim()
    : null;

  const provided = header || bearer;

  if (!provided || provided !== configured) {
    res.status(401).json({
      success: false,
      error: "Missing or invalid API key. Send it as 'X-API-Key: <key>' or 'Authorization: Bearer <key>'.",
    });
    return false;
  }

  return true;
}
