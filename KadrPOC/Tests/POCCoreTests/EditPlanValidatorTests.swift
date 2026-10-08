import XCTest
@testable import POCCore

final class EditPlanValidatorTests: XCTestCase {

    private let validator = EditPlanValidator()

    private func clip(_ range: ClosedRange<TimeInterval> = 0...3,
                      speed: SpeedPlan = .flat(1.0),
                      transition: PlanTransition? = nil,
                      source: String = "clip1.mp4") -> PlanClip {
        PlanClip(source: MediaRef(fileName: source), range: range, speed: speed, transitionAfter: transition)
    }

    func testValidPlanPasses() {
        let plan = EditPlan(clips: [clip(transition: .dissolve(duration: 0.5)), clip()])
        XCTAssertTrue(validator.validate(plan).isEmpty)
    }

    func testEmptyClips() {
        let issues = validator.validate(EditPlan(clips: []))
        XCTAssertEqual(issues, [ValidationIssue(path: "clips", message: "至少需要一个片段")])
    }

    func testNegativeRangeStart() {
        let issues = validator.validate(EditPlan(clips: [clip(-1...3)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testEmptyRange() {
        let issues = validator.validate(EditPlan(clips: [clip(2...2)]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].range"])
    }

    func testSpeedOutOfBounds() {
        XCTAssertEqual(validator.validate(EditPlan(clips: [clip(speed: .flat(0.1))])).map(\.path), ["clips[0].speed"])
        XCTAssertEqual(validator.validate(EditPlan(clips: [clip(speed: .flat(5.0))])).map(\.path), ["clips[0].speed"])
    }

    func testDanglingTransitionOnLastClip() {
        let issues = validator.validate(EditPlan(clips: [clip(transition: .dissolve(duration: 0.5))]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testTransitionLongerThanNeighbor() {
        // clip0 裁后 1s，转场 2s 超过它
        let issues = validator.validate(EditPlan(clips: [clip(0...1, transition: .dissolve(duration: 2)), clip()]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testTransitionFitUsesPostSpeedDuration() {
        // clip0 裁剪 2s @2x → 变速后 1s；dissolve 1.5s。
        // 变速前判断会放行（2 >= 1.5），但 Kadr CompositionBuilder 按变速后时长检查，
        // 导出期会抛 invalidTransition——校验器必须提前拦截。
        let issues = validator.validate(EditPlan(clips: [
            clip(0...2, speed: .flat(2.0), transition: .dissolve(duration: 1.5)),
            clip(0...3),
        ]))
        XCTAssertEqual(issues.map(\.path), ["clips[0].transitionAfter"])
    }

    func testCaptionSourceMustBeSRT() {
        let plan = EditPlan(clips: [clip()],
                            captions: CaptionTrack(source: MediaRef(fileName: "a.vtt"), isEnabled: true,
                                                   style: CaptionStyle(fontSize: 48, isBold: true)))
        XCTAssertEqual(validator.validate(plan).map(\.path), ["captions.source"])
    }

    func testCollectsAllIssuesAtOnce() {
        let plan = EditPlan(clips: [clip(speed: .flat(99)), clip(5...5)])
        XCTAssertEqual(validator.validate(plan).count, 2)
    }

    func testAssetExistence() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! Data().write(to: dir.appendingPathComponent("exists.mp4"))
        let resolver = AssetResolver(directory: dir)
        let plan = EditPlan(clips: [clip(source: "exists.mp4"), clip(source: "missing.mp4")])
        let issues = validator.validateAssets(plan, resolver: resolver)
        XCTAssertEqual(issues.map(\.path), ["clips[1].source"])
    }
}
