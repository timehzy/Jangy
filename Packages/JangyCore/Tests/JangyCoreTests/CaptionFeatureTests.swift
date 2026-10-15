import XCTest
@testable import JangyCore

final class CaptionFeatureTests: XCTestCase {

    func testCueRoundTripsAsTrackPayload() throws {
        let cue = CaptionCuePayload(text: "第一段：开场", duration: 2.5)
        let payload = TrackPayload(cue)
        XCTAssertEqual(payload.payloadType, "caption-cue")
        XCTAssertEqual(payload.duration, 2.5, accuracy: 0.0001)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(TrackPayload.self, from: data)
        XCTAssertEqual(decoded.value as? CaptionCuePayload, cue)
    }

    func testSettingsRoundTrip() throws {
        let sourceID = UUID()
        let settings = CaptionTrackSettings(fontSize: 48, isBold: true, isEnabled: true,
                                            sourceAssetID: sourceID)
        let payload = TrackPayload(settings)
        XCTAssertEqual(payload.payloadType, "caption-settings")
        XCTAssertEqual(payload.duration, 0, "轨级参数不占时间线")
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(TrackPayload.self, from: data).value as? CaptionTrackSettings,
                       settings)
    }

    func testSettingsFallsBackToDefaultsWhenMissing() {
        let track = PlanTrack(kind: .caption, placement: .absolute)
        XCTAssertEqual(CaptionFeature.settings(of: track), CaptionTrackSettings())
    }

    func testValidateRejectsCueBeyondMainTrackEnd() {
        let cue = PlanElement(at: 4, content: .content(TrackPayload(
            CaptionCuePayload(text: "越界", duration: 3))))
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [cue])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 5, tracks: [track])
        let issues = CaptionFeature.validate(track: track, context: context)
        XCTAssertTrue(issues.contains { $0.message.contains("超出主轨末端") })
        XCTAssertEqual(issues.first?.elementID, cue.id)
    }

    func testValidateRejectsAbsoluteElementWithoutAt() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(content: .content(TrackPayload(CaptionCuePayload(text: "x", duration: 1)))),
        ])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("必须带 at") })
    }

    func testValidateRejectsUnregisteredSourceAsset() {
        let track = PlanTrack(kind: .caption, placement: .absolute,
                              settings: TrackPayload(CaptionTrackSettings(sourceAssetID: UUID())))
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("引用了未登记的字幕素材") })
    }

    func testIssuePathUsesTrackIndex() {
        // path 是给人/Agent 读的 JSON 字段路径，轨道段用下标（机器定位走 elementID）
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(content: .content(TrackPayload(CaptionCuePayload(text: "x", duration: 1)))),
        ])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        let issues = CaptionFeature.validate(track: track, context: context)
        XCTAssertEqual(issues.first?.path, "tracks[0].elements[0].at",
                       "轨道段与元素段都应是下标，且下标正确解析（不是回落 ?）")
    }

    func testRegistryKnowsAllPayloadTypes() {
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("clip"))
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("caption-cue"))
        XCTAssertTrue(TrackFeatureRegistry.payloadCodecs.keys.contains("caption-settings"))
    }

    func testValidateRejectsNonAbsolutePlacement() {
        // 字幕轨必须是绝对定位；链式轨会让「元素自带 at」的整套语义失效
        let track = PlanTrack(kind: .caption, placement: .chained, elements: [])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("必须是绝对定位") })
    }

    func testValidateRejectsNegativeAt() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: -1, content: .content(TrackPayload(
                CaptionCuePayload(text: "负起点", duration: 1)))),
        ])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("字幕起点不能为负") })
    }

    func testValidateRejectsNonPositiveDuration() {
        let track = PlanTrack(kind: .caption, placement: .absolute, elements: [
            PlanElement(at: 1, content: .content(TrackPayload(
                CaptionCuePayload(text: "零时长", duration: 0)))),
        ])
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("字幕时长必须为正") })
    }

    func testValidateRejectsSourceAssetOfWrongKind() {
        // 这条的旧实现（EditPlanValidator 的 captions 分支）连同它的测试会被 Task 6 删掉，
        // 届时这里是唯一实现——必须现在钉住
        let videoAssetID = UUID()
        let track = PlanTrack(kind: .caption, placement: .absolute,
                              settings: TrackPayload(CaptionTrackSettings(sourceAssetID: videoAssetID)))
        let context = TrackValidationContext(
            assets: [AssetItem(id: videoAssetID, kind: .video, fileName: "v.mp4")],
            mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("字幕来源必须是字幕素材") })
    }

    func testValidateRejectsWrongTypedSettingsPayload() {
        // settings 类型不对会让来源素材检查被静默跳过，必须显式上报
        let track = PlanTrack(kind: .caption, placement: .absolute,
                              settings: TrackPayload(CaptionCuePayload(text: "放错地方了", duration: 1)))
        let context = TrackValidationContext(assets: [], mainTrackEnd: 10, tracks: [track])
        XCTAssertTrue(CaptionFeature.validate(track: track, context: context)
            .contains { $0.message.contains("settings payload 类型不对") })
    }
}
