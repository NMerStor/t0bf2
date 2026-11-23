# t0api — Unified Lua/Luau Obfuscation Gateway

Một site Vercel duy nhất, **18 engine** obfuscate Lua/Luau khác nhau (Lua/wasmoon, JS/TS thuần,
1 binary C++ thật, 1 Python riêng), mỗi engine 1 (hoặc vài) route riêng dưới
`/api/<engine>/<action>` — không gộp logic các engine vào nhau — kèm web tester (`/`) và trang
docs (`/docs`). Toàn bộ API cũng được gộp vào 1 file `API_REFERENCE.md` để đưa thẳng cho bot/AI
đọc, không cần crawl web.

## Cài đặt & deploy

```bash
npm install
cp .env.example .env.local   # chỉ để tham khảo, KHÔNG commit key thật vào git
```

1. Push repo lên GitHub, import vào Vercel.
2. **Project Settings → Environment Variables**, thêm `API_KEY` = 1 chuỗi ngẫu nhiên dài
   (gợi ý: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`).
3. (Tuỳ chọn) `VOLTFUSCATOR_API_KEY`, `NOVA_PREMIUM_KEY` — xem `.env.example`.
4. **Project Settings → Functions → bật Fluid Compute** — cần cho `maxDuration: 300` trong
   `vercel.json` có tác dụng thật; không bật thì Hobby vẫn bị giới hạn cứng 10s.
5. Deploy. Vercel tự chạy `npm run build` (compile `lib/engines/**/*.ts` → `lib-dist/`) trước khi
   build function.
6. Test local trước khi deploy thật: `vercel dev` (cần Vercel CLI + đã `vercel link`).

Bot/web gọi API bằng header `X-API-Key: <key>` hoặc `Authorization: Bearer <key>`. Chi tiết từng
route: `API_REFERENCE.md` hoặc `/docs` sau khi deploy.

## Kiến trúc: vì sao chỉ có 3 serverless function (cho 21 route)

Vercel Hobby giới hạn **12 function/deployment**. Ban đầu mỗi route là 1 file riêng dưới `api/` —
càng thêm engine càng sớm vượt giới hạn, gây lỗi build `Exceeded 12 functions`.

Giải pháp: gộp **toàn bộ route Node (JS/TS/wasmoon/C++ binary)** — hiện 17 route — vào đúng 1 file
`api/[engine]/[action].js` dùng dynamic routing của Vercel (file-based, giống Next.js) — Vercel
tính theo **số file vật lý** dưới `api/`, không tính theo URL, nên 1 file này dù khớp 17 URL khác
nhau vẫn chỉ là **1 function**. Cộng `api/health.js` + `api/ig67/obfuscate.py` (route Python
riêng, vì Python là runtime khác hẳn, không gộp chung được với dispatcher Node) → tổng **3
function**, còn rất nhiều dư địa cho tương lai (giới hạn 12).

- Logic thật của từng route nằm ở `lib/routes/<tên>.js` (default export giống hệt 1 file
  `api/*.js` trước đây) — `api/[engine]/[action].js` chỉ là dispatcher tra bảng `(engine, action)
  → lib/routes/<tên>.js` rồi gọi.
- Dispatcher dùng **dynamic `import()`** (lazy-load) thay vì static import ở đầu file: (1) nhiều
  engine kéo theo dependency nặng (`wasmoon`) — static import sẽ load hết mọi thứ ở MỌI cold
  start dù request chỉ cần 1 engine nhẹ; (2) cô lập lỗi — nếu 1 engine có dependency hỏng, chỉ
  route đó lỗi, không kéo sập toàn bộ function.
- URL public **không đổi gì** — `/api/luaegis/obfuscate` vẫn hoạt động y hệt trước, chỉ là ở phía
  sau nó giờ là dynamic route thay vì file riêng.

Muốn thêm engine mới: viết 1 file `lib/routes/<ten>.js` (default export `(req,res)=>{...}`), copy
source gốc vào `lib/engines/<ten>/`, rồi thêm 1 dòng vào `ROUTE_MODULES` trong
`api/[engine]/[action].js`. Không tạo file mới trong `api/` — làm vậy sẽ lại tốn 1 function.

## 18 engine — trạng thái

| Engine | Route | Nguồn gốc | Trạng thái |
|---|---|---|---|
| `luaegis` | `/api/luaegis/{obfuscate,vm,validate}` | Dự án TS/Express của bạn | ✅ test chạy thật |
| `clyde` | `/api/clyde/{obfuscate,validate}` | Lua-Obfuscator-Clyde-Protection (MIT) | ✅ test chạy thật |
| `veil` | `/api/veil/obfuscate` | veil-lua-obfuscator (self-leak bởi null) | ✅ test chạy thật |
| `lumora` | `/api/lumora/obfuscate` | Port JS thuần, không cần Lua runtime | ✅ test chạy thật |
| `wearedev` | `/api/wearedev/obfuscate` | Proxy sang wearedevs.net | ✅ giữ nguyên gốc |
| `25ms-obf [old]` | `/api/25ms-obf/obfuscate` | Fork Prometheus, chạy qua `wasmoon` | ⚠️ chưa test thật (sandbox không có mạng/Lua) |
| `hercules` | `/api/hercules/obfuscate` | CLI Lua, chạy qua `wasmoon` | ⚠️ chưa test thật |
| `moonsecv2` | `/api/moonsecv2/obfuscate` | Bản mô phỏng by larpcorrupt, dùng bytecode | ⚠️⚠️ rủi ro cao (xem bên dưới) |
| `azurevm` | `/api/azurevm/obfuscate` | Proxy tới service Lua 5.1 riêng | ⚠️ cần deploy service và cấu hình URL/token |
| `voltfuscator` | `/api/voltfuscator/obfuscate` | Proxy sang voltils.cc (trả phí, cần key riêng) | ✅ proxy |
| `xayz` | `/api/xayz/obfuscate` | Proxy sang luaob.vercel.app | ✅ proxy |
| `oxyfuscator` | `/api/oxyfuscator/obfuscate` | TS, polymorphic + VM | ✅ test chạy thật |
| `moonsecv3 [reconstruction]` | `/api/moonsecv3/obfuscate` | Bản tái dựng, MIT, tự ghi rõ không phải gốc | ✅ test chạy thật |
| `eatfuscator [AGPL-3.0]` | `/api/eatfuscator/obfuscate` | Register-bytecode VM, AGPL-3.0 | ✅ test chạy thật |
| `nova` | `/api/nova/obfuscate` | Level weak→premium, đã bỏ key leak của bản gốc | ✅ test chạy thật |
| `exfuscator` | `/api/exfuscator/obfuscate` | **Binary C++ thật**, tự compile (không phải wasmoon/Node) | ✅ test chạy thật |
| `azurevm` | `/api/azurevm/obfuscate` | Fork Prometheus, "Lua 5.1 VM-based", dùng `string.dump` | ⚠️⚠️ rủi ro cao (bytecode, như moonsecv2) |
| `catph` | `/api/catph/obfuscate` | 3/4 preset chạy qua wasmoon; preset `luaubc` cần binary ngoài | ⚠️ chưa test thật (3 preset chính), `luaubc` bị chặn luôn |
| `claudium` | `/api/claudium/obfuscate` | 100% Lua thuần (Python chỉ là vỏ demo server cũ) | ⚠️ chưa test thật |
| `ig67` | `/api/ig67/obfuscate` | Python thuần, Vercel Python function riêng | ✅ **test chạy thật bằng HTTP server thật** |

`moonsec v3` (bản C#/.NET/IronBrew2 thật) và `luna-moon` (site Luna Moon) đã bị **loại bỏ hoàn
toàn** — xem "Engine đã bỏ" bên dưới.

### `moonsecv3` ở đây KHÔNG phải MoonSec V3 thật

Source nhận được tự ghi chú đây là bản **reconstruction** (tái dựng lại định dạng
bytecode/VM quan sát được từ MoonSec V3 thật), không phải source gốc rò rỉ. Giữ nguyên ghi chú đó
trong response (`engine: "moonsecv3 (reconstruction, not original)"`) để không gây hiểu nhầm.

### `eatfuscator` — lưu ý giấy phép AGPL-3.0

AGPL yêu cầu: nếu chạy bản đã sửa của phần mềm AGPL như 1 dịch vụ mạng, phải cho người dùng dịch
vụ đó quyền truy cập source tương ứng. Source gốc (không chỉnh sửa) được giữ nguyên tại
`lib/engines/eatfuscator/` + `docs/upstream/eatfuscator-LICENSE.txt` trong chính repo này — đảm
bảo repo này public hoặc có cách nào đó cho người dùng cuối lấy được source nếu bạn host dịch vụ
này cho người khác dùng.

### `nova` — đã bỏ key leak của bản gốc

App gốc gắn cứng 1 `PREMIUM_KEY` bị leak để chặn level "premium". Route này **không dùng key đó**
— "premium" chạy như mọi level khác, chỉ bị chặn thêm nếu bạn tự set `NOVA_PREMIUM_KEY` (xem
`.env.example`).

## Engine đã bỏ

- **`moonsec v3` (C#/.NET/IronBrew2 thật)** — bỏ ngay từ đầu dự án vì Vercel serverless (Node)
  không chạy được .NET.
- **Luna Moon** — đã thử 2 hướng: (1) reimplement từ JS minified trích xuất — không có hàm
  orchestrator thật, không ghép được; (2) headless-browser automation (Puppeteer) điều khiển bản
  mirror tự host — về mặt kỹ thuật khả thi nhưng **đã bị xoá khỏi dự án theo yêu cầu** vì không
  dùng được ổn định. Toàn bộ code liên quan (`lib/engines/luna-moon/`, `lib/engines/lunaMoonRunner.js`,
  `public/luna-moon-mirror/`, route, UI card) đã được gỡ bỏ hoàn toàn; `puppeteer-core` và
  `@sparticuz/chromium` cũng đã bỏ khỏi `package.json`.

## 5 engine từng bị "deferred" — giờ đã làm hết, cách giải quyết từng cái

- **Claudium** — tưởng là "Python + subprocess lua5.4" nhưng kiểm tra lại thì Python
  (`server.py`) chỉ là **vỏ demo server** (Railway/Docker) gọi `lua5.4 cli.lua` — logic obfuscate
  thật 100% là Lua thuần (`src/**/*.lua`). Bỏ hẳn Python, wire thẳng qua `wasmoon` như các engine
  Lua khác. Không cần host riêng gì cả.
- **ExFuscator** — đúng là binary C++ thật, không có cách nào chạy trong Node serverless ngoài
  compile sẵn 1 binary và bundle theo. Source gốc có **bug case-sensitivity thật**: mọi file
  `#include "astra/..."` nhưng thư mục trên đĩa tên `ExFuscator` (khác hẳn tên "astra"), và
  `CMakeLists.txt` cũng tự mâu thuẫn chữ hoa/thường với cây thư mục thật. Sandbox build không có
  `cmake` nên bỏ qua CMake luôn, copy source sang 1 thư mục tên `astra` (khớp include path) rồi
  compile thẳng bằng `g++ -std=c++17 -O2 -static` — ra 1 **binary tĩnh hoàn toàn** (không phụ
  thuộc thư viện ngoài, `ldd` xác nhận "not a dynamic executable"), đã test chạy thật ra output
  đúng trước khi đóng gói vào `lib/engines/exfuscator/bin/exfuscator`. Source đã fix giữ tại
  `lib/engines/exfuscator/src-fixed/` để tham khảo/build lại sau này.
- **AzureVM** — xác nhận đúng như lo ngại: dùng `string.dump()` thật để lấy bytecode (tự nhận là
  "Lua 5.1 VM-based"). Vẫn làm theo đúng yêu cầu (wasmoon như mấy cái kia), nhưng giữ nguyên mức
  cảnh báo rủi ro cao nhất (ngang `moonsecv2`) — rất có thể cần host Lua 5.1 riêng nếu lỗi.
- **Catph** — `os.execute` chỉ xuất hiện ở 2 chỗ: (1) lệnh `mkdir` trong `cli.lua` (không dùng
  tới vì route này không đụng filesystem của CLI, chỉ gọi thẳng Pipeline API); (2) bên trong 1
  pipeline step tên "LuauBytecode" (chỉ preset `luaubc` dùng), gọi 1 binary `luau-compile`
  **chính thức của Roblox** để nén bytecode Luau thật — không phải lệnh tuỳ ý từ input người
  dùng, và không bundle binary đó nên preset `luaubc` bị **chặn thẳng ở route** (lỗi 400 rõ ràng)
  thay vì để lỗi khó hiểu từ sâu trong pipeline. 3 preset còn lại (`customvm`/`ironbrew2`/`catph`)
  không đụng tới `os.execute` chút nào, chạy bình thường qua wasmoon.
- **ig67** — Python thuần, có sẵn hàm `build(payload, seed, min_kb, name, ver)` không cần file
  I/O. Thêm 1 **Vercel Python Serverless Function** riêng (`api/ig67/obfuscate.py`, function thứ
  3 của dự án) — không cần proxy/host ngoài gì cả. Python3 có sẵn trong sandbox viết code này nên
  **test được thật bằng 1 HTTP server thật** (không chỉ import suông), xác nhận hoạt động đúng.

## `25ms-obf` / `hercules` / `moonsecv2` — vẫn chạy qua `wasmoon`, vẫn chưa test thật

Sandbox dùng để viết code này không có mạng (không `npm install` được `wasmoon`) và không có
interpreter Lua để chạy thử trực tiếp. Cách bundle nhiều file Lua (`package.preload`) là kỹ thuật
chuẩn và glue code gọi đúng API thật của từng project, nhưng **chưa chạy thử được end-to-end**.
Đã vá 2 bug thực tế gặp phải khi deploy thật (ENOENT `glue.wasm` → thêm `includeFiles` trong
`vercel.json`; `attempt to concatenate a nil value` ở `25ms-obf` → sửa chunkname truyền vào
`load()`) — nhưng vẫn nên tự test kỹ sau khi deploy.

`moonsecv2` dùng `string.dump()` (bytecode) — rủi ro cao nhất vì bytecode Lua gắn chặt version
sinh ra nó, `wasmoon` chạy Lua 5.4 còn engine này nhiều khả năng viết cho Lua 5.1. Nếu lỗi/ra
output hỏng, hướng sửa đúng là host engine này trên 1 server Lua 5.1 thật rồi proxy sang (giống
`/api/wearedev`), không phải vá `wasmoon`.

`azurevm` cũng đọc bytecode Lua 5.1 nên chạy qua service container riêng, không qua wasmoon.
Xem [`services/azurevm-lua51/README.md`](./services/azurevm-lua51/README.md) để build/deploy;
gateway cần `AZUREVM_LUA51_SERVICE_URL` và `AZUREVM_LUA51_SERVICE_TOKEN`.

## Giao diện

Giữ nguyên cấu trúc web (tester `/` + docs `/docs`, vanilla HTML/CSS/JS, không phải React) —
chỉ đổi **màu sắc/typography** sang tông tối gần đen (`#050505`), chữ trắng, viền trắng mờ
(translucent), accent tím-xanh `#5865F2`, font Manrope (chữ) + DM Mono (code/số liệu) — lấy cảm
hứng từ bảng màu/typography thấy được trong CSS đã build sẵn của leakd-vercel-app (không copy
code/markup, chỉ tham khảo token màu+font).

## Cài đặt / fix trước đó (tóm tắt)

- Bug `ENOENT glue.wasm` + bug `attempt to concatenate a nil value` ở `25ms-obf` — đã vá, xem
  `lib/engines/25msRunner.js`.
- Bug Clyde mặc định không đổi output — không phải lỗi (đúng hành vi gốc), đã thêm checkbox bật
  sẵn `encodeStrings`/`scramble` trên web tester để thấy obfuscate thật ngay; gọi API trực tiếp
  vẫn giữ default gốc (tất cả tắt) nếu không truyền `options`.
- Bug build TypeScript `TS2305 has no exported member` trên Vercel dù code đúng cục bộ — do file
  bị hỏng khi push lên GitHub (không phải lỗi code), đã gửi lại 2 file gốc để thay trực tiếp.

## Cấu trúc thư mục

```
api/
  _lib/auth.js, cors.js          # API key + CORS dùng chung
  health.js                      # GET, không cần key (function #1)
  [engine]/[action].js           # dispatcher cho 17 route Node (function #2)
  ig67/obfuscate.py               # Vercel Python function riêng (function #3)
lib/
  routes/<ten>.js                # logic thật từng route (default export (req,res)=>{})
  engines/
    luaegis/ clyde/ veil/        # source TS gốc (compile ra lib-dist/ lúc build)
    oxyfuscator/                 # đã compile sẵn (ESM JS), copy nguyên dist/
    moonsecv3/ eatfuscator/      # CommonJS thuần, có package.json {"type":"commonjs"} riêng
    nova/                        # TS, compile cùng luaegis/clyde
    exfuscator/
      bin/exfuscator              # binary C++ TĨNH đã compile sẵn (g++ -static), chạy qua child_process
      src-fixed/                  # source đã fix include-path case-sensitivity, để build lại sau này
    ig67/src/                    # Python thuần, import trực tiếp từ api/ig67/obfuscate.py
    lumora.js  25msRunner.js  herculesRunner.js  moonsecv2Runner.js
    azureVmRunner.js  catphRunner.js  claudiumRunner.js
  lua-sources/
    25ms-obf/ hercules/ moonsecv2/ azurevm/ catph/ claudium/   # source .lua gốc, không sửa logic
  lua-bundle.js                  # bundler chung: .lua -> package.preload cho wasmoon
docs/upstream/                   # docs/license gốc của các dịch vụ bên thứ 3
public/
  index.html  docs.html  style.css  app.js   # web tester + docs
API_REFERENCE.md                 # toàn bộ API trong 1 file, cho bot/AI đọc trực tiếp
```

## Việc nên làm tiếp theo

1. Sau deploy: test từng route ở `/` (web tester) với 1 đoạn code ngắn — ưu tiên
   `azurevm`/`catph`/`claudium` (wasmoon, chưa test thật) và `exfuscator` (binary, verify đúng
   kiến trúc Vercel chạy là x86_64 Linux, cùng kiến trúc lúc compile).
2. Bật Fluid Compute nếu muốn `maxDuration: 300` có tác dụng thật.
3. Nếu `25ms-obf`/`hercules`/`moonsecv2`/`azurevm` lỗi do bytecode/wasmoon — cân nhắc host riêng 1
   service Lua nhỏ (VPS/Render) rồi đổi route tương ứng thành proxy.
4. Cân nhắc thêm rate-limit theo IP/key nếu site bị gọi quá nhiều (hiện chưa có).
