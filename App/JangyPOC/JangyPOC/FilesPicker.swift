import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 文件 App 视频选择器：UIDocumentPickerViewController 的薄封装。
/// asCopy: true —— 系统把选中文件拷入 App 可访问的临时目录，返回 URL 直接可读，
/// 无需手工管理 security-scoped resource；后续 AssetImporter move 入库（与相册路径同构）。
struct FilesPicker: UIViewControllerRepresentable {
    /// 完成回调：选中文件的临时 URL 列表；取消/未选则为空数组
    let onFinish: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.movie], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: ([URL]) -> Void

        init(onFinish: @escaping ([URL]) -> Void) { self.onFinish = onFinish }

        nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Task { @MainActor in self.onFinish(urls) }
        }

        nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in self.onFinish([]) }
        }
    }
}
