# t0api — Unified Lua/Luau Obfuscation Gateway

## Luna Moon đổi hướng: headless-browser automation

Bạn gửi thêm bản mirror đầy đủ site (`public/luna-moon-mirror/`, qua Zipasite). Kiểm tra bundle
JS thật của bản mirror này thì phát hiện: **site hiện tại không còn obfuscate ở client nữa** —
nó gọi 1 backend thật (Convex, `compassionate-ant-590.convex.cloud`) để xử lý. Nên route
`/api/luna-moon/obfuscate` giờ **không reimplement logic**, mà dùng `puppeteer-core` +
`@sparticuz/chromium` để mở 1 trình duyệt headless thật, điều khiển trang mirror tự host
(`/luna-moon-mirror/`) y như người dùng thật: gõ code vào ô nhập → bấm nút Obfuscate → đọc kết
quả từ DOM. Chi tiết đầy đủ: `lib/engines/luna-moon/NOTES.md`.

**Cực kỳ thử nghiệm — cần bạn tự kiểm tra DOM thật:**

Sandbox viết code này không có mạng/trình duyệt để render trang thật, nên các selector trong
`lib/engines/lunaMoonRunner.js` (ô nhập code, nút "Obfuscate", cách đọc kết quả) là **suy luận**
từ vài chuỗi text tìm thấy trong file JS minified (`data-placeholder-text`, `"copy"`,
`"download"`), chưa chắc đúng 100%. Nếu gọi API mà lỗi:

1. Deploy xong, mở `https://<domain>/luna-moon-mirror/` thật trên trình duyệt của bạn.
2. Mở DevTools → thử gõ code, bấm Obfuscate, xem kết quả hiện ở đâu.
3. Bấm chuột phải → Inspect vào đúng ô nhập code / nút Obfuscate / vùng kết quả → copy CSS
   selector thật.
4. Set vào Vercel env vars: `LUNA_MOON_INPUT_SELECTOR`, `LUNA_MOON_BUTTON_TEXT`,
   `LUNA_MOON_OUTPUT_SELECTOR` (không cần sửa code, đọc từ env).

Plan Vercel: route này cần khởi động Chromium thật (chậm hơn hẳn các route khác) — đã set
`maxDuration: 60` + `memory: 1769` trong `vercel.json`, gần như chắc chắn cần **Vercel Pro trở
lên** (Hobby giới hạn cứng 10s, không đủ cho cold-start Chromium + mở trang + chờ kết quả).

Nếu deploy báo lỗi function quá lớn (giới hạn dung lượng gói): đổi `@sparticuz/chromium` thành
`@sparticuz/chromium-min` trong `package.json` (tải binary Chromium từ xa lúc cold-start thay vì
đóng gói sẵn, gói nhỏ hơn nhiều) — xem docs của package đó để chỉnh `executablePath`.

## Thêm 3 engine mới + API_REFERENCE.md

- **`voltfuscator`** (`/api/voltfuscator/obfuscate`) — proxy sang dịch vụ trả phí `voltils.cc`.
  Cần API key Voltfuscator **của chính bạn** (khác `API_KEY` của gateway này): truyền qua
  `voltKey` mỗi request hoặc set env `VOLTFUSCATOR_API_KEY`. Quota tính theo plan Voltfuscator
  (Basic/Pro/Elite), không liên quan quota site này. Docs gốc lưu tại
  `docs/upstream/Voltfuscator_API_Docs.md`.
- **`xayz`** (`/api/xayz/obfuscate`) — proxy sang `luaob.vercel.app`, không cần key, ~100
  req/IP/giờ theo họ. Có gửi kèm `User-Agent` bình thường vì chính docs của họ nói WAF tự chặn
  User-Agent chứa "bot"/"curl"/"postman" — làm đúng theo hướng dẫn tích hợp chính thức, không tự
  chế thêm gì. Docs gốc: `docs/upstream/xayz_api_docs.md`.
