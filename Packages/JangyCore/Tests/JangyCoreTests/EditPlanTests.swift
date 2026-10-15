import XCTest
@testable import JangyCore

final class EditPlanTests: XCTestCase {

    private static let videoID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private static let videoID2 = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
    private static let srtID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-0000000000f1")!

    private func makePlan() -> EditPlan {
        let primary = PlanTrack(kind: .video, placement: .chained, elements: [
            PlanElement(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: Self.videoID,
                            source: .video(0...3), speed: .flat(1.0),
                            transitionAfter: .dissolve(duration: 0.5))))),
            PlanElement(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        content: .content(TrackPayload(PlanClip(
                            assetID: Self.videoID2,
                            source: .video(0...3), speed: .flat(0.5))))),
        ])
        let captionTrack = PlanTrack(kind: .caption, placement: .absolute,
                                     settings: TrackPayload(CaptionTrackSettings(
                                        fontSize: 48, isBold: true, isEnabled: true,
                                        sourceAssetID: Self.srtID)))
        return EditPlan(
            assets: [
                AssetItem(id: Self.videoID, kind: .video, fileName: "clip1.mp4", duration: 4.0),
                AssetItem(id: Self.videoID2, kind: .video, fileName: "clip2.mp4", duration: 4.0),
                AssetItem(id: Self.srtID, kind: .subtitle, fileName: "sample.srt"),
            ],
            tracks: [primary, captionTrack], primaryTrackID: primary.id,
            preset: .reelsAndShorts
        )
    }

    func testRoundTrip() throws {
        let plan = makePlan()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }

    func testDefaultVersionIs4() {
        XCTAssertEqual(makePlan().version, 4)
    }

    func testAssetLookup() {
        let plan = makePlan()
        XCTAssertEqual(plan.asset(withID: Self.videoID)?.fileName, "clip1.mp4")
        XCTAssertNil(plan.asset(withID: UUID()))
    }

    func testSpeedRateAccessor() {
        XCTAssertEqual(SpeedPlan.flat(0.5).rate, 0.5)
    }

    func testTransitionDurationAccessor() {
        XCTAssertEqual(PlanTransition.dissolve(duration: 0.5).duration, 0.5)
        XCTAssertEqual(PlanTransition.fade(duration: 0.3).duration, 0.3)
    }

    /// Agent 手写的极简 v3 JSON（省略 clip 的 id/speed/transitionAfter、省略 preset/captions）
    /// 经 PlanLoader 迁移后落回默认值。v4 的 EditPlan 是严格解码，极简形状走 v3 迁移入口。
    func testDecodesMinimalLegacyJSONViaLoader() throws {
        let json = """
        {
          "version": 3,
          "assets": [
            { "id": "aaaaaaaa-0000-0000-0000-000000000001", "kind": "video", "fileName": "clip1.mp4" }
          ],
          "clips": [
            {
              "assetID": "aaaaaaaa-0000-0000-0000-000000000001",
              "range": [0, 3]
            }
          ]
        }
        """
        let plan = try PlanLoader.decode(Data(json.utf8), assetsDirectory: nil).plan
        XCTAssertEqual(plan.version, 4)
        XCTAssertEqual(plan.preset, .reelsAndShorts)
        XCTAssertEqual(plan.tracks.count, 1, "无字幕轨")
        XCTAssertEqual(plan.assets.count, 1)
        XCTAssertEqual(plan.assets[0].displayName, "clip1.mp4")   // 缺省回落 fileName
        XCTAssertEqual(plan.assets[0].origin, .files)             // 缺省 .files
        XCTAssertNil(plan.assets[0].duration)
        let clip = plan.primaryTrack?.elements.first?.content.clipPayload
        XCTAssertEqual(clip?.assetID, Self.videoID)
        XCTAssertEqual(clip?.source, .video(0...3))
        XCTAssertEqual(clip?.speed, .flat(1.0))
        XCTAssertNil(clip?.transitionAfter)
    }

    /// 素材登记表是 v2 新增的可选字段：省略时解码为空表（Agent 渐进式采用）。
    func testDecodesLegacyWithoutAssetsTable() throws {
        let json = """
        { "version": 3, "clips": [ { "assetID": "aaaaaaaa-0000-0000-0000-000000000001", "range": [0, 3] } ] }
        """
        let plan = try PlanLoader.decode(Data(json.utf8), assetsDirectory: nil).plan
        XCTAssertTrue(plan.assets.isEmpty)
        XCTAssertNil(plan.asset(withID: Self.videoID))
    }

    func testSpeedPlanWireFormat() throws {
        struct Wrapper: Codable { var speed: SpeedPlan }
        let data = try JSONEncoder().encode(Wrapper(speed: .flat(0.5)))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"type\":\"flat\""), "got: \(json)")
        XCTAssertTrue(json.contains("\"rate\":0.5"), "got: \(json)")

        let decoded = try JSONDecoder().decode(SpeedPlan.self,
                                               from: Data("{\"type\":\"flat\",\"rate\":0.5}".utf8))
        XCTAssertEqual(decoded, .flat(0.5))
    }

    func testPlanTransitionWireFormat() throws {
        struct Wrapper: Codable { var transition: PlanTransition }
        let data = try JSONEncoder().encode(Wrapper(transition: .dissolve(duration: 0.5)))
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"type\":\"dissolve\""), "got: \(json)")
        XCTAssertTrue(json.contains("\"duration\":0.5"), "got: \(json)")

        let decoded = try JSONDecoder().decode(PlanTransition.self,
                                               from: Data("{\"type\":\"dissolve\",\"duration\":0.5}".utf8))
        XCTAssertEqual(decoded, .dissolve(duration: 0.5))
    }

    func testUnknownEnumTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SpeedPlan.self,
                                     from: Data("{\"type\":\"warp\",\"rate\":1}".utf8))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("warp"))
        }
    }

    func testPlanClipSourceWireFormat() throws {
        struct Wrapper: Codable { var source: PlanClipSource }
        let videoJSON = String(decoding: try JSONEncoder().encode(Wrapper(source: .video(0...3))), as: UTF8.self)
        XCTAssertTrue(videoJSON.contains("\"type\":\"video\""), "got: \(videoJSON)")
        XCTAssertTrue(videoJSON.contains("\"range\":[0,3]"), "got: \(videoJSON)")

        let stillJSON = String(decoding: try JSONEncoder().encode(Wrapper(source: .still(duration: 2.5))), as: UTF8.self)
        XCTAssertTrue(stillJSON.contains("\"type\":\"still\""), "got: \(stillJSON)")
        XCTAssertTrue(stillJSON.contains("\"duration\":2.5"), "got: \(stillJSON)")

        XCTAssertEqual(try JSONDecoder().decode(PlanClipSource.self,
                                                from: Data(#"{"type":"still","duration":2.5}"#.utf8)),
                       .still(duration: 2.5))
    }

    /// v2 旧 clip（只有 range）宽容解码为 .video(range)。
    func testDecodesLegacyRangeField() throws {
        let json = #"{"assetID":"aaaaaaaa-0000-0000-0000-000000000001","range":[1,2.5]}"#
        let clip = try JSONDecoder().decode(PlanClip.self, from: Data(json.utf8))
        XCTAssertEqual(clip.source, .video(1...2.5))
    }

    func testUnknownClipSourceTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(PlanClipSource.self,
                                     from: Data(#"{"type":"gif","duration":1}"#.utf8))
        ) { error in
            XCTAssertTrue(String(describing: error).contains("gif"))
        }
    }

    func testRoundTripWithStillClip() throws {
        let imageID = UUID()
        let plan = PlanTestSupport.plan(
            assets: [AssetItem(id: imageID, kind: .image, fileName: "p.png", pixelWidth: 100, pixelHeight: 100)],
            clips: [PlanClip(assetID: imageID, source: .still(duration: 2.5))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoded = try JSONDecoder().decode(EditPlan.self, from: encoder.encode(plan))
        XCTAssertEqual(decoded, plan)
    }
}
