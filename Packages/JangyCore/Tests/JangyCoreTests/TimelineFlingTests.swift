import XCTest
import CoreGraphics
@testable import JangyCore

final class TimelineFlingTests: XCTestCase {
    func testFlingThreshold() {
        XCTAssertFalse(TimelineFling(distance: TimelineFling.minDistance - 1).isFling)
        XCTAssertTrue(TimelineFling(distance: TimelineFling.minDistance).isFling)
        XCTAssertTrue(TimelineFling(distance: -200).isFling, "反向甩同样起惯性")
    }

    func testAdvanceSumConvergesToTotalDistance() {
        var fling = TimelineFling(distance: 400)
        var total: CGFloat = 0
        var ticks = 0
        while !fling.isAtRest, ticks < 600 {
            total += fling.advance(by: 1.0 / 60)
            ticks += 1
        }
        XCTAssertTrue(fling.isAtRest, "60Hz 推进 10s 内必须停稳")
        XCTAssertEqual(total, 400, accuracy: 1.0)
    }

    func testAdvanceIsDecreasingAndKeepsSign() {
        var fling = TimelineFling(distance: -400)
        var previous = CGFloat.greatestFiniteMagnitude
        for _ in 0..<8 {
            let step = fling.advance(by: 1.0 / 60)
            XCTAssertLessThan(step, 0, "位移方向与总行程一致")
            XCTAssertLessThan(abs(step), previous, "每拍位移应递减")
            previous = abs(step)
        }
        XCTAssertGreaterThan(previous, 0)
    }

    func testLongerDistanceTakesLonger() {
        // 同一条衰减曲线：行程越长，走得越久（时间常数与行程无关）
        var short = TimelineFling(distance: 100)
        var long = TimelineFling(distance: 1000)
        for _ in 0..<10 {
            short.advance(by: 1.0 / 60)
            long.advance(by: 1.0 / 60)
        }
        XCTAssertGreaterThan(abs(long.remaining), abs(short.remaining))
    }

    func testZeroDeltaTimeReturnsZero() {
        var fling = TimelineFling(distance: 400)
        XCTAssertEqual(fling.advance(by: 0), 0)
    }

    func testStartsAtRestWhenDistanceIsTiny() {
        XCTAssertTrue(TimelineFling(distance: 0.1).isAtRest)
    }

    func testHugeOrNegativeDeltaTimeDoesNotOvershoot() {
        // 系统休眠 / 时钟回拨等异常 dt：衰减饱和到 0，advance 最多走完剩余行程，不越界、不跑飞
        var fling = TimelineFling(distance: 400)
        XCTAssertEqual(fling.advance(by: 1000), 400, accuracy: 0.001)
        XCTAssertTrue(fling.isAtRest)
        XCTAssertEqual(fling.advance(by: -5), 0, "负 dt 视为 0")
    }
}
