import SwiftUI
import VisionKit
import UIKit

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentScanner: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], Error>) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[UIImage], Error>) -> Void
        init(completion: @escaping (Result<[UIImage], Error>) -> Void) { self.completion = completion }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            completion(.success((0..<scan.pageCount).map { scan.imageOfPage(at: $0) }))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            completion(.success([]))
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(error))
        }
    }
}
