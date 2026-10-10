# ScanPDF

Ứng dụng quét tài liệu, xử lý PDF và dịch PDF sang tiếng Việt cho **iPhone/iPad iOS 17+** và **Windows x64**. Phiên bản mã nguồn hiện tại: **1.2.0**. App iOS dùng SwiftUI, PDFKit, Vision, VisionKit và PhotosUI của Apple. App Windows dùng PySide6, PyMuPDF và engine PDFMathTranslate Next/BabelDOC.

## Thay đổi trong 1.2.0

- Thêm ScanPDF cho Windows: thư viện, xem PDF, xử lý trang, xuất ảnh, nén, watermark, số trang và mật khẩu; tạo PDF từ ảnh hoặc webcam.
- Dịch PDF có chữ thật sang tiếng Việt trên PC bằng engine chuyên xử lý bố cục PDF, giữ hình/công thức theo khả năng của engine; xuất bản tiếng Việt và song ngữ.
- Chọn Google, Bing hoặc API tương thích OpenAI. API key cấu hình trên PC và lưu trong Windows Credential Manager.
- iPhone kết nối PC cùng Wi-Fi bằng URL/mã ghép nối, gửi PDF để dịch rồi nhập kết quả về thư viện iOS.
- Thêm build/test EXE Windows và ZIP nguồn vào GitHub Releases, cùng IPA iOS.

## Cài Windows và dịch PDF

