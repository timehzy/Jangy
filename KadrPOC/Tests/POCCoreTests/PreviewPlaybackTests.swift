import AVFoundation
#if os(iOS)
import UIKit
#endif
import XCTest
@testable import POCCore

/// 预览播放回归：转场边界不停播。
///
/// 曾实测 iOS 26 模拟器：转场路径（双视频轨 composition）+ 素材分辨率恰好等于
/// renderSize（1080x1920）→ 显示管线把解码 buffer 直通 CA image queue 被拒
/// （-11800/-19230 "CoreAnimation image queue does not support this pixel format"）
/// → AVPlayerItemFailedToPlayToEndTime，播到转场即停。修复见 PreviewBridge.nudgeIdentityTransforms。
final class PreviewPlaybackTests: XCTestCase {

    private var workDir: URL!
    private var resolver: AssetResolver!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = try AssetSynthesizer.synthesize(into: workDir)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        resolver = nil
    }

    /// 4 倍速扫过整段时间轴（dissolve + 0.5x 变速段），转场边界处 rate 掉 0 即回归。
    @MainActor
    func testPlaybackDoesNotStallAtTransitionBoundary() async throws {
        let plan = EditPlan(
            assets: [
                AssetItem(id: SamplePlan.assetID1, kind: .video, fileName: "clip1.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                AssetItem(id: SamplePlan.assetID2, kind: .video, fileName: "clip2.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
            ],
            clips: [
                PlanClip(assetID: SamplePlan.assetID1, range: 0...3,
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(assetID: SamplePlan.assetID2, range: 0...3, speed: .flat(0.5)),
            ]
        )

        let package = try await PreviewBridge.makePreview(for: plan, resolver: resolver)
        let player = AVPlayer(playerItem: package.playerItem)
        player.rate = 4  // 快进扫过边界；若边界处会停，rate 高一样停
        defer { player.pause() }

        // 时间轴总长 8.5s（3 + 3s@0.5x=6 - 0.5 重叠），4 倍速约 2.2s 播完，给 10s 富余
        var stalledAt: TimeInterval?
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(50))
            let t = player.currentTime().seconds
            if player.rate == 0, t > 0.5, t < 8.3 {
                stalledAt = t
                break
            }
            if t >= 8.4 { break }  // 播到末尾，未停
        }

        XCTAssertNil(stalledAt, "播放停在时间轴 \(stalledAt ?? -1)s 处（预期一路播到 8.5s 末尾）")
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 8.4,
                                    "应播到接近末尾，实际停在 \(player.currentTime().seconds)s")
    }

    /// renderSize 微扰的判定逻辑（全平台）：有轨道尺寸 == renderSize 才微扰，否则不动。
    @MainActor
    func testRenderSizeEqualityBreakOnlyAppliesWhenMatching() async throws {
        let tallURL = workDir.appendingPathComponent("tall.mp4")
        try AssetSynthesizer.writeSolidColorVideo(to: tallURL, color: CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1),
                                                  seconds: 4, width: 1080, height: 1920)
        let tallID = UUID()
        func makePlan(secondClipAsset: UUID) -> EditPlan {
            EditPlan(
                assets: [
                    AssetItem(id: SamplePlan.assetID1, kind: .video, fileName: "clip1.mp4",
                              origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                    AssetItem(id: tallID, kind: .video, fileName: "tall.mp4",
                              origin: .synthesized, duration: 4.0, pixelWidth: 1080, pixelHeight: 1920, hasAudio: false),
                ],
                clips: [
                    PlanClip(assetID: SamplePlan.assetID1, range: 0...3,
                             transitionAfter: .dissolve(duration: 0.5)),
                    PlanClip(assetID: secondClipAsset, range: 0...3),
                ]
            )
        }

        // 含 1080x1920（== renderSize）素材 → renderSize 被微扰
        let matched = try await PreviewBridge.makePreview(for: makePlan(secondClipAsset: tallID), resolver: resolver)
        XCTAssertEqual(matched.playerItem.videoComposition?.renderSize.width ?? 0, 1080.5, accuracy: 0.001)

        // 纯 720p 素材 → renderSize 不动
        let plain = try await PreviewBridge.makePreview(for: makePlan(secondClipAsset: SamplePlan.assetID1), resolver: resolver)
        XCTAssertEqual(plain.playerItem.videoComposition?.renderSize.width ?? 0, 1080, accuracy: 0.001)
    }

    #if os(iOS)
    /// 关键回归：分辨率 == renderSize 的素材 + 转场，挂真实 AVPlayerLayer 播放过边界。
    /// 无显示输出的裸 AVPlayer 不跑 videoComposition 渲染，复现不了——必须有 Layer。
    @MainActor
    func testTransitionPlaybackWithRenderSizeMatchingAsset() async throws {
        // 合成一段 1080x1920（恰等于 reelsAndShorts renderSize）素材
        let tallURL = workDir.appendingPathComponent("tall.mp4")
        try AssetSynthesizer.writeSolidColorVideo(to: tallURL, color: CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1),
                                                  seconds: 4, width: 1080, height: 1920)
        let tallID = UUID()
        let plan = EditPlan(
            assets: [
                AssetItem(id: SamplePlan.assetID1, kind: .video, fileName: "clip1.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1280, pixelHeight: 720, hasAudio: false),
                AssetItem(id: tallID, kind: .video, fileName: "tall.mp4",
                          origin: .synthesized, duration: 4.0, pixelWidth: 1080, pixelHeight: 1920, hasAudio: false),
            ],
            clips: [
                PlanClip(assetID: SamplePlan.assetID1, range: 0...3,
                         transitionAfter: .dissolve(duration: 0.5)),
                PlanClip(assetID: tallID, range: 0...3),
            ]
        )

        let package = try await PreviewBridge.makePreview(for: plan, resolver: resolver)
        let player = AVPlayer(playerItem: package.playerItem)

        var failError: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem, queue: .main
        ) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            failError = err.map { "\($0.localizedDescription) underlying=\(($0.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0)" }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = window.rootViewController!.view.bounds
        window.rootViewController!.view.layer.addSublayer(playerLayer)
        playerLayer.player = player

        player.rate = 1
        defer { player.pause(); window.isHidden = true }

        // 时间轴 5.5s（3 + 3 - 0.5），转场段 [2.5, 3.0]；1x 实速播，播过 4s 即过转场
        var stalledAt: TimeInterval?
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(50))
            let t = player.currentTime().seconds
            if player.rate == 0, t > 0.5, t < 5.2 {
                stalledAt = t
                break
            }
            if t >= 4.0 { break }
        }

        XCTAssertNil(stalledAt,
                     "播放停在 t=\(stalledAt ?? -1)（identity-transform 直通路径回归）\(failError.map { "，失败错误: \($0)" } ?? "")")
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 4.0)
    }
    #endif
}