- **`luna-moon`** (`/api/luna-moon/obfuscate`) — ❌ **chưa chạy được, luôn trả 501**. Code trích
  xuất (`luna_moon_obf_package`) là JS minified lấy từ bundle production của
  `obfuuscator.vercel.app`, chỉ có các mảnh nội bộ (tokenizer/renamer/string encryptor/...) chứ
  không có hàm orchestrator thật — đã quét hết ~40 hàm top-level, không hàm nào khớp shape
  options mà chính README gốc của gói mô tả. Xem lý do đầy đủ + hướng làm tiếp ở
  `lib/engines/luna-moon/NOTES.md`.

**Mới: `API_REFERENCE.md`** — 1 file markdown duy nhất chứa toàn bộ API (15 endpoint), auth,
body/response, ví dụ curl, bảng tổng hợp trạng thái. Đưa thẳng file này cho bot/AI/dev đọc, không
cần crawl `/docs` trên web nữa.

## Bản vá trước đó

3. **`25ms-obf` lỗi `prometheus:13: attempt to concatenate a nil value`**: dòng 13 của
   `prometheus.lua` gốc tự dò đường dẫn file của chính nó bằng
   `debug.getinfo(2,"S").source` để tự thêm vào `package.path` (phục vụ `require()` qua
   filesystem thật). Khi nạp file này bằng `load(sourceString, "@prometheus")` (không qua
   filesystem), `source` không có dấu `/` nên hàm dò đường trả về `nil`, rồi
   `nil .. "?.lua;" .. package.path` nổ lỗi concatenate — xảy ra **trước khi** chạm tới API thật
   của Prometheus. Vì mọi module con đã được nạp sẵn qua `package.preload` (không cần
   `package.path` hoạt động), fix chỉ cần đổi "tên file ảo" truyền cho `load()` thành một chuỗi
   có dấu `/` (`@/virtual/prometheus.lua`) để hàm dò đường không trả `nil` nữa — không đụng vào
   logic gốc của Prometheus. Đã sửa trong `lib/engines/25msRunner.js`.

## Bản vá trước đó (đã sửa 2 bug báo cáo từ bản deploy thật)

1. **`ENOENT ... node_modules/wasmoon/dist/glue.wasm`** trên `25ms-obf` / `hercules` /
   `moonsecv2`: Vercel tự trace dependency bằng static analysis nên bỏ sót file nhị phân
   `glue.wasm` của `wasmoon` (không require() trực tiếp được bằng path tĩnh). Đã thêm
   `includeFiles: "node_modules/wasmoon/dist/**"` cho 3 function này trong `vercel.json` để ép
   Vercel đóng gói kèm. **Cần deploy lại (redeploy) sau khi cập nhật code này** — sửa file không
   tự áp dụng cho deployment cũ.
2. **Clyde `print("hi")` ra y nguyên, không obfuscate**: đây thực ra là hành vi *gốc* của
   `server.ts` Clyde (mặc định `encodeStrings`/`scramble` đều tắt, và script không có local nào
   để rename) — API không hề bị đơn giản hoá so với bản gốc. Vấn đề là trang test (`/`) chưa có ô
   bật các tuỳ chọn này nên trông như không chạy gì. Đã thêm đủ checkbox
   (`encodeStrings`, `scramble`, `oneLine`, tắt rename, tắt preserve) + dropdown `vmType`/`vmLevel`
   cho card Clyde trên trang test, 2 ô `encodeStrings`/`scramble` được tick sẵn để bấm
   Obfuscate là thấy kết quả thật ngay. Gọi API trực tiếp (không qua web) vẫn giữ đúng default
   gốc (tất cả tắt) nếu bạn không truyền `options`.


Một site Vercel duy nhất, mỗi obfuscator là 1 nhóm endpoint riêng dưới `/api/<engine>/...`
(không gộp logic các engine vào nhau), kèm web UI test nhanh (`/`) và trang docs (`/docs`).

## Cài đặt & deploy

```bash
npm install
cp .env.example .env.local   # chỉ để tham khảo, KHÔNG commit key thật vào git
```

