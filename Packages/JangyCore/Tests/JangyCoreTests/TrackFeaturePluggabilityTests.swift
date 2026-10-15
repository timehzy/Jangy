import XCTest
@testable import JangyCore

/// 第四类轨（贴纸轨空壳）。它只存在于本测试文件里——payload + 特性片 + 一次注入，
/// 核心的编解码、校验分派、不变式就全部正确工作。
/// 这就是注册表的验收标准：**加一类轨不需要改核心的任何 switch / if 分支**。
struct StickerPayload: Codable, Equatable, Sendable, TrackElementPayload {
    static let payloadType = "sticker"
    var imageName: String
    var duration: TimeInterval
}

enum StickerFeature: TrackFeature {
    static let kind = TrackKind(rawValue: "sticker")
    static let payloadTypes: [any TrackElementPayload.Type] = [StickerPayload.self]

    static func validate(track: PlanTrack, context: TrackValidationContext) -> [ValidationIssue] {
        track.elements.compactMap { element in
            guard case .content(let payload) = element.content,
                  let sticker = payload.value as? StickerPayload,
                  sticker.imageName.isEmpty else { return nil }
            return ValidationIssue(path: context.pathPrefix(for: track), elementID: element.id,
                                   message: "贴纸缺图片名")
        }
    }
}

final class TrackFeaturePluggabilityTests: XCTestCase {

    override func tearDown() {
        TrackFeatureRegistry.testOnlyFeatures = []
        super.tearDown()
    }

    func testFourthTrackKindRoundTripsWithoutCoreChanges() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let stickerTrack = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                StickerPayload(imageName: "star.png", duration: 2)))),
        ])
        let plan = EditPlan(tracks: [primary, stickerTrack], primaryTrackID: primary.id)

        // 编解码：核心不知道 sticker 是什么，仍能往返
        let data = try JSONEncoder().encode(plan)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"sticker\""))
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testValidatorDispatchesUnknownKindToItsFeature() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let badSticker = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                StickerPayload(imageName: "", duration: 2)))),
        ])
        let plan = EditPlan(tracks: [primary, badSticker], primaryTrackID: primary.id)

        let issues = EditPlanValidator().validate(plan)
        XCTAssertTrue(issues.contains { $0.message.contains("贴纸缺图片名") },
                      "校验应分派给 StickerFeature，核心不需要认识 sticker")
    }

    func testCoreInvariantsApplyToUnknownKind() throws {
        TrackFeatureRegistry.testOnlyFeatures = [StickerFeature.self]

        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 3))])
        let stickerTrack = PlanTrack(kind: StickerFeature.kind, placement: .absolute, elements: [
            PlanElement(at: 6, content: .content(TrackPayload(
                StickerPayload(imageName: "star.png", duration: 2)))),
        ])
        var plan = EditPlan(tracks: [primary, stickerTrack], primaryTrackID: primary.id)

        TrackOperations.maintainInvariants(in: &plan)
        XCTAssertEqual(plan.primaryTrack!.span, 8, accuracy: 0.001,
                       "核心用通用规则处理未知轨：主轨自动补到 8s")
    }

    func testUnregisteredTrackKindIsRejectedByValidator() {
        let primary = PlanTrack(kind: .video, placement: .chained,
                                elements: [PlanElement(content: .gap(duration: 5))])
        let orphan = PlanTrack(kind: TrackKind(rawValue: "no-such-kind"), placement: .absolute)
        let plan = EditPlan(tracks: [primary, orphan], primaryTrackID: primary.id)

        let issues = EditPlanValidator().validate(plan)
        XCTAssertTrue(issues.contains { $0.message.contains("未注册的轨道类型") })
    }

    func testUnregisteredPayloadTypeIsRejectedByDecoder() {
        // 未注册的 payload 在解码期就报错（不静默丢弃）
        let json = #"{"type":"sticker","imageName":"a.png","duration":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPayload.self, from: json))
    }
}
