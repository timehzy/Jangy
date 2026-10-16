import XCTest
import CoreGraphics
@testable import JangyCore

final class TimelineFilmstripTests: XCTestCase {
    private let laneHeight: CGFloat = 56

    // MARK: 格宽

    func testCellWidthFollowsAssetAspectRatio() {
        // 横屏 16:9 → 车道高 × 宽高比，画面不裁切
        let w = TimelineFilmstrip.cellWidth(laneHeight: laneHeight, aspectRatio: 16.0 / 9.0)
        XCTAssertEqual(w, laneHeight * 16.0 / 9.0, accuracy: 0.01)
    }

    func testCellWidthClampsExtremeAspectRatios() {
        let narrow = TimelineFilmstrip.cellWidth(laneHeight: laneHeight, aspectRatio: 9.0 / 16.0)
        XCTAssertEqual(narrow, TimelineFilmstrip.minCellWidth, "竖屏素材夹到下限")
        let wide = TimelineFilmstrip.cellWidth(laneHeight: laneHeight, aspectRatio: 21.0 / 9.0)
        XCTAssertEqual(wide, TimelineFilmstrip.maxCellWidth, "超宽画幅夹到上限")
    }

    func testCellWidthFallsBackWhenAspectRatioUnknown() {
        // 探测失败（pixelWidth/Height 为 nil）不能算出 NaN / 0 宽
        for bad in [nil, 0, -2, CGFloat.nan] as [CGFloat?] {
            let w = TimelineFilmstrip.cellWidth(laneHeight: laneHeight, aspectRatio: bad)
            XCTAssertEqual(w, laneHeight * TimelineFilmstrip.fallbackAspectRatio, accuracy: 0.01)
        }
    }

    // MARK: 格划分

    func testCellsTileElementWithGlobalIndices() {
        // pps 60、格宽 100 → 每格 5/3 s；10s 元素铺 6 格
        let cells = TimelineFilmstrip.cells(start: 0, duration: 10, pointsPerSecond: 60,
                                            cellWidth: 100, window: 0...100)
        XCTAssertEqual(cells.map(\.index), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(cells.map(\.x), [0, 100, 200, 300, 400, 500])
        XCTAssertEqual(cells[1].outputOffset, 2.5, accuracy: 0.001)   // 格 [1.667, 3.333] 中点
        XCTAssertEqual(cells[5].outputOffset, 9.1667, accuracy: 0.001) // 末格被元素尾部截断
    }

    func testCellOffsetsStayInsideElement() {
        // 末格中点被元素尾部截断——用整格中点会越过元素末尾，抽帧落到源区间之外
        let cells = TimelineFilmstrip.cells(start: 0, duration: 5.2, pointsPerSecond: 60,
                                            cellWidth: 100, window: 0...100)
        XCTAssertTrue(cells.allSatisfy { $0.outputOffset > 0 && $0.outputOffset < 5.2 })
    }

    func testCellIndicesAreStableWhenWindowMoves() {
        // 窗口平移后，同一物理位置的格索引与 x 不变——视图身份才稳定、才不重取缩略图
        let first = TimelineFilmstrip.cells(start: 0, duration: 60, pointsPerSecond: 60,
                                            cellWidth: 100, window: 0...10)
        let second = TimelineFilmstrip.cells(start: 0, duration: 60, pointsPerSecond: 60,
                                             cellWidth: 100, window: 4...14)
        let byIndex = Dictionary(uniqueKeysWithValues: second.map { ($0.index, $0) })
        let overlap = first.filter { byIndex[$0.index] != nil }
        XCTAssertFalse(overlap.isEmpty)
        for cell in overlap {
            XCTAssertEqual(cell, byIndex[cell.index]!, "同一格索引必须给出同一格")
        }
    }

    func testCellsOnlyCoverWindowIntersection() {
        // 10s 元素、窗口只落在 [4, 6]：只建与之相交的格
        let cells = TimelineFilmstrip.cells(start: 0, duration: 10, pointsPerSecond: 60,
                                            cellWidth: 100, window: 4...6)
        XCTAssertEqual(cells.map(\.index), [2, 3])
    }

    func testCellsAccountForElementStartOffset() {
        // 元素起点在 20s：窗口按成片时间轴给，格索引仍从元素起点数起
        let cells = TimelineFilmstrip.cells(start: 20, duration: 10, pointsPerSecond: 60,
                                            cellWidth: 100, window: 20...22)
        XCTAssertEqual(cells.map(\.index), [0, 1])
        XCTAssertEqual(cells[0].x, 0)
    }

    func testCellCountIsBoundedByWindowNotElementLength() {
        // 长素材 × 大缩放：格数由窗口（一屏）决定，不随元素时长增长
        let cells = TimelineFilmstrip.cells(start: 0, duration: 300, pointsPerSecond: 480,
                                            cellWidth: 100, window: 0...0.8125)
        XCTAssertLessThanOrEqual(cells.count, 5)
    }

    func testCellsAreEmptyForDisjointWindowOrZeroDuration() {
        XCTAssertTrue(TimelineFilmstrip.cells(start: 0, duration: 10, pointsPerSecond: 60,
                                              cellWidth: 100, window: 30...40).isEmpty)
        XCTAssertTrue(TimelineFilmstrip.cells(start: 0, duration: 0, pointsPerSecond: 60,
                                              cellWidth: 100, window: 0...10).isEmpty)
    }

    func testCellOffsetsMapIntoSourceRangeThroughSpeed() {
        // 格中点 → 源时间必须落在源区间内（含变速）
        let clip = PlanClip(assetID: UUID(), source: .video(10...30), speed: .flat(2.0))
        let cells = TimelineFilmstrip.cells(start: 0, duration: clip.duration, pointsPerSecond: 60,
                                            cellWidth: 100, window: 0...100)
        XCTAssertFalse(cells.isEmpty)
        for cell in cells {
            let source = clip.sourceTime(forOutputOffset: cell.outputOffset)
            XCTAssertNotNil(source)
            XCTAssertTrue((10...30).contains(source!), "格中点 \(cell.outputOffset) → 源 \(source!) 越界")
        }
    }

    func testSameCellIndexMapsToDifferentSourceTimeWhenZoomChanges() {
        // 格索引**不是**帧的身份：索引 → 源时间的映射依赖 pps（缩放）与 clip 源区间。
        // 所以视图侧的帧缓存必须按源时间做键，按索引会在缩放 / trim 后错位（同一索引指向另一帧）。
        let clip = PlanClip(assetID: UUID(), source: .video(0...10), speed: .flat(1.0))
        let atDefault = TimelineFilmstrip.cells(start: 0, duration: 10, pointsPerSecond: 60,
                                                cellWidth: 100, window: 0...10)
        let zoomedIn = TimelineFilmstrip.cells(start: 0, duration: 10, pointsPerSecond: 240,
                                               cellWidth: 100, window: 0...10)
        let a = atDefault.first { $0.index == 1 }
        let b = zoomedIn.first { $0.index == 1 }
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a!.outputOffset, b!.outputOffset, accuracy: 0.001,
                          "同一格索引在缩放后必须指向另一帧")
    }
}
