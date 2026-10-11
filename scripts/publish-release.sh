#!/usr/bin/env bash
set -euo pipefail

: "${GH_REPO:?Set GH_REPO}"
: "${GITHUB_SHA:?Set GITHUB_SHA}"
: "${GITHUB_REF:?Set GITHUB_REF}"
if [[ $# -eq 0 ]]; then
  echo "Pass the tested release assets to publish." >&2
  exit 1
fi
assets=()
for asset in "$@"; do
  [[ -f "$asset" && -f "$asset.sha256" ]] || { echo "Missing asset/checksum: $asset" >&2; exit 1; }
  (cd "$(dirname "$asset")" && sha256sum --check "$(basename "$asset").sha256")
  assets+=("$asset" "$asset.sha256")
done
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
cat > "$notes" <<EOF
ScanPDF cho iPhone/iPad iOS 17+ và PC Windows x64.

- **ScanPDF-SideStore.ipa**: mở trong SideStore để ký bằng Apple Account của bạn. Chữ ký ad-hoc trong gói chỉ dùng kiểm tra toàn vẹn.
- **ScanPDF-Desktop-Windows-x64.zip**: giải nén toàn bộ, mở ScanPDF-Desktop.exe trong thư mục. Gói gồm Qt/engine DLL, chưa ký Authenticode; không cần cài Python.
- **ScanPDF-Desktop-Source.zip**: mã nguồn PC và các nguồn upstream có giấy phép AGPL/GPL, cùng hướng dẫn build.

Hai workflow cập nhật các asset riêng sau khi tests và kiểm tra khởi chạy vượt qua. Trong lúc đang build, asset iOS/Windows có thể đến ở những thời điểm khác nhau. Mỗi file tải về có checksum SHA-256.

Dịch giữ bố cục dùng PDFMathTranslate Next/BabelDOC trên PC. Lần đầu cần Internet tải model/font (~350 MB); dịch dùng nhà cung cấp đã chọn. Bản scan/ảnh có OCR ẩn chưa hỗ trợ dịch giữ bố cục.

Gemini hỗ trợ dịch PDF và trợ lý tóm tắt/hỏi đáp/giải thích, gồm PDF scan. Nhập API key của bạn trên PC; trợ lý gửi toàn PDF tới Google sau khi bạn chủ động chọn phân tích. Giới hạn trợ lý: 10 MB, 60 trang. Hạn mức/chi phí theo Gemini API của bạn; kết quả AI cần đối chiếu bản gốc.

Lượt cập nhật này: **${GITHUB_SHA}**.
Hướng dẫn: https://github.com/$GH_REPO#readme
EOF
if [[ "$GITHUB_REF" == refs/tags/v* ]]; then
  tag="${GITHUB_REF#refs/tags/}"
  if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" --verify-tag --title "ScanPDF $tag" --notes-file "$notes"
  fi
else
  tag=latest
  if gh release view "$tag" >/dev/null 2>&1; then
    gh api --method PATCH "repos/$GH_REPO/git/refs/tags/$tag" \
      -f "sha=$GITHUB_SHA" -F force=true >/dev/null
    gh release edit "$tag" --title 'ScanPDF · Latest build' --notes-file "$notes" --prerelease
  else
    gh release create "$tag" --target "$GITHUB_SHA" \
      --title 'ScanPDF · Latest build' --notes-file "$notes" --prerelease
  fi
fi
# Upload only this workflow's assets. The other platform's files survive.
gh release upload "$tag" "${assets[@]}" --clobber
