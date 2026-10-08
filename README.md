# ScanPDF

Ứng dụng quét tài liệu và xử lý PDF bằng SwiftUI, cho iPhone/iPad chạy iOS 17 trở lên. Mã nguồn dùng PDFKit, Vision, VisionKit và PhotosUI của Apple, không có thư viện runtime bên thứ ba.

## Tính năng

- Quét nhiều trang bằng camera: tự nhận diện mép giấy, chỉnh phối cảnh và cắt trang qua giao diện quét của iOS.
- Tạo PDF từ ảnh, nhập PDF từ ứng dụng Tệp; giữ màu gốc, chuyển xám hoặc đen trắng khi tạo tài liệu.
- Thư viện cục bộ: tìm theo tên, đổi tên, xóa, xem trước, chia sẻ và in PDF.
- Gộp PDF; trích xuất trang; xoay, xóa và thay đổi thứ tự trang.
- Nén PDF thành bản sao, thêm watermark và chữ ký vẽ tay tại các vị trí được chọn.
- Đặt mật khẩu PDF và tạo bản mở khóa khi biết mật khẩu.
- OCR trên thiết bị để lấy văn bản, tạo PDF có lớp văn bản có thể tìm kiếm.

## Giới hạn và dữ liệu

- Camera/quét tài liệu cần iPhone hoặc iPad thật có hỗ trợ VisionKit. Simulator dùng để kiểm tra phần xử lý PDF và giao diện; không kiểm chứng camera.
- OCR phụ thuộc ngôn ngữ mà Vision hỗ trợ trên phiên bản iOS của thiết bị. App ưu tiên tiếng Việt nếu có, dùng tiếng Anh làm dự phòng; chữ viết tay, dấu tiếng Việt, bố cục phức tạp có thể nhận sai. Kiểm tra văn bản trước khi sử dụng.
- Nén bằng cách raster hóa trang và mã hóa ảnh. Bản nén có thể mất lớp văn bản có thể tìm kiếm, vector, liên kết và các cấu trúc PDF tương tác; dung lượng có thể tăng với PDF vốn đã tối ưu. Tài liệu gốc vẫn nằm trong thư viện.
- Chữ ký là hình vẽ thêm lên tài liệu, không phải chữ ký số có chứng thư. Watermark/chữ ký hiển thị phụ thuộc trang và vị trí được chọn.
- Ứng dụng xử lý trên thiết bị, không có tài khoản, quảng cáo, analytics hoặc dịch vụ tải tài liệu lên máy chủ. PDF được lưu trong `Documents/Library/<UUID>.pdf`; thông tin thư viện nằm tại `Application Support/library.json` trong sandbox của app. iOS có thể đưa dữ liệu này vào bản sao lưu hệ thống theo cài đặt của bạn.
- Xóa app có thể xóa tài liệu bên trong. Hãy chia sẻ/xuất các file cần giữ trước khi gỡ app. PDF đã chia sẻ chịu sự quản lý của ứng dụng/dịch vụ mà bạn chọn.

## Cài bằng SideStore

1. Mở [Releases](https://github.com/duckk37/scanpdf/releases) và tải `ScanPDF-SideStore.ipa` từ bản build đã hoàn tất. `latest` là prerelease tự cập nhật mỗi khi nhánh `main` build thành công; các tag `v*` tạo bản phát hành riêng.
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

Script chọn một iPhone simulator đã cài có iOS 17 trở lên, ưu tiên phiên bản khớp SDK của Xcode đang hoạt động; nếu không có, chọn phiên bản gần nhất thấp hơn SDK. Script chạy XCTest, cài/mở app để kiểm tra khởi chạy và chụp `build/ScanPDF-Simulator.png`, build Release cho thiết bị arm64 bằng `CODE_SIGNING_ALLOWED=NO`, rồi đóng gói `Payload/ScanPDF.app`. File đầu ra gồm `build/ScanPDF-SideStore.ipa`, checksum và kết quả test `.xcresult`. CI giữ ảnh màn hình trong artifact **ScanPDF-Simulator-Preview** để kiểm tra giao diện ban đầu.

Windows không có Xcode/iOS SDK, nên không thể biên dịch hoặc kiểm chứng iOS native tại máy Windows. Workflow [Build iOS IPA](.github/workflows/ios.yml) dùng runner macOS để thực hiện build/test. Các GitHub Actions được pin bằng commit SHA; XcodeGen tải về được xác minh SHA-256.

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

Trước khi dùng cho tài liệu quan trọng: quét vài trang, kiểm tra viền/chỉnh phối cảnh; thử nhập từ Tệp/Ảnh; thử gộp, trích xuất, xoay, đổi thứ tự; mở lại bản nén/watermark/chữ ký; khóa/mở bằng mật khẩu; soát kết quả OCR và thử tìm trong PDF có văn bản; chia sẻ/in; đóng mở app để xác nhận thư viện được lưu.

Các tests tự động kiểm tra xử lý PDF bằng tài liệu được tạo trong bộ nhớ. Camera, quyền truy cập, in và cài/refresh SideStore cần được xác nhận trên thiết bị thật.
