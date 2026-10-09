import XCTest
@testable import POCCore

final class EditPlanValidatorTests: XCTestCase {

    private let validator = EditPlanValidator()
    private let videoID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private let videoID2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
    private let srtID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-0000000000f1")!

    /// 默认配套素材表：clip1/clip2 各 4s 视频 + sample.srt 字幕
    private func assets() -> [AssetItem] {
        [
            AssetItem(id: videoID, kind: .video, fileName: "clip1.mp4", duration: 4.0),
            AssetItem(id: videoID2, kind: .video, fileName: "clip2.mp4", duration: 4.0),
            AssetItem(id: srtID, kind: .subtitle, fileName: "sample.srt"),
        ]
    }

    private func clip(_ range: ClosedRange<TimeInterval> = 0...3,
                      speed: SpeedPlan = .flat(1.0),
                      transition: PlanTransition? = nil,
                      assetID: UUID? = nil) -> PlanClip {
        PlanClip(assetID: assetID ?? videoID, range: range, speed: speed, transitionAfter: transition)
    }

    private func plan(clips: [PlanClip], assets: [AssetItem]? = nil,
                      captions: CaptionTrack? = nil) -> EditPlan {
        EditPlan(assets: assets ?? self.assets(), clips: clips, captions: captions)
    }

    func testValidPlanPasses() {
        let plan = plan(clips: [clip(transition: .dissolve(duration: 0.5)), clip(assetID: videoID2)])
        XCTAssertTrue(validator.validate(plan).isEmpty)
    }

    func testEmptyClips() {
        let issues = validator.validate(EditPlan(clips: []))
        XCTAssertEqual(issues, [ValidationIssue(path: "clips", message: "至少需要一个片段")])
    }

    func testDanglingAssetReference() {
        let unknown = UUID()
        let issues = validator.validate(plan(clips: [clip(assetID: unknown)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].assetID"])
    }

    func testClipRejectsNonVideoAsset() {
        let audioID = UUID()
        let table = [AssetItem(id: audioID, kind: .audio, fileName: "bgm.mp3", duration: 30)]
        let issues = validator.validate(plan(clips: [clip(assetID: audioID)], assets: table))
        XCTAssertEqual(issues.map(\.path), ["clips[0].assetID"])
    }

    func testRangeBeyondAssetDuration() {
        // 素材 4s，裁剪到 5s 越界；容差内（4.04s）放行
        XCTAssertEqual(validator.validate(plan(clips: [clip(0...5)])).map(\.path), ["clips[0].range"])
        XCTAssertTrue(validator.validate(plan(clips: [clip(0...4.04)])).isEmpty)
    }

    func testRangeCheckSkippedWhenDurationUnknown() {
        let noMeta = [AssetItem(id: videoID, kind: .video, fileName: "clip1.mp4")]
        XCTAssertTrue(validator.validate(plan(clips: [clip(0...99)], assets: noMeta)).isEmpty)
    }

    func testDuplicateAssetIDs() {
        var table = assets()
        table.append(table[0])
        let issues = validator.validate(plan(clips: [clip()], assets: table))
        XCTAssertEqual(issues.map(\.path), ["assets[3].id"])
    }

    func testNegativeRangeStart() {
        let issues = validator.validate(plan(clips: [clip(-1...3)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testEmptyRange() {
        let issues = validator.validate(plan(clips: [clip(2...2)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testSpeedOutOfBounds() {
        XCTAssertEqual(validator.validate(plan(clips: [clip(speed: .flat(0.1))])).map(\.path), ["clips[0].speed"])
        XCTAssertEqual(validator.validate(plan(clips: [clip(speed: .flat(5.0))])).map(\.path), ["clips[0].speed"])
    }

    func testDanglingTransitionOnLastClip() {
        let issues = validator.validate(plan(clips: [clip(transition: .dissolve(duration: 0.5))]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testTransitionLongerThanNeighbor() {
        // clip0 裁后 1s，转场 2s 超过它
        let issues = validator.validate(plan(clips: [clip(0...1, transition: .dissolve(duration: 2)), clip(assetID: videoID2)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testTransitionFitUsesPostSpeedDuration() {
        // clip0 裁剪 2s @2x → 变速后 1s；dissolve 1.5s。
        // 变速前判断会放行（2 >= 1.5），但 Kadr CompositionBuilder 按变速后时长检查，
        // 导出期会抛 invalidTransition——校验器必须提前拦截。
        let issues = validator.validate(plan(clips: [
            clip(0...2, speed: .flat(2.0), transition: .dissolve(duration: 1.5)),
            clip(0...3, assetID: videoID2),
        ]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testCaptionMustBeSRT() {
        let vttID = UUID()
        let table = assets() + [AssetItem(id: vttID, kind: .subtitle, fileName: "a.vtt")]
        let plan = plan(clips: [clip()], assets: table,
                        captions: CaptionTrack(assetID: vttID, isEnabled: true,
                                               style: CaptionStyle(fontSize: 48, isBold: true)))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["captions.assetID"])
    }

    func testCaptionRejectsNonSubtitleAsset() {
        let plan = plan(clips: [clip()],
                        captions: CaptionTrack(assetID: videoID2, isEnabled: true,
                                               style: CaptionStyle(fontSize: 48, isBold: true)))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["captions.assetID"])
    }

    func testCaptionDanglingAssetReference() {
        let plan = plan(clips: [clip()],
                        captions: CaptionTrack(assetID: UUID(), isEnabled: true,
                                               style: CaptionStyle(fontSize: 48, isBold: true)))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["captions.assetID"])
    }

    func testCollectsAllIssuesAtOnce() {
        let plan = plan(clips: [clip(speed: .flat(99)), clip(5...5, assetID: videoID2)])
        XCTAssertEqual(validator.validate(plan).count, 2)
    }

    func testAssetExistence() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data().write(to: dir.appendingPathComponent("clip1.mp4"))
        let resolver = AssetResolver(directory: dir)
        // 登记表 3 条目中 clip2.mp4 / sample.srt 未落盘
        let issues = validator.validateAssets(plan(clips: [clip()]), resolver: resolver)
        XCTAssertEqual(issues.map(\.path), ["assets[1].fileName", "assets[2].fileName"])
    }
}