1. Push repo này lên GitHub (hoặc dùng `vercel` CLI deploy thẳng từ thư mục).
2. Import vào Vercel.
3. Vào **Project Settings → Environment Variables**, thêm:
   - `API_KEY` = một chuỗi ngẫu nhiên dài (gợi ý: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`).
4. Deploy. Vercel sẽ tự chạy `npm run build` (compile toàn bộ `lib/engines/**/*.ts` sang `lib-dist/`) trước khi build các serverless function trong `api/`.
5. Test local trước khi deploy thật: `vercel dev` (cần Vercel CLI + đã `vercel link`).

Bot Discord / web của bạn gọi API bằng header:
```
X-API-Key: <API_KEY bạn đặt ở bước 3>
```
hoặc `Authorization: Bearer <key>`. Xem đầy đủ từng endpoint tại `/docs` sau khi deploy, hoặc `public/docs.html`.

## 8 engine, trạng thái thật sau khi build & test trong sandbox này

| Engine | Route | Nguồn gốc | Trạng thái |
|---|---|---|---|
| `luaegis` | `/api/luaegis/obfuscate`, `/vm`, `/validate` | Dự án TS/Express của bạn | ✅ Đã chạy thật, verify output đúng |
| `clyde` | `/api/clyde/obfuscate`, `/validate` | Lua-Obfuscator-Clyde-Protection (MIT, open-source gốc) | ✅ Đã chạy thật |
| `veil` | `/api/veil/obfuscate` | veil-lua-obfuscator (self-leak bởi null, free to use) — chỉ lấy phần lõi obfuscator, không kèm app/DB/auth gốc | ✅ Đã chạy thật |
| `lumora` | `/api/lumora/obfuscate` | Lumora-Obfuscator, port 1:1 sang JS thuần | ✅ Logic đơn giản, không phụ thuộc Lua runtime |
| `wearedev` | `/api/wearedev/obfuscate` | Proxy sang `wearedevs.net` (API công khai bên thứ 3) | ✅ Giữ nguyên logic gốc |
| `25ms-obf [old]` | `/api/25ms-obf/obfuscate` | Fork của Prometheus (không phải bản gốc) — CLI Lua, chạy qua `wasmoon` | ⚠️ Chưa test thật (sandbox không có mạng/Lua), cần smoke-test sau deploy |
| `hercules` | `/api/hercules/obfuscate` | hercules-obfuscator — CLI Lua, chạy qua `wasmoon` | ⚠️ Chưa test thật, preset `maximum` có thể dùng bytecode (`string.dump`) |
| `moonsecv2` | `/api/moonsecv2/obfuscate` | moonsec v2 by larpcorrupt (bản mô phỏng, không phải MoonSec gốc) | ⚠️⚠️ Rủi ro cao — dùng `string.dump` (bytecode), rất có thể không tương thích Lua 5.4 của `wasmoon` (xem bên dưới) |

`moonsec v3` đã bị bỏ theo yêu cầu (bản thật là C#/.NET — Vercel serverless không chạy được .NET).

## Vì sao 3 engine Lua CLI lại "chưa test thật"

Sandbox dùng để viết code này **không có kết nối mạng** (không `npm install` được `wasmoon`) và
**không có interpreter Lua** để chạy thử trực tiếp. Vì vậy:

- `luaegis`, `clyde`, `veil`, `lumora` — code thuần JS/TS, mình đã compile bằng `tsc` có sẵn trong
  sandbox và **chạy thật bằng `node`** để xác nhận ra đúng output obfuscate. Những route này tin
  cậy được ngay.
- `25ms-obf`, `hercules`, `moonsecv2` — là code Lua gốc, được nhúng chạy qua `wasmoon` (Lua 5.4
  biên dịch sang WASM, chạy thuần trong Node, không cần binary ngoài). Cách bundle nhiều file Lua
  (`package.preload`) là kỹ thuật chuẩn, và glue code gọi đúng API thật của từng project (đã đọc
  source để lấy đúng `Pipeline:fromConfig/apply`, preset keys, v.v.), nhưng **chưa chạy thử được**
  end-to-end. Sau khi deploy, hãy gọi thử với 1 đoạn script ngắn trước khi gắn vào bot thật.

### Rủi ro riêng của `moonsecv2`

Engine này dùng `string.dump(fn)` để lấy **bytecode** đã compile, rồi tự parse bytecode đó
(`parser.lua`). Bytecode Lua gắn chặt với đúng version sinh ra nó — `wasmoon` chạy Lua 5.4, trong
khi kiểu obfuscator "VM hoá" này thường được viết nhắm vào bytecode Lua 5.1. Nếu route này lỗi
hoặc ra output hỏng sau khi test, hướng sửa đúng là **host engine này trên 1 server có Lua 5.1
thật** (VPS, Render, Fly.io...) rồi để `/api/moonsecv2` proxy sang đó — giống hệt cách
`/api/wearedev` đang proxy sang wearedevs.net — chứ không phải cố vá `wasmoon`.

## Giới hạn thời gian chạy trên Vercel

- Hobby (free): **10 giây/function**, không thể tăng.
- Pro: mặc định cao hơn, cấu hình qua `functions.*.maxDuration` trong `vercel.json` (đã set sẵn
  60s cho các route nặng: `luaegis/vm`, `25ms-obf`, `hercules`, `moonsecv2`, `wearedev`).
- Nếu đang ở Hobby và `luaegis/vm` với `vmLayers` cao bị timeout 504: giảm `vmLayers`, dùng
  `vmLevel: "normal"` thay vì `"max"`, hoặc nâng lên Pro.

## Giấy phép / nguồn gốc (ghi chú theo thông tin bạn cung cấp)

- `veil-lua-obfuscator-leaked-by-null`: tự leak bởi null (dự án đã drop, free to use với member).
- `moonsec v2` / từng là `v3` by larpcorrupt: không phải MoonSec thật, chỉ là bản mô phỏng do
  larpcorrupt tự viết (v3 — bản C#/IronBrew2 — đã bị loại khỏi dự án này theo yêu cầu).
- `Lua-Obfuscator-Clyde-Protection`: MIT, open-source công khai trên GitHub.
- Các phần còn lại (`luaegis`, `lumora` port, wrapper code, website, docs) viết mới cho dự án này.

## Cấu trúc thư mục

```
api/
  _lib/auth.js, cors.js        # API key + CORS dùng chung
  health.js                    # GET, không cần key
  luaegis/  clyde/  veil/      # engine JS/TS — gọi thẳng lib-dist (đã compile)
  lumora/   wearedev/          # engine JS thuần / proxy
  25ms-obf/ hercules/ moonsecv2/  # engine Lua — chạy qua wasmoon
lib/
  engines/
    luaegis/  clyde/  veil/    # source TS gốc (compile ra lib-dist/ lúc build)
    lumora.js                  # port JS thuần
    25msRunner.js  herculesRunner.js  moonsecv2Runner.js   # wasmoon wrapper
  lua-sources/
    25ms-obf/  hercules/  moonsecv2/  # source .lua gốc, không sửa logic
  lua-bundle.js                # bundler chung: .lua -> package.preload cho wasmoon
public/
  index.html  docs.html  style.css  app.js   # web tester + docs
```

## Việc nên làm tiếp theo

1. Sau khi deploy: test từng route trong `/` (web tester) với 1 đoạn code ngắn.
2. Nếu `25ms-obf` / `hercules` chạy ổn ở wasmoon — tốt, giữ nguyên.
3. Nếu `moonsecv2` (hoặc preset `maximum` của `hercules`) lỗi do bytecode — cân nhắc host riêng
   1 service Lua 5.1 nhỏ (VPS/Render) và đổi handler thành proxy giống `/api/wearedev`.
4. Cân nhắc thêm rate-limit theo IP/key nếu public site bị gọi quá nhiều (hiện chưa có).
