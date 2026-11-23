# Voltfuscator API Documentation (Official)

> **Source**: [https://voltils.cc/docs/](https://voltils.cc/docs/)  
> **Version**: v8.0  
> **Last updated from official docs**

---
6 time Per Day,reset At 12:00 And 12:00,Every 12H +3 Time Use,24H>6 Time Per Day.
## Overview

Voltfuscator is a Lua 5.1 / Luau obfuscator by Voltils.  
You can use it via:

- Website Dashboard
- Discord Bot
- **REST API** (`POST /v1/obfuscate`)

All accounts can create private API keys from the dashboard.

---

## Authentication

- Create an API key in the dashboard → **API Keys**
- Send the key in the `Authorization` header as a Bearer token
- **Never** put the API key in frontend code or public repositories
- API keys expire after **30 days** without use

```
Authorization: Bearer YOUR_API_KEY
```

---

## Endpoint

```
POST https://voltils.cc/v1/obfuscate
```

**Headers:**
```
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json
```

---

## Request Body

```json
{
  "code": "print('hello')",
  "preset": "normal",
  "runtime": "roblox"
}
```

### Parameters

| Field     | Type   | Required | Default     | Description |
|-----------|--------|----------|-------------|-------------|
| `code`    | string | Yes      | -           | Source code to obfuscate (Lua / Luau) |
| `preset`  | string | No       | `"normal"`  | Protection level |
| `runtime` | string | No       | `"luau"`    | Target runtime |

### Preset values

| Value     | Description |
|-----------|-------------|
| `normal`  | Default. Strong protection + practical performance (replaces old "Max") |
| `ultra`   | Higher protection (larger output, higher runtime cost) |

> `max` is **no longer accepted**.

### Runtime values

| Value      | Description |
|------------|-------------|
| `luau`     | Portable Luau (API default) |
| `lua51`    | Standard Lua 5.1 |
| `roblox`   | Roblox / Studio (developer scripts + published games) |
| `studio`   | Roblox Studio |
| `executor` | Roblox Executor (requires `getgenv()` + executor name) |

---

## Full HTTP Example

```http
POST https://voltils.cc/v1/obfuscate
Authorization: Bearer YOUR_API_KEY
Content-Type: application/json

{
  "code": "print('hello')",
  "preset": "normal",
  "runtime": "roblox"
}
```

### Success Response (example)

```json
{
  "success": true,
  "obfuscated": "-- protected code here ..."
}
```

---

## Rate Limits & Quotas

| Plan      | Successful builds (rolling 12h) | Daily maximum | Source size limit |
|-----------|----------------------------------|---------------|-------------------|
| **Basic** | 3                                | 6             | 350 KB            |
| **Pro**   | 12                               | 24            | 500 KB            |
| **Elite** | 120                              | 240           | 600 KB            |
| **Commercial** | Negotiable                   | Negotiable    | up to 1 MB+       |

- Quota is **shared** across Website + Discord Bot + API
- Failed builds **do not** count toward the quota
- Daily limits reset at **00:00 UTC**
- Size is measured in UTF-8 bytes (1 KB = 1024 bytes)
- Compiler default timeout: **15 seconds** per job

---

## Macros (Supported in source)

You can use these macros inside your Lua/Luau code for fine-grained control:

### Performance macros
- `VLT_JIT(function() ... end)`
- `VLT_JIT_MAX(function() ... end)` / `VLT_JITMAX`
- `VLT_NO_VIRTUALIZE(function() ... end)`

### Compatibility aliases (also supported)
- `LPH_*` (Luraph-style)
- `MV_*` (MoonVeil-style)
- `VOLTFUSCATOR_*`

Common ones:
- `VLT_NO_VIRTUALIZE` / `LPH_NO_VIRTUALIZE` / `MV_NO_VIRTUALIZE`
- `VLT_JIT` / `LPH_JIT` / `MV_JIT`
- Encryption / line / crash macros are also supported

---

## Important Notes

- Only obfuscate code you own or have permission to process
- Do not put secrets (tokens, passwords) inside scripts
- `executor` runtime requires a real Roblox executor environment (`getgenv()` + non-blank executor name)
- If the compiler is busy, the API returns a retry delay instead of queuing
- One active protected build per account at a time

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Runtime mismatch | Choose correct runtime (`lua51`, `roblox`, `executor`...) |
| Syntax error | Test original script first |
| Rate limited | Wait for the returned retry delay |
| Key expired | Create a new API key (keys expire after 30 days of inactivity) |

---

**Official Documentation**: https://voltils.cc/docs/  
**Dashboard / API Keys**: https://voltils.cc/dashboard/
