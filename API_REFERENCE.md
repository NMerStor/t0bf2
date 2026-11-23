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
- [15. POST /api/oxyfuscator/obfuscate](#15-post-apioxyfuscatorobfuscate)
- [16. POST /api/moonsecv3/obfuscate](#16-post-apimoonsecv3obfuscate)
- [17. POST /api/eatfuscator/obfuscate](#17-post-apieatfuscatorobfuscate)
- [18. POST /api/nova/obfuscate](#18-post-apinovaobfuscate)
- [19. POST /api/exfuscator/obfuscate](#19-post-apiexfuscatorobfuscate)
- [20. POST /api/azurevm/obfuscate](#20-post-apiazurevmobfuscate)
- [21. POST /api/catph/obfuscate](#21-post-apicatphobfuscate)
- [22. POST /api/claudium/obfuscate](#22-post-apiclaudiumobfuscate)
- [23. POST /api/ig67/obfuscate (Python function riêng)](#23-post-apiig67obfuscate-python-function-riêng)
- [Engine đã bỏ hoàn toàn](#engine-đã-bỏ-hoàn-toàn)
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

- 17 route Node (Lua qua wasmoon, JS/TS thuần, 1 binary C++) gộp vào đúng **1 serverless
  function** (`api/[engine]/[action].js`, dynamic route). `ig67` là Python nên có **1 function
  riêng** (`api/ig67/obfuscate.py`, runtime khác hẳn, không gộp chung được). Cộng `api/health.js`
  → tổng **3 function** cho cả deployment (Hobby giới hạn tối đa 12) — URL public không đổi gì,
  chỉ là kiến trúc phía sau (xem README.md mục "Kiến trúc").
- `exfuscator` là **binary C++ tĩnh đã compile sẵn**, chạy qua `child_process`, không phải
  wasmoon/Node thuần — khác hẳn cơ chế mọi engine Lua khác trong gateway này.
- `vercel.json` set `maxDuration: 300` cho function đó — **chỉ có tác dụng thật nếu bạn bật Fluid
  Compute** trong Project Settings. Không bật thì Hobby vẫn giới hạn cứng 10s bất kể config.
- `25ms-obf`, `hercules`, `moonsecv2` chạy qua `wasmoon` (Lua 5.4 compiled WASM) — **test kỹ sau
  khi deploy**, xem ghi chú rủi ro ở mục 10-12.
- `voltfuscator`, `xayz`, `wearedev` là **proxy sang dịch vụ bên thứ 3** — không do code này tự
  obfuscate, phụ thuộc server của họ còn sống/còn free hay không.
- `moonsecv3` là **bản tái dựng (reconstruction)**, không phải MoonSec V3 gốc. `eatfuscator` có
  giấy phép **AGPL-3.0** (xem mục 17). `nova` đã bỏ key "premium" leak của bản gốc (xem mục 18).
- Luna Moon và MoonSec V3 (bản C#/.NET thật) đã **bị loại bỏ hoàn toàn** khỏi dự án — không còn
  route nào cho 2 cái này.

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

## 15. POST /api/oxyfuscator/obfuscate

TypeScript, polymorphic builds + 2 lớp VM độc lập ở preset `maximum`. Đã compile sẵn (ESM JS),
không cần bước build riêng.

**Body**: `source`, `preset` (`minimum` \| `balanced` \| `maximum` \| `swear`, mặc định `balanced`), `seed` (number, optional — tự điền `Date.now()` nếu bỏ trống, giống CLI gốc)
**Response**: `{ success, engine: "oxyfuscator", output, preset }`

---

## 16. POST /api/moonsecv3/obfuscate

**Lưu ý: đây là bản tái dựng (reconstruction), không phải MoonSec V3 gốc** — source tự ghi chú
rõ điều này. CommonJS thuần, không phụ thuộc native nào.

**Body**: `source`, `seed` (number, optional), `watermark` (boolean, mặc định `true`)
**Response**: `{ success, engine: "moonsecv3 (reconstruction, not original)", output, meta: {seed, profile, bytecodeBytes} }`

---

## 17. POST /api/eatfuscator/obfuscate

Register bytecode riêng + VM interpreter + envelope anti-tamper. **Giấy phép AGPL-3.0** — source
gốc không chỉnh sửa được giữ tại `lib/engines/eatfuscator/` và license đầy đủ tại
`docs/upstream/eatfuscator-LICENSE.txt` (yêu cầu network-use source-availability của AGPL).

**Body**: `source`, `seed` (number, optional), `minify` (string, optional)
**Response**: `{ success, engine: "eatfuscator", license: "...", output }`

---

## 18. POST /api/nova/obfuscate

Level `weak` → `premium`. **App gốc gắn cứng 1 key bị leak để chặn level "premium" — route này
KHÔNG dùng key đó.** Mặc định "premium" chạy như mọi level khác; nếu bạn set env
`NOVA_PREMIUM_KEY`, phải kèm `novaKey` đúng giá trị đó trong body mới dùng được level "premium".

**Body**: `source`, `level` (`weak`\|`medium`\|`harder`\|`strong`\|`premium`, mặc định `medium`), `novaKey` (chỉ cần nếu server đã set `NOVA_PREMIUM_KEY`)
**Response**: `{ success, engine: "nova", output, level }`

---

## 19. POST /api/exfuscator/obfuscate

Binary C++ thật, tự compile tĩnh (`g++ -static`) từ source đã vá lỗi case-sensitivity
(`#include "astra/..."` nhưng thư mục thật là `ExFuscator`). Chạy qua `child_process.execFile`,
ghi input ra file tạm trong `/tmp`, đọc output từ file tạm, dọn dẹp sau khi xong.

**Body**: `source`, `preset` (`light`\|`medium`\|`maximum`, mặc định `medium`), `seed` (số nguyên, mặc định theo giờ hệ thống), và các cờ boolean: `noStrings`, `noNumbers`, `noRename`, `noDeadcode`, `noFlatten`, `noProxies`, `noOpaque`, `noDfm`, `renameGlobals`, `globalsReal`
**Response**: `{ success, engine: "exfuscator", output, preset, seed }`

⚠️ Binary biên dịch cho Linux x86_64 tĩnh (không phụ thuộc thư viện ngoài) — giả định Vercel chạy
function trên kiến trúc x86_64 (mặc định hiện tại). Nếu Vercel đổi sang arm64, binary này sẽ
không chạy được và cần compile lại.

---

## 20. POST /api/azurevm/obfuscate

⚠️⚠️ **Rủi ro cao — cùng lớp rủi ro như moonsecv2.** Fork Prometheus, tự mô tả là "Lua 5.1
VM-based obfuscator", dùng `string.dump()` thật để lấy bytecode rồi tự parse. wasmoon chạy Lua
5.4 — có thể không tương thích định dạng bytecode Lua 5.1.

**Body**: `source`, `preset` (mặc định `Luraph`): `Minify`\|`Weak`\|`Vmify`\|`Medium`\|`Strong`\|`Luraph`\|`Luraph14`\|`Luraph15`\|`AzureGod`\|`AzureGod15`\|`AzureGodUltra`\|`Fast`\|`Balanced`\|`Hardened`\|`Research`, `seed` (number, optional)
**Response**: `{ success, engine: "azurevm", output, preset }`

---

## 21. POST /api/catph/obfuscate

**Body**: `source`, `preset` (mặc định `customvm`): `customvm`\|`ironbrew2`\|`catph`\|`luaubc`

Preset `luaubc` bị **chặn ở route với lỗi 400** — step "LuauBytecode" của nó cần 1 binary
`luau-compile` chính thức của Roblox (không bundle trong gateway này). 3 preset còn lại không
đụng tới `os.execute` nội bộ, chạy bình thường qua wasmoon.

**Response thành công**: `{ success, engine: "catph", output, preset }`
**Response khi chọn luaubc**: `{ success: false, error: "'luaubc' preset needs a real external luau-compile binary..." }`

---

## 22. POST /api/claudium/obfuscate

100% Lua thuần — bản demo server gốc (archive gửi kèm) dùng Python chỉ để gọi `lua5.4` làm CLI
wrapper, không phải phụ thuộc Python thật của logic obfuscate, nên chạy qua wasmoon như mọi engine
Lua khác, không cần Python/host riêng.

**Body**: `source`, `preset` (mặc định `lua51`): `minimum`\|`maximum`\|`lua51`\|`lua53`\|`luajit`\|`roblox`\|`luau`\|`executor`
**Response**: `{ success, engine: "claudium", output, preset }`

---

## 23. POST /api/ig67/obfuscate (Python function riêng)

Python thuần (chỉ thư viện chuẩn, không pip package nào) — chạy trên **Vercel Python Serverless
Function riêng** (`api/ig67/obfuscate.py`), không phải dispatcher Node. Đã verify thật bằng 1 HTTP
server thật (không chỉ import suông) trong lúc viết code — engine đáng tin cậy nhất trong đợt bổ
sung này.

**Body**: `source`, `seed` (number, mặc định `0x7C01` = 31777), `minKb` (số KB tối thiểu của output, mặc định 1), `name`, `version` (chuỗi ghi trong header comment của output)
**Response**: `{ success, engine: "ig67", output, seed }`

---

## Engine đã bỏ hoàn toàn

**Đã bỏ hoàn toàn khỏi dự án:**
- `moonsec v3` thật (C#/.NET/IronBrew2) — Vercel Node không chạy được .NET.
- Luna Moon — đã thử 2 hướng (reimplement từ JS minified, headless-browser automation), cả 2 đều
  không ổn định đủ để dùng thật; toàn bộ code liên quan đã bị xoá theo yêu cầu.

Không còn engine nào "deferred" — Claudium, ExFuscator, AzureVM, Catph, ig67 đều đã được tích hợp
thật (xem mục 19-23 ở trên và README.md để biết cách từng cái được giải quyết).

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
| 15 | `/api/oxyfuscator/obfuscate` | `source` | không | ✅ đã test chạy thật |
| 16 | `/api/moonsecv3/obfuscate` | `source` | không | ✅ đã test chạy thật (reconstruction) |
| 17 | `/api/eatfuscator/obfuscate` | `source` | không | ✅ đã test chạy thật (AGPL-3.0) |
| 18 | `/api/nova/obfuscate` | `source` | không | ✅ đã test chạy thật |
| 19 | `/api/exfuscator/obfuscate` | `source` | không | ✅ đã test chạy thật (binary C++ tĩnh) |
| 20 | `/api/azurevm/obfuscate` | `source` | không | ⚠️⚠️ rủi ro bytecode cao, chưa test thật |
| 21 | `/api/catph/obfuscate` | `source` | không | ⚠️ wasmoon, chưa test thật (trừ preset luaubc bị chặn) |
| 22 | `/api/claudium/obfuscate` | `source` | không | ⚠️ wasmoon, chưa test thật |
| 23 | `/api/ig67/obfuscate` | `source` | không | ✅ **test chạy thật bằng HTTP server thật** |
