import SwiftUI
import PhotosUI

/// 相册视频选择器：PHPickerViewController 的薄封装（系统 UI，进程外运行）。
/// 用 PHPickerConfiguration(photoLibrary:) 构造以拿到 assetIdentifier——
/// 后续 PHAsset 解析（POCCore.PhotosBridge）需要这个稳定标识。
/// 选择器本身免授权弹窗；授权在导入解析阶段由 PhotosBridge.requestReadAccess() 申请。
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    /// 完成回调：选中项的 assetIdentifier 列表；取消/未选则为空数组
    let onFinish: ([String]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 0   // 0 = 不限多选
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onFinish: ([String]) -> Void

        init(onFinish: @escaping ([String]) -> Void) { self.onFinish = onFinish }

        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let identifiers = results.compactMap(\.assetIdentifier)
            Task { @MainActor in self.onFinish(identifiers) }
        }
    }
}
