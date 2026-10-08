import PencilKit
import SwiftUI

enum SignaturePlacement: String, CaseIterable, Identifiable {
    case bottomRight = "Góc phải dưới"
    case bottomLeft = "Góc trái dưới"
    case center = "Chính giữa"
    var id: String { rawValue }
}

@MainActor
struct SignatureView: View {
    let pageNumber: Int
    let onSave: (UIImage, SignaturePlacement) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var canvas = PKCanvasView()
    @State private var placement: SignaturePlacement = .bottomRight
    @State private var isEmpty = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chữ ký của bạn").font(.title2.bold())
                    Text("Viết bằng ngón tay hoặc Apple Pencil. Chữ ký sẽ được đặt lên trang \(pageNumber).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                SignatureCanvas(canvas: canvas, isEmpty: $isEmpty)
                    .frame(minHeight: 180, maxHeight: 260)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.teal.opacity(0.3), lineWidth: 1))

                HStack {
                    Label("Ký trong khung phía trên", systemImage: "pencil.tip.crop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Xóa nét vẽ", role: .destructive) {
                        canvas.drawing = PKDrawing()
                        isEmpty = true
                    }.disabled(isEmpty)
                }

                Picker("Vị trí trên trang", selection: $placement) {
                    ForEach(SignaturePlacement.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline)

                Text("Chữ ký được lưu thành hình ảnh trên PDF; đây là chữ ký viết tay, không phải chứng thư ký số.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Thêm chữ ký")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đặt chữ ký") {
                        let bounds = canvas.drawing.bounds.insetBy(dx: -8, dy: -8)
                        guard !isEmpty, bounds.width > 0, bounds.height > 0 else { return }
                        let image = canvas.drawing.image(from: bounds, scale: 2)
                        onSave(image, placement)
                    }.bold().disabled(isEmpty)
                }
            }
            .tint(Color(red: 0.02, green: 0.53, blue: 0.51))
        }
    }
}

private struct SignatureCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    @Binding var isEmpty: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvas.backgroundColor = .white
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SignatureCanvas
        init(_ parent: SignatureCanvas) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.isEmpty = canvasView.drawing.strokes.isEmpty
        }
    }
}
