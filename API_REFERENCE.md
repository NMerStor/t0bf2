# t0api — API Reference (đầy đủ, dùng trực tiếp cho bot)

File này chứa toàn bộ thông tin cần để gọi API từ bot Discord (hoặc bất kỳ client nào) —
không cần vào web `/docs` copy từng cái. Base URL thay `<domain>` bằng domain Vercel của bạn,
ví dụ `https://t0api-yourname.vercel.app`.

## Mục lục

- [Xác thực](#xác-thực)
- [Giới hạn & lưu ý chung](#giới-hạn--lưu-ý-chung)
- [1. GET /api/health](#1-get-apihealth)
- [2. POST /api/luaegis/obfuscate](#2-post-apiluaegisobfuscate)
- [3. POST /api/luaegis/vm](#3-post-apiluaegisvm)
- [4. POST /api/luaegis/validate](#4-post-apiluaegisvalidate)
- [5. POST /api/clyde/obfuscate](#5-post-apiclydeobfuscate)
- [6. POST /api/clyde/validate](#6-post-apiclydevalidate)
- [7. POST /api/veil/obfuscate](#7-post-apiveilobfuscate)
- [8. POST /api/lumora/obfuscate](#8-post-apilumoraobfuscate)
- [9. POST /api/wearedev/obfuscate](#9-post-apiwearedevobfuscate)
- [10. POST /api/25ms-obf/obfuscate](#10-post-api25ms-obfobfuscate)
- [11. POST /api/hercules/obfuscate](#11-post-apiherculesobfuscate)
- [12. POST /api/moonsecv2/obfuscate](#12-post-apimoonsecv2obfuscate)
- [13. POST /api/voltfuscator/obfuscate](#13-post-apivoltfuscatorobfuscate)
- [14. POST /api/xayz/obfuscate](#14-post-apixayzobfuscate)
- [15. POST /api/luna-moon/obfuscate (chưa chạy được)](#15-post-apiluna-moonobfuscate-chưa-chạy-được)
- [Bảng tổng hợp nhanh](#bảng-tổng-hợp-nhanh)

---

## Xác thực

Mọi endpoint trừ `/api/health` yêu cầu header:

```
X-API-Key: <API_KEY bạn đặt trong Vercel env vars>
```
hoặc
```
Authorization: Bearer <API_KEY>
```

Nếu server chưa set biến môi trường `API_KEY`, **mọi** request (kể cả có key) sẽ bị từ chối
(fail-closed, status 500).

Response luôn có field `success: true|false`. Khi `false`, xem `error` (và `detail` nếu có).

## Giới hạn & lưu ý chung

- Vercel Hobby: timeout 10s/function, không tăng được. Các route nặng (`luaegis/vm`, `25ms-obf`,
  `hercules`, `moonsecv2`, `wearedev`) đã set `maxDuration: 60` trong `vercel.json` — chỉ có hiệu
  lực nếu bạn ở plan Pro trở lên.
- `25ms-obf`, `hercules`, `moonsecv2` chạy qua `wasmoon` (Lua 5.4 compiled WASM) — **test kỹ sau
  khi deploy**, xem ghi chú rủi ro ở mục 10-12.
- `voltfuscator`, `xayz`, `wearedev` là **proxy sang dịch vụ bên thứ 3** — không do code này tự
  obfuscate, phụ thuộc server của họ còn sống/còn free hay không.
- `luna-moon` hiện **luôn trả lỗi 501** — chưa có cách chạy thật (xem mục 15).

---

## 1. GET /api/health

Không cần API key.

```bash
curl https://<domain>/api/health
```

```json
{ "ok": true, "service": "t0api", "engines": ["luaegis", "..."], "time": "2026-..." }
```

---

## 2. POST /api/luaegis/obfuscate

AST obfuscate: rename, encrypt strings/members, numbers, control-flow, minify, vmWrap.

**Body**

| Field | Type | Bắt buộc | Mặc định | Ghi chú |
|---|---|---|---|---|
| `source` | string | ✅ | — | Lua/Luau source |
| `preset` | string | ❌ | `medium` | `light` \| `medium` \| `heavy` \| `maximum` |
| `seed` | number | ❌ | `0` | seed để tái tạo kết quả giống hệt |
| `rename`, `encryptStrings`, `encryptMembers`, `numbers`, `controlFlow`, `minify`, `vmWrap` | boolean | ❌ | theo preset | ghi đè từng cờ riêng |

```bash
curl -X POST https://<domain>/api/luaegis/obfuscate \
  -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
  -d '{"source":"print(1)","preset":"heavy"}'
```

**Response**: `{ success, output, mode, seed, localsRenamed, ... }`

---

## 3. POST /api/luaegis/vm

Bytecode VM (stack/register), nhiều lớp + DTC anti-dump probe. **Nặng** — dễ chạm timeout nếu
`vmLayers` cao, xem mục "Giới hạn" ở trên.

**Body**

| Field | Type | Mặc định | Ghi chú |
|---|---|---|---|
| `source` | string | — | bắt buộc |
| `vmType` | string | `none` | `none` \| `stack` \| `register` |
| `vmLevel` | string | `normal` | `debug` \| `normal` \| `max` |
| `vmLayers` | number | 1 | số lớp VM lồng nhau |
| `padBytes` | number | — | padding byte cho VM |
| `hookIntegrity` | boolean | — | bật anti-tamper hook |
| `randomDtc` | boolean | — | random hoá DTC probe id |
| `rename`, `preserveGlobals`, `encodeStrings`, `scrambleControlFlow`, `oneLine`, `seed` | — | — | giống `/obfuscate` |

**Response**: `{ success, output, usedDtcId, seed, ... }`

---

## 4. POST /api/luaegis/validate

**Body**: `{ "source": "..." }` → kiểm tra cú pháp trước khi obfuscate.

---

## 5. POST /api/clyde/obfuscate

Base codebase mà luaegis phát triển lên. **Quan trọng:** mặc định gốc (không truyền `options`)
TẮT hết `encodeStrings`/`scramble` — giống hệt `server.ts` gốc, không bị đơn giản hoá. Muốn thấy
obfuscate thật phải tự bật.

**Body**

```json
{
  "code": "print(\"hi\")",
  "options": {
    "noRename": false,
    "noPreserve": false,
    "encodeStrings": true,
    "scramble": true,
    "oneLine": false,
    "vmType": "none",
    "vmLevel": "normal"
  }
}
```
`vmType`: `none` \| `stack` \| `register`. `vmLevel`: `debug` \| `normal` \| `max`.

**Response**: `{ success, output }`

---

## 6. POST /api/clyde/validate

**Body**: `{ "code": "..." }`

---

## 7. POST /api/veil/obfuscate

Engine của veil (self-leak bởi null, free to use — không kèm app/DB gốc, chỉ phần lõi
obfuscator). Shape giống hệt `/api/luaegis/obfuscate`.

**Body**: `source`, `preset` (`light`/`medium`/`heavy`/`maximum`), các cờ boolean giống luaegis.

**Response**: `{ success, output, mode, seed }`

---

## 8. POST /api/lumora/obfuscate

Numerical VM 3 lớp XOR, port 100% JS thuần — luôn chạy ổn định, không phụ thuộc Lua runtime.

**Body**: `{ "source": "..." }`
**Response**: `{ success, output, outputBytes, originalBytes, seed: {k1,k2,k3} }`

---

## 9. POST /api/wearedev/obfuscate

Proxy sang API công khai của `wearedevs.net`. Không cần key riêng.

**Body**: `{ "script": "..." }` (hoặc `source`, cả hai đều nhận)
**Response**: nguyên văn JSON upstream trả về (thường `{ success, obfuscated/script }`).

---

## 10. POST /api/25ms-obf/obfuscate

`[old]` — fork của Prometheus (không phải bản gốc của levno-710). Chạy qua `wasmoon`.

**Body**: `source`, `preset` (mặc định `Minify`): `ol` \| `Normal` \| `Vmify` \| `Minify` \| `me` \| `Weak` \| `doubled` \| `Medium` \| `Strong`.

**Response**: `{ success, engine: "25ms-obf [old]", output, preset }`

⚠️ Nếu gặp lỗi `glue.wasm` ENOENT → chưa redeploy sau khi thêm `includeFiles` trong
`vercel.json`. Nếu gặp lỗi `attempt to concatenate a nil value` tại dòng liên quan
`debug.getinfo`/`script_path` → đã vá trong `lib/engines/25msRunner.js`, đảm bảo bạn dùng đúng
bản mới nhất.

---

## 11. POST /api/hercules/obfuscate

Chạy qua `wasmoon`. **Body**: `source`, `preset` (mặc định `balanced`): `light` \| `balanced` \|
`heavy` \| `maximum`.

Preset `maximum` bật `virtual_machine`/`bytecode_encoding` — có thể dùng `string.dump`, cùng rủi
ro bytecode-version như moonsecv2 bên dưới. Nếu lỗi, thử preset nhẹ hơn trước khi kết luận cả
route bị hỏng.

**Response**: `{ success, output, preset }`

---

## 12. POST /api/moonsecv2/obfuscate

⚠️ **Rủi ro cao, thử nghiệm.** Dùng `string.dump()` lấy bytecode rồi tự parse — bytecode Lua gắn
chặt version sinh ra nó. `wasmoon` chạy Lua 5.4, engine này nhiều khả năng được viết cho bytecode
Lua 5.1. Nếu lỗi/ra output hỏng, hướng sửa đúng là host engine này trên 1 server Lua 5.1 thật rồi
đổi route này thành proxy (giống `/api/wearedev`), không phải vá `wasmoon`.

**Body**: `{ "source": "..." }`
**Response**: `{ success, experimental: true, output }`

---

## 13. POST /api/voltfuscator/obfuscate

Proxy sang **Voltfuscator** (`voltils.cc`, dịch vụ trả phí bên thứ 3, docs gốc tại
`docs/upstream/Voltfuscator_API_Docs.md`). **Cần API key Voltfuscator của chính bạn** (khác với
`API_KEY` của gateway này) — tạo trong dashboard voltils.cc.

**Body**

| Field | Type | Mặc định | Ghi chú |
|---|---|---|---|
| `code` | string | — | bắt buộc |
| `preset` | string | `normal` | `normal` \| `ultra` (⚠️ `max` không còn được chấp nhận ở upstream) |
| `runtime` | string | `luau` | `luau` \| `lua51` \| `roblox` \| `studio` \| `executor` |
| `voltKey` | string | — | API key Voltfuscator của bạn; nếu bỏ trống, server dùng env `VOLTFUSCATOR_API_KEY` |

```bash
curl -X POST https://<domain>/api/voltfuscator/obfuscate \
  -H "Content-Type: application/json" -H "X-API-Key: $KEY" \
  -d '{"code":"print(\"hi\")","preset":"normal","runtime":"roblox","voltKey":"YOUR_VOLT_KEY"}'
```

**Response**: nguyên văn JSON Voltfuscator trả (`{ success, obfuscated }`).

**Quota upstream (không liên quan quota gateway này)**:

| Plan | Builds/12h | Builds/ngày | Giới hạn size |
|---|---|---|---|
| Basic | 3 | 6 | 350 KB |
| Pro | 12 | 24 | 500 KB |
| Elite | 120 | 240 | 600 KB |

Build fail không tính vào quota. Reset 00:00 UTC. Timeout compiler mặc định phía họ: 15s.

---

## 14. POST /api/xayz/obfuscate

Proxy sang **Xayz** (docs gốc ghi "RayX obfuscator" / base URL `luaob.vercel.app`, xem
`docs/upstream/xayz_api_docs.md`). Không cần API key, giới hạn ~100 request/IP/giờ theo phía họ.

**Body**: `{ "code": "...", "targetMode": "roblox" }` (`targetMode`: `roblox` mặc định, hoặc
`standard`).

**Response**: `{ success, result }` (nguyên văn upstream).

Lưu ý: route này tự gửi kèm `User-Agent` bình thường (không chứa "bot"/"curl"/"postman") vì
chính docs của Xayz nói WAF của họ tự chặn các User-Agent đó — đây là hướng dẫn tích hợp chính
thức từ phía họ, không phải mình tự chế cách né.

---

## 15. POST /api/luna-moon/obfuscate (headless-browser automation — cực kỳ thử nghiệm)

Không reimplement logic obfuscate (site thật đã chuyển sang gọi backend Convex, không còn logic
client thuần để trích xuất). Thay vào đó: mở Chromium headless thật (`puppeteer-core` +
`@sparticuz/chromium`), điều khiển bản mirror tự host tại `/luna-moon-mirror/` giống thao tác tay
— gõ code, bấm "Obfuscate", đọc kết quả từ DOM.

**Body**: `{ "source": "..." }`
**Response thành công**: `{ success, experimental: true, engine: "luna-moon (headless-browser automation)", output }`
**Response lỗi**: `{ success: false, experimental: true, error, detail }`

⚠️ Chưa test thật end-to-end. Selector (ô nhập/nút/kết quả) có thể sai — xem README.md mục
"Luna Moon — cần bạn tự kiểm tra DOM thật" để tự chỉnh qua env vars
(`LUNA_MOON_INPUT_SELECTOR`, `LUNA_MOON_BUTTON_TEXT`, `LUNA_MOON_OUTPUT_SELECTOR`,
`LUNA_MOON_MIRROR_URL`) mà không cần sửa code. Gần như chắc chắn cần Vercel Pro (Hobby 10s
timeout không đủ cho cold-start Chromium).

---

## Bảng tổng hợp nhanh

| # | Route | Field body chính | Cần key riêng? | Trạng thái |
|---|---|---|---|---|
| 2 | `/api/luaegis/obfuscate` | `source` | không | ✅ đã test chạy thật |
| 3 | `/api/luaegis/vm` | `source` | không | ✅ đã test chạy thật |
| 4 | `/api/luaegis/validate` | `source` | không | ✅ đã test chạy thật |
| 5 | `/api/clyde/obfuscate` | `code` | không | ✅ đã test chạy thật |
| 6 | `/api/clyde/validate` | `code` | không | ✅ đã test chạy thật |
| 7 | `/api/veil/obfuscate` | `source` | không | ✅ đã test chạy thật |
| 8 | `/api/lumora/obfuscate` | `source` | không | ✅ JS thuần, ổn định |
| 9 | `/api/wearedev/obfuscate` | `script` | không | ✅ proxy, giữ nguyên gốc |
| 10 | `/api/25ms-obf/obfuscate` | `source` | không | ⚠️ wasmoon, đã vá 2 bug, chưa test thật |
| 11 | `/api/hercules/obfuscate` | `source` | không | ⚠️ wasmoon, chưa test thật |
| 12 | `/api/moonsecv2/obfuscate` | `source` | không | ⚠️⚠️ rủi ro bytecode cao |
| 13 | `/api/voltfuscator/obfuscate` | `code` | ✅ (`voltKey` hoặc env) | ✅ proxy, cần tài khoản Voltfuscator |
| 14 | `/api/xayz/obfuscate` | `code` | không | ✅ proxy |
| 15 | `/api/luna-moon/obfuscate` | `source` | không | ⚠️⚠️ headless-browser, cực kỳ thử nghiệm, cần Pro plan |
