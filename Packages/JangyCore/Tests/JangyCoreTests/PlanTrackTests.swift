import XCTest
@testable import JangyCore

/// 测试用假 payload：只验证注册表的分发机制。
struct TestPingPayload: TrackElementPayload {
    static let payloadType = "test-ping"
    var value: Int
    var duration: TimeInterval { 1.0 }
}

final class PlanTrackTests: XCTestCase {

    /// 本测试类用到 `TestPingPayload` 的编解码，需先把承载它的假特性注入注册表；
    /// 逐用例 setUp 保证 `testTestOnlyFeatureInjectionReachesRegistry` 里 reset 后仍能复原。
    override func setUp() {
        super.setUp()
        TrackFeatureRegistry.testOnlyFeatures = [TestPingFeature.self]
    }

    override func tearDown() {
        TrackFeatureRegistry.testOnlyFeatures = []
        super.tearDown()
    }

    // MARK: 轨道与元素

    func testTrackKindIsOpenType() {
        let custom = TrackKind(rawValue: "sticker")
        XCTAssertEqual(custom.rawValue, "sticker")
        XCTAssertNotEqual(custom, .video)
    }

    func testChainedTrackDerivesSpanFromOrder() {
        let track = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(content: .gap(duration: 2)),
            PlanElement(content: .gap(duration: 3)),
        ])
        XCTAssertEqual(track.span, 5)
        XCTAssertNil(track.elements[0].at, "链式轨元素不带 at")
    }

    func testAbsoluteTrackSpanIsMaxOfEnds() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 1.0, content: .gap(duration: 2)),
            PlanElement(at: 4.0, content: .gap(duration: 1)),
        ])
        XCTAssertEqual(track.span, 5)
    }

    func testElementDurationComesFromContent() {
        XCTAssertEqual(PlanElement(content: .gap(duration: 1.5)).duration, 1.5)
        XCTAssertEqual(PlanElement(content: .content(TrackPayload(TestPingPayload(value: 1)))).duration, 1.0)
    }

    func testElementContentRoundTrips() throws {
        for content: ElementContent in [.gap(duration: 1.5), .content(TrackPayload(TestPingPayload(value: 7)))] {
            let data = try JSONEncoder().encode(content)
            XCTAssertEqual(try JSONDecoder().decode(ElementContent.self, from: data), content)
        }
    }

    func testUnknownContentTypeThrows() {
        let json = #"{"type":"no-such-content"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ElementContent.self, from: json))
    }

    // MARK: JSON 往返（CLI / Agent / 落盘的互操作契约）

    func testElementRoundTripsThroughJSON() throws {
        let element = PlanElement(at: 2.5, content: .content(TrackPayload(TestPingPayload(value: 9))))
        let data = try JSONEncoder().encode(element)
        XCTAssertEqual(try JSONDecoder().decode(PlanElement.self, from: data), element)
    }

    func testChainedElementOmitsAtFromJSON() throws {
        // chained 轨元素不带 at：nil 必须从 JSON 省略，避免「顺序 + at」两个事实源。
        let data = try JSONEncoder().encode(PlanElement(content: .gap(duration: 1)))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"at\""), "at 为 nil 时应从 JSON 省略；实际：\(json)")
    }

    func testTrackRoundTripsThroughJSON() throws {
        let track = PlanTrack(
            kind: .video, name: "主轨", placement: .chained,
            isMuted: true, isHidden: false, isLocked: true,
            settings: TrackPayload(TestPingPayload(value: 3)),
            elements: [
                PlanElement(content: .gap(duration: 2)),
                PlanElement(content: .content(TrackPayload(TestPingPayload(value: 5)))),
            ])
        let data = try JSONEncoder().encode(track)
        XCTAssertEqual(try JSONDecoder().decode(PlanTrack.self, from: data), track)
    }

    // MARK: payload 与注册表

    func testPayloadRoundTripsThroughRegisteredCodec() throws {
        let payload = TrackPayload(TestPingPayload(value: 7))
        XCTAssertEqual(payload.payloadType, "test-ping")
        XCTAssertEqual(payload.duration, 1.0)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? TestPingPayload, TestPingPayload(value: 7))
    }

    func testPayloadEqualityDistinguishesSameTypeDifferentValue() {
        // 同类型但值不等：走 isEqual(to:) 的「同类型不等」分支。
        XCTAssertNotEqual(TrackPayload(TestPingPayload(value: 1)),
                          TrackPayload(TestPingPayload(value: 2)))
        XCTAssertEqual(TrackPayload(TestPingPayload(value: 1)),
                       TrackPayload(TestPingPayload(value: 1)))
    }

    func testUnknownPayloadTypeThrowsAndListsRegistered() throws {
        let json = #"{"type":"no-such-payload"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPayload.self, from: json)) { error in
            XCTAssertTrue("\(error)".contains("已注册"), "报错应列出已注册类型，便于排查")
        }
    }

    func testRegistryIsStaticallyAssembledWithoutExternalInit() {
        // 注册表必须在 JangyCore 内部装配：headless CLI 不做任何初始化即可用。
        // 本步生产清单还是空的（Video/Caption 特性在后续任务加入），
        // 只断言「静态可读、不依赖任何外部初始化」。
        XCTAssertNotNil(TrackFeatureRegistry.payloadCodecs)
        XCTAssertNotNil(TrackFeatureRegistry.features)
    }

    func testTestOnlyFeatureInjectionReachesRegistry() {
        TrackFeatureRegistry.testOnlyFeatures = [TestPingFeature.self]
        defer { TrackFeatureRegistry.testOnlyFeatures = [] }

        XCTAssertEqual(TrackFeatureRegistry.payloadCodecs["test-ping"]?.payloadType, "test-ping")
        XCTAssertEqual(TrackFeatureRegistry.feature(for: TrackKind(rawValue: "test-ping-track"))?.kind,
                       TrackKind(rawValue: "test-ping-track"))
    }
}

/// 测试用假特性片。
enum TestPingFeature: TrackFeature {
    static let kind = TrackKind(rawValue: "test-ping-track")
    static let payloadTypes: [any TrackElementPayload.Type] = [TestPingPayload.self]
    static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] { [] }
}
