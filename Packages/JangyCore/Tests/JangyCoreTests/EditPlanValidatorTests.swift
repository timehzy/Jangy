import XCTest
@testable import JangyCore

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
        PlanClip(assetID: assetID ?? videoID, source: .video(range), speed: speed, transitionAfter: transition)
    }

    private func plan(clips: [PlanClip], assets: [AssetItem]? = nil,
                      captionSettings: CaptionTrackSettings? = nil) -> EditPlan {
        PlanTestSupport.plan(assets: assets ?? self.assets(), clips: clips,
                             captionSettings: captionSettings)
    }

    func testValidPlanPasses() {
        let plan = plan(clips: [clip(transition: .dissolve(duration: 0.5)), clip(assetID: videoID2)])
        XCTAssertTrue(validator.validate(plan).isEmpty)
    }

    func testEmptyClips() {
        let issues = validator.validate(PlanTestSupport.plan(clips: []))
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.message, "主轨至少需要一个元素")
    }

    func testDanglingAssetReference() {
        let unknown = UUID()
        let issues = validator.validate(plan(clips: [clip(assetID: unknown)]))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].assetID"])
    }

    func testClipRejectsNonVideoAsset() {
        let audioID = UUID()
        let table = [AssetItem(id: audioID, kind: .audio, fileName: "bgm.mp3", duration: 30)]
        let issues = validator.validate(plan(clips: [clip(assetID: audioID)], assets: table))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].assetID"])
    }

    func testRangeBeyondAssetDuration() {
        // 素材 4s，裁剪到 5s 越界；容差内（4.04s）放行
        XCTAssertEqual(validator.validate(plan(clips: [clip(0...5)])).map(\.path),
                       ["tracks[0].elements[0].source.range"])
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
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].source.range"])
    }

    func testEmptyRange() {
        let issues = validator.validate(plan(clips: [clip(2...2)]))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].source.range"])
    }

    func testSpeedOutOfBounds() {
        XCTAssertEqual(validator.validate(plan(clips: [clip(speed: .flat(0.1))])).map(\.path),
                       ["tracks[0].elements[0].speed"])
        XCTAssertEqual(validator.validate(plan(clips: [clip(speed: .flat(5.0))])).map(\.path),
                       ["tracks[0].elements[0].speed"])
    }

    func testDanglingTransitionOnLastClip() {
        let issues = validator.validate(plan(clips: [clip(transition: .dissolve(duration: 0.5))]))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].transitionAfter"])
    }

    func testTransitionLongerThanNeighbor() {
        // clip0 裁后 1s，转场 2s 超过它
        let issues = validator.validate(plan(clips: [clip(0...1, transition: .dissolve(duration: 2)), clip(assetID: videoID2)]))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].transitionAfter"])
    }

    func testTransitionFitUsesPostSpeedDuration() {
        // clip0 裁剪 2s @2x → 变速后 1s；dissolve 1.5s。
        // 变速前判断会放行（2 >= 1.5），但 Kadr CompositionBuilder 按变速后时长检查，
        // 导出期会抛 invalidTransition——校验器必须提前拦截。
        let issues = validator.validate(plan(clips: [
            clip(0...2, speed: .flat(2.0), transition: .dissolve(duration: 1.5)),
            clip(0...3, assetID: videoID2),
        ]))
        XCTAssertEqual(issues.map(\.path), ["tracks[0].elements[0].transitionAfter"])
    }

    /// 主轨必须是链式：绝对定位的主轨会让「元素位置由顺序推出」的整套语义失效。
    /// （原 captions 的 SRT 后缀检查随 v4 字幕逐句化移除——字幕来源约束已下沉到导入层。）
    func testPrimaryTrackMustBeChained() {
        let primary = PlanTrack(kind: .video, placement: .absolute, elements: [
            PlanElement(at: 0, content: .content(TrackPayload(clip()))),
        ])
        let plan = EditPlan(assets: assets(), tracks: [primary], primaryTrackID: primary.id)
        XCTAssertTrue(validator.validate(plan).contains { $0.message.contains("主轨必须是链式") })
    }

    func testCaptionRejectsNonSubtitleAsset() {
        let plan = plan(clips: [clip()],
                        captionSettings: CaptionTrackSettings(sourceAssetID: videoID2))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["tracks[1].settings.sourceAssetID"])
    }

    func testCaptionDanglingAssetReference() {
        let plan = plan(clips: [clip()],
                        captionSettings: CaptionTrackSettings(sourceAssetID: UUID()))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["tracks[1].settings.sourceAssetID"])
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

    func testStillClipIsValid() {
        let imageID = UUID()
        let table = [AssetItem(id: imageID, kind: .image, fileName: "p.png")]
        let clip = PlanClip(assetID: imageID, source: .still(duration: 3.0))
        XCTAssertTrue(validator.validate(plan(clips: [clip], assets: table)).isEmpty)
    }

    func testStillClipRejectsNonImageAsset() {
        // still 片段引用视频素材 → source 与 kind 不一致
        let clip = PlanClip(assetID: videoID, source: .still(duration: 3.0))
        XCTAssertEqual(validator.validate(plan(clips: [clip])).map(\.path), ["tracks[0].elements[0].assetID"])
    }

    func testVideoClipRejectsImageAsset() {
        let imageID = UUID()
        let table = [AssetItem(id: imageID, kind: .image, fileName: "p.png")]
        let clip = PlanClip(assetID: imageID, source: .video(0...3))
        XCTAssertEqual(validator.validate(plan(clips: [clip], assets: table)).map(\.path),
                       ["tracks[0].elements[0].assetID"])
    }

    func testStillDurationMustBePositive() {
        let imageID = UUID()
        let table = [AssetItem(id: imageID, kind: .image, fileName: "p.png")]
        let clip = PlanClip(assetID: imageID, source: .still(duration: 0))
        XCTAssertEqual(validator.validate(plan(clips: [clip], assets: table)).map(\.path),
                       ["tracks[0].elements[0].source.duration"])
    }

    func testStillClipWithTransitionIsValid() {
        let imageID = UUID()
        let table = [AssetItem(id: imageID, kind: .image, fileName: "p.png")]
        let clips = [
            PlanClip(assetID: imageID, source: .still(duration: 3.0), transitionAfter: .dissolve(duration: 0.5)),
            PlanClip(assetID: imageID, source: .still(duration: 3.0)),
        ]
        XCTAssertTrue(validator.validate(plan(clips: clips, assets: table)).isEmpty)
    }
}