1. Mở [Releases](https://github.com/duckk37/scanpdf/releases), tải `ScanPDF-Desktop-Windows-x64.zip`, giải nén toàn bộ và mở `ScanPDF-Desktop/ScanPDF-Desktop.exe`. Giữ thư mục `_internal` cạnh EXE; không cần cài Python. Gói chưa ký Authenticode.
2. Nhập PDF có chữ chọn được, vào **Dịch tiếng Việt**, chọn ngôn ngữ nguồn và dịch vụ. Google hỗ trợ tự nhận diện; Bing cần chọn ngôn ngữ nguồn; API riêng cần URL/model/API key.
3. Lần dùng đầu cần Internet tải model và font khoảng **350 MB** vào `%USERPROFILE%\.cache\babeldoc`. Dịch tiếp tục cần kết nối tới nhà cung cấp đã chọn; chi phí/giới hạn API theo tài khoản của bạn.
4. Để dịch từ iPhone, mở **Kết nối iPhone** trên PC, bật dịch vụ cổng mặc định `8765`; trên iPhone vào **Công cụ → Dịch tiếng Việt → Kết nối PC**, nhập URL và mã ghép nối. Hai máy cùng Wi-Fi tin cậy; cho phép Local Network trên iOS và Windows Firewall mạng riêng khi được hỏi. PC/app phải tiếp tục chạy.

Kết nối Wi-Fi dùng HTTP và mã ghép nối, không mã hóa nội dung truyền. Chỉ bật trên mạng riêng tin cậy. Khi dịch, tài liệu chuyển sang PC và văn bản gửi tới nhà cung cấp đã chọn; API key không cần đưa sang iPhone.

**Dịch giữ bố cục cần PDF có chữ thật. Bản scan/ảnh, kể cả có lớp OCR ẩn, chưa được hỗ trợ cho luồng dịch này.** Bản dịch/ngắt dòng/bảng/công thức cần được soát lại. Giới hạn mỗi tác vụ: 100 MB, 500 trang; PC chạy lần lượt các tác vụ. Bản gốc được giữ; output gồm PDF tiếng Việt và song ngữ.

Hướng dẫn đầy đủ, dữ liệu, cache, webcam và build: [docs/windows.md](docs/windows.md). Windows app và nguồn tích hợp engine dùng AGPL-3.0 hoặc mới hơn; xem [giấy phép và thư viện](desktop/THIRD_PARTY_NOTICES.md). Giấy phép đó áp dụng thành phần Windows, không thay đổi giấy phép các SDK Apple hoặc thư viện bên thứ ba.

## Thay đổi trong 1.1.0

- Xuất những trang được chọn của PDF thành PNG hoặc JPEG; chia sẻ từng file ảnh qua giao diện chia sẻ iOS.
- Chèn các trang từ một PDF khác vào tài liệu và nhân bản trang.
- Tạo bản sao có số trang.
- Tạo PDF scan với khổ trang theo ảnh gốc, A4 hoặc Letter; A4/Letter giữ toàn bộ ảnh và thêm lề trắng nếu cần.
- Đánh dấu yêu thích và sắp xếp thư viện. Thư viện của phiên bản 1.0 vẫn được đọc khi cập nhật app.

## Tính năng

- Quét nhiều trang bằng camera: tự nhận diện mép giấy, chỉnh phối cảnh và cắt trang qua giao diện quét của iOS.
- Tạo PDF từ ảnh, nhập PDF từ ứng dụng Tệp; giữ màu gốc, chuyển xám hoặc đen trắng khi tạo tài liệu; chọn khổ trang theo ảnh, A4 hoặc Letter.
- Thư viện cục bộ: tìm theo tên, yêu thích, sắp xếp, đổi tên, xóa, xem trước, chia sẻ và in PDF.
- Gộp PDF; chèn PDF; trích xuất, nhân bản, xoay, xóa và thay đổi thứ tự trang.
- Xuất các trang PDF được chọn thành PNG/JPEG, chia sẻ nhiều file ảnh; tạo bản sao PDF có số trang.
- Nén PDF thành bản sao, thêm watermark và chữ ký vẽ tay tại các vị trí được chọn.
- Đặt mật khẩu PDF và tạo bản mở khóa khi biết mật khẩu.
- OCR trên thiết bị để lấy văn bản, tạo PDF có lớp văn bản có thể tìm kiếm.
- Dịch PDF qua PC cùng Wi-Fi, theo dõi tiến trình/hủy tác vụ và nhập bản tiếng Việt/song ngữ về thư viện.

## Giới hạn và dữ liệu

- Camera/quét tài liệu cần iPhone hoặc iPad thật có hỗ trợ VisionKit. Simulator dùng để kiểm tra phần xử lý PDF và giao diện; không kiểm chứng camera.
- Khổ A4/Letter đặt ảnh vừa trong trang và giữ tỷ lệ, có thể xuất hiện lề trắng; lựa chọn khổ giấy này không cắt bớt nội dung ảnh. Lớp OCR được đặt theo vị trí ảnh trên trang.
- OCR phụ thuộc ngôn ngữ mà Vision hỗ trợ trên phiên bản iOS của thiết bị. App ưu tiên tiếng Việt nếu có, dùng tiếng Anh làm dự phòng; chữ viết tay, dấu tiếng Việt, bố cục phức tạp có thể nhận sai. Kiểm tra văn bản trước khi sử dụng.
- Nén bằng cách raster hóa trang và mã hóa ảnh. Bản nén có thể mất lớp văn bản có thể tìm kiếm, vector, liên kết và các cấu trúc PDF tương tác; dung lượng có thể tăng với PDF vốn đã tối ưu. Tài liệu gốc vẫn nằm trong thư viện.
- PNG/JPEG xuất ra là ảnh tĩnh của từng trang, không giữ lớp văn bản có thể tìm kiếm, liên kết hoặc biểu mẫu PDF. Chia sẻ chọn nhiều trang tạo nhiều file ảnh, không tạo ZIP. Tài liệu PDF gốc vẫn nằm trong thư viện.
- Chữ ký là hình vẽ thêm lên tài liệu, không phải chữ ký số có chứng thư. Watermark/chữ ký hiển thị phụ thuộc trang và vị trí được chọn.
- Công cụ PDF, quét và OCR iOS xử lý trên thiết bị; không có quảng cáo hoặc analytics. Khi chủ động dùng dịch, app gửi PDF tới PC đã ghép nối, PC gửi văn bản cần dịch tới nhà cung cấp bạn chọn. PDF iOS được lưu trong `Documents/Library/<UUID>.pdf`; thông tin thư viện nằm tại `Application Support/library.json` trong sandbox của app. iOS có thể đưa dữ liệu này vào bản sao lưu hệ thống theo cài đặt của bạn.
- Xóa app có thể xóa tài liệu bên trong. Hãy chia sẻ/xuất các file cần giữ trước khi gỡ app. PDF đã chia sẻ chịu sự quản lý của ứng dụng/dịch vụ mà bạn chọn.

## Cài bằng SideStore

1. Mở [Releases](https://github.com/duckk37/scanpdf/releases) và tải `ScanPDF-SideStore.ipa` từ bản build đã hoàn tất. `latest` là prerelease tự cập nhật mỗi khi nhánh `main` build thành công; các tag `v*` tạo bản phát hành riêng. Hai workflow cập nhật asset iOS/Windows ở các thời điểm khác nhau; chọn đúng file IPA cho SideStore.
2. Cài và thiết lập SideStore theo [hướng dẫn chính thức](https://docs.sidestore.io/docs/installation/install), gồm Apple Account, VPN và Developer Mode khi được yêu cầu.
3. Lưu IPA trong ứng dụng Tệp. Trong SideStore, vào **My Apps**, nhấn **+**, chọn IPA và chờ SideStore ký/cài bằng Apple Account của bạn.
4. Mở ScanPDF, cấp quyền camera khi quét. Refresh ứng dụng theo thời hạn hiển thị trong SideStore.

`ScanPDF-SideStore.ipa` được build cho arm64 và có chữ ký ad-hoc (`codesign --sign -`) để kiểm tra toàn vẹn. **Đây chưa phải chữ ký Apple cho tài khoản/thiết bị của bạn**; SideStore thực hiện bước ký cá nhân khi cài. Không cần gửi Apple Account, mật khẩu hoặc chứng chỉ của bạn cho dự án này.

Theo [FAQ SideStore](https://docs.sidestore.io/docs/faq), tài khoản Apple miễn phí có chu kỳ ký 7 ngày và giới hạn 3 app đang hoạt động, tính cả SideStore. Khả năng cài/refresh phụ thuộc thiết bị, phiên bản iOS và cấu hình SideStore hiện tại; đối chiếu tài liệu SideStore nếu gặp lỗi.

Nếu chưa có bản Release, vào tab [Actions](https://github.com/duckk37/scanpdf/actions/workflows/ios.yml), chọn một lần chạy thành công và tải artifact **ScanPDF-SideStore**. Giải nén artifact để lấy IPA; không chọn file ZIP artifact trực tiếp trong SideStore. Có thể chạy workflow bằng **Run workflow** khi có quyền trên repo.

Mỗi IPA đi kèm file `.sha256`. Trên macOS/Linux, kiểm tra bằng:

```sh
shasum -a 256 --check ScanPDF-SideStore.ipa.sha256
```

## Build trên macOS

Cần Xcode hỗ trợ iOS 17 trở lên, công cụ dòng lệnh Xcode, Python 3 và [XcodeGen](https://github.com/yonaskolb/XcodeGen). Nên dùng cùng bản XcodeGen 2.46.0 như CI. Source of truth của project là `project.yml`; `.xcodeproj` được tạo tự động và không commit vào repo.

```sh
brew install xcodegen
xcodegen generate --spec project.yml
open ScanPDF.xcodeproj
```

Để chạy trên iPhone trực tiếp từ Xcode, chọn team Apple của bạn ở **Signing & Capabilities**, chọn thiết bị rồi Run. Bundle identifier mặc định là `com.duckk37.scanpdf`.

Để chạy unit tests, build app iOS và đóng gói IPA cho SideStore:

```sh
bash scripts/build-ios.sh
```

Script kiểm tra logic chọn simulator bằng các Python fixtures trước khi tạo project. Sau đó, script chọn một iPhone simulator đã cài có iOS 17 trở lên, ưu tiên phiên bản khớp SDK của Xcode đang hoạt động; nếu không có, chọn phiên bản gần nhất thấp hơn SDK. Script chạy XCTest, cài/mở app để kiểm tra khởi chạy và chụp `build/ScanPDF-Simulator.png`, build Release cho thiết bị arm64 bằng `CODE_SIGNING_ALLOWED=NO`, rồi đóng gói `Payload/ScanPDF.app`. File đầu ra gồm `build/ScanPDF-SideStore.ipa`, checksum và kết quả test `.xcresult`. CI giữ ảnh màn hình trong artifact **ScanPDF-Simulator-Preview** để kiểm tra giao diện ban đầu.

Có thể chạy riêng các kiểm tra chọn simulator trên macOS hoặc Windows có Python 3:

```sh
python -m unittest discover -s scripts/tests -v
```

Windows không có Xcode/iOS SDK, nên không thể biên dịch hoặc kiểm chứng iOS native tại máy Windows. Workflow [Build iOS IPA](.github/workflows/ios.yml) dùng runner macOS để thực hiện build/test. Các GitHub Actions được pin bằng commit SHA; XcodeGen tải về được xác minh SHA-256.

## Build Windows

Cần Python **3.12 x64** trên Windows. Chạy:

```powershell
./scripts/build-windows.ps1
```

Script cài dependency theo version/hash trong môi trường `desktop/.venv`, chạy pytest, đóng gói PyInstaller thành EXE dạng thư mục, kiểm tra import/worker dịch/PDF/thư viện trên EXE và chụp giao diện. Output ở `desktop/dist/` gồm `ScanPDF-Desktop-Windows-x64.zip`, `ScanPDF-Desktop-Source.zip`, checksum và ảnh preview. Workflow [Build Windows desktop](.github/workflows/windows.yml) kiểm thử trước khi upload vào `latest` hoặc release tag, giữ asset IPA của workflow iOS.

## Ký Apple bằng chứng chỉ của bạn (tùy chọn)

Nếu cần IPA được ký Apple trước khi tải về, thêm những **repository secrets** sau tại Settings → Secrets and variables → Actions. Không đưa các file chứng chỉ hoặc mật khẩu vào Git:

| Secret | Nội dung |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | File `.p12` gồm chứng chỉ Apple và private key, mã hóa base64 |
| `P12_PASSWORD` | Mật khẩu của file `.p12` |
| `BUILD_PROVISION_PROFILE_BASE64` | Provisioning profile `.mobileprovision`, mã hóa base64 |
| `KEYCHAIN_PASSWORD` | Mật khẩu ngẫu nhiên cho keychain tạm của build |

Chọn **Run workflow** rồi bật `sign_with_apple`. Workflow vẫn chạy tests trước, sau đó tạo artifact riêng **ScanPDF-AppleSigned**. IPA ký Apple không được tải lên Release tự động; artifact tồn tại 7 ngày. Script kiểm tra hạn profile, bundle ID, chứng chỉ khớp profile và dọn keychain/file bí mật khi kết thúc.

Profile phải cho phép bundle `com.duckk37.scanpdf` và thiết bị cài app. Dùng profile Development/Ad Hoc phù hợp; profile App Store không dùng để cài trực tiếp ngoài App Store. Apple mô tả các điều kiện tại [Create an ad hoc provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile). SideStore có thể ký lại IPA bằng tài khoản của bạn khi cài.

## Kiểm tra trên thiết bị thật

Trước khi dùng cho tài liệu quan trọng:

- Quét vài trang, kiểm tra viền/chỉnh phối cảnh; thử khổ theo ảnh, A4 và Letter, xác nhận toàn bộ ảnh và lớp OCR nằm đúng trên trang.
- Thử nhập từ Tệp/Ảnh; gộp, chèn PDF, trích xuất, nhân bản, xoay và đổi thứ tự trang.
- Xuất vài trang thành PNG và JPEG, mở từng ảnh để kiểm tra nội dung và chia sẻ nhiều file.
- Mở lại bản nén, bản có watermark, chữ ký và số trang; khóa/mở bằng mật khẩu; soát kết quả OCR và thử tìm trong PDF có văn bản.
- Đánh dấu yêu thích, đổi cách sắp xếp; đóng mở app để xác nhận thư viện được lưu. Khi cập nhật từ 1.0, giữ app và kiểm tra các tài liệu cũ trước khi thay đổi.
- Thử chia sẻ và in từ thiết bị.
- Với dịch PDF, ghép nối PC cùng Wi-Fi, thử PDF có chữ thật, xác nhận tiến trình/bản tiếng Việt/song ngữ; thử hủy và ngắt kết nối. Soát bố cục, hình và công thức ở output. Bản scan/OCR ẩn phải hiển thị giới hạn hỗ trợ rõ ràng.

Các tests tự động kiểm tra xử lý PDF bằng tài liệu được tạo trong bộ nhớ. Camera, quyền truy cập, in và cài/refresh SideStore cần được xác nhận trên thiết bị thật.
