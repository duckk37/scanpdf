# ScanPDF cho Windows và dịch PDF qua Wi-Fi

## Cài và sử dụng

1. Tải `ScanPDF-Desktop-Windows-x64.zip` trong [Releases](https://github.com/duckk37/scanpdf/releases), giải nén toàn bộ vào một thư mục có quyền đọc/ghi.
2. Mở `ScanPDF-Desktop/ScanPDF-Desktop.exe`; giữ thư mục `_internal` cạnh EXE. Không cần cài Python. Gói hiện chưa ký Authenticode; Windows có thể hiển thị thông tin nhà phát hành chưa được xác minh.
3. Nhập PDF vào thư viện hoặc dùng **Ảnh / Camera → PDF**. Bản Windows nhận ảnh/webcam qua Qt; giữ nguyên khung ảnh, chọn khổ gốc/A4/Letter và bộ lọc. Tự cắt phối cảnh dùng giao diện quét iOS trên iPhone.
4. Chọn tài liệu để gộp/tách/chèn/nhân bản/xoay/xóa/sắp xếp trang, nén, xuất ảnh, thêm watermark/số trang và khóa/mở khóa bằng mật khẩu. Thao tác tạo bản sao; kiểm tra kết quả trước khi dùng.

Bản Windows x64 dành cho Windows 10/11. Webcam và quyền camera phụ thuộc thiết bị; các bài test chạy trên Windows runner không thay thế kiểm tra camera thật.

## Dịch sang tiếng Việt

Trong **Dịch tiếng Việt**, chọn PDF, ngôn ngữ nguồn và nhà cung cấp: Google, Bing, Gemini hoặc API tương thích OpenAI của bạn. Bing cần ngôn ngữ nguồn cụ thể. Với API riêng, nhập base URL, model và API key trên PC; API key lưu trong Windows Credential Manager. Nhà cung cấp có thể áp dụng giới hạn/tính phí theo tài khoản của bạn.

Engine [PDFMathTranslate Next](https://github.com/PDFMathTranslate/PDFMathTranslate-next) / [BabelDOC](https://github.com/funstory-ai/BabelDOC) nhận diện bố cục và đặt bản dịch vào PDF, giữ hình/công thức theo khả năng của engine. Kết quả gồm PDF tiếng Việt và PDF song ngữ. Bản gốc được giữ trong thư viện. Bố cục, ngắt dòng và bản dịch cần được soát lại, nhất là bảng/công thức và trang phức tạp.

PDF cần có chữ thật có thể chọn được. Bản scan chỉ có ảnh hoặc ảnh với lớp OCR ẩn chưa được hỗ trợ dịch giữ bố cục. Hãy dùng PDF văn bản gốc khi có; chức năng OCR iOS vẫn hữu ích để tìm kiếm/trích văn bản nhưng không biến bản scan thành PDF có bố cục chữ thật.

Lần dịch đầu cần Internet để tải model nhận diện và font vào `%USERPROFILE%\.cache\babeldoc` theo cơ chế upstream. Model DocLayout khoảng 75 MB, model RapidOCR khoảng 4.7 MB, bộ font khoảng 266 MB; cộng tokenizer và dữ liệu phụ, nên dự trù khoảng 350 MB tải thêm. Những file này được tái sử dụng và upstream kiểm tra hash. Cache BabelDOC không có sẵn trong ZIP; thư viện RapidOCR có kèm các model OCR mặc định nhỏ hơn. Dịch qua Google/Bing/API vẫn cần mạng tới nhà cung cấp sau khi có cache.

Ứng dụng xử lý từng tác vụ dịch để hạn chế RAM. Mỗi PDF tối đa 100 MB và 500 trang; tối đa 8 tác vụ đang chờ. Muốn dịch một phần tài liệu, dùng **Tách trang** tạo PDF nhỏ trước (backend API cũng nhận dải trang `1,3-5`; giao diện dịch hiện gửi toàn bộ PDF). Công việc/lỗi và tiến trình được hiển thị trong app; có thể hủy tác vụ đang chạy. File tác vụ tạm của phiên làm việc được dọn khi đóng app; phần còn sót do lỗi được dọn khi mở lại nếu đã quá 24 giờ. PDF đã nhập vào thư viện vẫn được giữ.

## Trợ lý Gemini

1. Tạo API key qua [Google AI Studio](https://aistudio.google.com/apikey), rồi nhập ở **Dịch tiếng Việt → Gemini** và nhấn **Lưu Gemini**. Key này tách biệt với API key tương thích OpenAI; không ghi vào JSON, Git hoặc PDF.
2. Model mặc định `gemini-3.8-flash`; có thể chọn `gemini-3.5-flash-lite` hoặc nhập tên model Gemini được tài khoản của bạn hỗ trợ. Đối chiếu [danh sách model của Google](https://ai.google.dev/gemini-api/docs/models) nếu model bị ngừng phục vụ.
3. Vào **Trợ lý Gemini**, chọn PDF và tóm tắt/hỏi đáp/giải thích, chọn cho phép gửi PDF tới Google, rồi nhấn phân tích. PDF scan cũng dùng được cho trợ lý. PDF bảo vệ cần mật khẩu đúng; bản gửi được mở khóa trong bộ nhớ và bản gốc vẫn giữ nguyên.
4. Đọc kết quả và các trang Gemini đề xuất; mở bản gốc để kiểm tra. Sao chép hoặc xuất TXT khi cần. Trợ lý không chỉnh sửa PDF hay tự thực thi chỉ dẫn bên trong tài liệu.

Giới hạn mỗi yêu cầu: PDF 10 MB, 60 trang; câu hỏi 3000 ký tự. PC xử lý một yêu cầu trợ lý tại một thời điểm. Có thể ngừng chờ; yêu cầu đã gửi có thể vẫn được Google xử lý. App không tự gửi lại yêu cầu trợ lý khi lỗi/mất kết nối. Mạng, quota, API key và quyền dùng model phụ thuộc tài khoản của bạn; không có key dùng chung được đóng gói.

Trên iPhone/iPad, mở PDF → **Trợ lý Gemini**, dùng kết nối PC và mã ghép nối đã có. **Lưu Gemini** trên PC để trợ lý sẵn sàng ngay cả khi dịch PDF đang chọn Google/Bing. Nhấn **Xóa API key** trên PC để ngừng dùng key cho yêu cầu mới; yêu cầu đã gửi có thể tiếp tục.

Gemini nhận toàn bộ PDF để phân tích, gồm chữ, hình, công thức và ảnh scan; khác với dịch giữ bố cục chỉ gửi các đoạn cần dịch. Nội dung được Google xử lý theo dịch vụ của họ. Chức năng xử lý PDF cục bộ và dịch Google/Bing vẫn dùng được khi chưa cấu hình Gemini.

Bộ prompt cho tóm tắt/hỏi đáp/giải thích, quy tắc dẫn trang và cách xử lý công thức/chữ mờ: [ai-prompts.md](ai-prompts.md). PC và iOS dùng chung các prompt này.

## Kết nối iPhone với PC

1. PC và iPhone cùng Wi-Fi tin cậy. Mở ScanPDF Windows → **Kết nối iPhone**, chọn địa chỉ mạng/cổng mặc định `8765`, bật kết nối và sao chép URL + mã ghép nối.
2. Cho phép EXE qua Windows Firewall trên mạng riêng nếu Windows hỏi. PC phải bật và ứng dụng tiếp tục chạy.
3. Trên iPhone: **Công cụ → Dịch tiếng Việt → Kết nối PC**, nhập URL dạng `http://192.168.x.x:8765` và mã ghép nối; cho phép Local Network khi iOS hỏi.
4. Chọn PDF để gửi tới PC, theo dõi tiến trình và nhập bản tiếng Việt/song ngữ về thư viện iOS. Nhà cung cấp API riêng được cấu hình trên PC; API key không cần gửi sang iPhone.

Kết nối LAN dùng HTTP và mã ghép nối, không mã hóa nội dung truyền trên Wi-Fi. Chỉ bật trên mạng riêng tin cậy; không mở cổng router ra Internet. Dừng kết nối trong app khi dùng xong. Mã ghép nối lưu trong Windows Credential Manager.

## Dữ liệu

PDF/thư viện Windows nằm trong thư mục dữ liệu ứng dụng do Qt chọn (`%LOCALAPPDATA%\duckk37\ScanPDF` trên cấu hình Windows thông thường). Thư viện lưu PDF và metadata JSON, cấu hình không bí mật nằm trong `settings.json`. Dùng nút xuất bản sao để giữ tài liệu ở thư mục bạn chọn. Model cache upstream nằm riêng như mô tả ở trên.

Công cụ PDF và thư viện xử lý trên máy. Khi chủ động dịch, PDF được gửi từ iPhone tới PC, và văn bản cần dịch được gửi tới nhà cung cấp đã chọn. Nhà cung cấp quản lý dữ liệu theo dịch vụ của họ. API key/mã ghép nối lưu trong Credential Manager, không ghi vào Git hoặc JSON cấu hình.

## Build từ mã nguồn

Cần Windows x64, Python **3.12** x64. Các file lock có version và hash wheel dành riêng cho Windows/Python 3.12; không dùng cho macOS/Linux.

```powershell
./scripts/build-windows.ps1
```

Script tạo `desktop/.venv`, cài dependency theo hash, chạy pytest, đóng gói PyInstaller, chạy `--self-test`, chụp giao diện bằng `--screenshot`, rồi tạo ZIP/checksum và ZIP nguồn. Bản EXE dạng thư mục giữ DLL Qt/ONNX bên cạnh ứng dụng; [PyInstaller mô tả cơ chế folder build](https://pyinstaller.org/en/stable/operating-mode.html#bundling-to-one-folder).

Output nằm ở `desktop/dist/`. Có thể chạy source bằng `desktop/.venv/Scripts/python.exe desktop/main.py`. Để kiểm tra riêng: `desktop/.venv/Scripts/python.exe -m pytest -c desktop/pytest.ini desktop/tests -q`.

Workflow [Build Windows desktop](../.github/workflows/windows.yml) dùng Windows runner x64, kiểm thử EXE rồi tải ZIP lên Release. Workflow iOS chạy riêng trên macOS; hai workflow dùng cùng nhóm publish để giữ asset của cả hai nền tảng. Tag `v*` tạo release riêng, nhánh `main` cập nhật `latest`.

Giấy phép và nguồn thư viện: [THIRD_PARTY_NOTICES.md](../desktop/THIRD_PARTY_NOTICES.md). Windows app dùng AGPL-3.0 hoặc mới hơn; ZIP nguồn cung cấp mã build và các nguồn upstream có giấy phép AGPL/GPL. Không có cache model/font BabelDOC tải trước hoặc API key trong gói phát hành.
