# Luna Moon — chưa wire được, lý do cụ thể

Nguồn: `obfuuscator.vercel.app`, trích từ `assets/Landing-BBVTw25V.js` (xem
`UPSTREAM_README.md`, `engine.original.js`, `USAGE_STUB.js` — nguyên văn file
người dùng cung cấp, không chỉnh sửa).

## Đã kiểm tra

Quét toàn bộ hàm top-level trong `engine.original.js` (~40 hàm: `pe`, `U`,
`_`, `he`, `fe`, `Ne`, `D`, `Ee`, `xe`, `E`, `wt`, `C`, `$`, `jt`, `W`, `S`,
`J`, `be`, `Nt`, `P`, `Et`, `V`, `Mt`, `St`, `Ct`, `Lt`, `Bt`, `ge`, `It`,
`re`, `ke`, `Ot`, `Ft`, `Rt`, `Se`, `Tt`, `Pt`, `ye`, `qt`, `Ut`, ...) —
**không có hàm nào** nhận vào object dạng
`{ level, encryptStrings, encodeNumbers, minify, integrityCheck }` mà chính
README của gói này mô tả là shape thật của entry point. Cũng không có dòng
`export` nào thật sự export 1 hàm orchestrator.

Điều này khớp với chính lời README gốc: *"the real entry point is buried
inside the minified engine.js"* / *"To use it properly you still need to
wire the entry function"* — tức là ngay cả người trích xuất file này cũng
chưa tìm/nối được pipeline thật, chỉ có các mảnh rời (tokenizer, renamer,
string encryptor, control-flow flattener, junk inserter, integrity check...).

## Vì sao không đoán đại cho chạy

Ghép ~40 hàm minified theo đúng thứ tự gọi (tokenize → parse → rename →
encrypt string → control-flow → junk → integrity → emit) mà không có bản gốc
để đối chiếu kết quả, và sandbox viết code này không có mạng để gọi thử
`obfuuscator.vercel.app` thật — nếu đoán sai thứ tự/tham số, output sinh ra
trông "có vẻ obfuscate" nhưng thực chất sai logic (code sau obfuscate chạy
không ra kết quả như bản gốc), **nguy hiểm hơn** là không trả gì cả. Nên route
`/api/luna-moon/obfuscate` hiện trả 501 kèm lý do, thay vì giả vờ chạy được.

## Hướng làm tiếp nếu muốn hoàn thiện

1. Lấy được bản đầy đủ `Landing-BBVTw25V.js` (không phải bản đã cắt riêng
   `engine.js`) — phần UI React gọi vào engine thường nằm ngay trong cùng
   chunk, chỉ là file trích xuất hiện tại có thể đã cắt mất đoạn đó.
2. Hoặc mở DevTools trên `obfuuscator.vercel.app` thật, obfuscate 1 đoạn code
   ngắn, rồi dùng breakpoint/call stack để tìm chính xác hàm nào được gọi khi
   bấm nút "Obfuscate" — từ đó map ra đúng tên hàm orchestrator.
3. Hoặc chấp nhận bỏ Luna Moon khỏi danh sách engine.

---

## Update — đổi hướng: headless-browser automation thay vì reimplement

Bạn gửi thêm 1 bản mirror đầy đủ site (`obfuuscator-vercel-app.zip`, qua Zipasite) thay vì chỉ
`engine.js`. Mở bundle JS thật của bản mirror này (`assets/1d95c7905c216d06-index-CkD9fOaq.js`,
441KB) thì phát hiện 1 điều quan trọng:

**Bản hiện tại của site KHÔNG còn chứa logic obfuscate ở client nữa.** Bundle JS này không có
chữ "obfusc" nào cả — thay vào đó có `ConvexError`, `convexWebSocketOpen`, và URL backend thật:
`https://compassionate-ant-590.convex.cloud`. Tức là site đã refactor sang gọi 1 backend
(Convex) để xử lý thật, khác với bản cũ (`Landing-BBVTw25V.js`) từng có logic client thuần mà
bạn gửi lúc đầu.

Vì vậy việc "reimplement" lại từ đầu không còn ý nghĩa — ngay cả khi ghép đúng hết các hàm minified
cũ, nó cũng không phải cách site thật đang chạy bây giờ. Hướng đúng là **điều khiển UI thật bằng
headless browser** (Puppeteer) — xem `lib/engines/lunaMoonRunner.js`. Site mirror được tự host
tại `public/luna-moon-mirror/` để không phụ thuộc `obfuuscator.vercel.app` còn sống hay không
(backend Convex vẫn là phụ thuộc không tránh được, giống các proxy khác trong dự án này).

**Vẫn chưa test được thật** (không có mạng/browser trong sandbox viết code) — các CSS selector
trong `lunaMoonRunner.js` là suy luận từ chuỗi text tìm thấy trong bundle minified
(`data-placeholder-text`, `"copy"`, `"download"`), không phải xác nhận trên DOM render thật. Xem
README.md phần "Luna Moon — cần bạn tự kiểm tra DOM thật" để biết cách tự sửa nếu sai.
