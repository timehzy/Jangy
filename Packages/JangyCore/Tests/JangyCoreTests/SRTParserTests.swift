import XCTest
@testable import JangyCore

final class SRTParserTests: XCTestCase {

    func testParsesBasicCues() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,500
        第一段：开场

        2
        00:00:02,500 --> 00:00:05,000
        第二段：中景

        """
        let cues = SRTParser.parse(srt).cues
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "第一段：开场")
        XCTAssertEqual(cues[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 2.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "第二段：中景")
        XCTAssertEqual(cues[1].start, 2.5, accuracy: 0.001)
    }

    func testJoinsMultilineText() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\n第一行\n第二行\n\n"
        XCTAssertEqual(SRTParser.parse(srt).cues.first?.text, "第一行\n第二行")
    }

    func testToleratesDotMillisecondSeparatorAndCRLF() {
        let srt = "1\r\n00:00:01.000 --> 00:00:02.000\r\n你好\r\n\r\n"
        let cues = SRTParser.parse(srt).cues
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 1.0, accuracy: 0.001)
    }

    func testSkipsMalformedBlocks() {
        let srt = "garbage without timeline\n\n1\n00:00:01,000 --> 00:00:02,000\n有效\n\n"
        let cues = SRTParser.parse(srt).cues
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "有效")
    }

    func testEmptyInputGivesNoCues() {
        XCTAssertTrue(SRTParser.parse("").cues.isEmpty)
    }

    /// I1：时间轴行尾追加的定位坐标（YouTube / ASR 工具常见）不能导致整条 cue 被丢弃。
    func testParsesCueWithPositioningCoordinates() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000 X1:100 X2:200 Y1:300 Y2:400\n带定位\n\n"
        let cues = SRTParser.parse(srt).cues
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "带定位")
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 1.0, accuracy: 0.001)
    }

    /// I2：坏块被跳过，但跳过多少要能被调用方看见。
    func testCountsSkippedMalformedBlocks() {
        let srt = "garbage without timeline\n\n1\n00:00:01,000 --> 00:00:02,000\n有效\n\n"
        let result = SRTParser.parse(srt)
        XCTAssertEqual(result.cues.count, 1)
        XCTAssertEqual(result.skippedBlocks, 1)
    }

    /// I2：纯空块（多空行 / 末尾换行产生的）不算「被跳过的坏块」。
    func testDoesNotCountPureEmptyBlocksAsSkipped() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n你好\n\n\n\n"
        let result = SRTParser.parse(srt)
        XCTAssertEqual(result.cues.count, 1)
        XCTAssertEqual(result.skippedBlocks, 0)
    }

    /// M1：与旧路径（`Kadr.Caption.load(srt:)`）一致——标签原样保留，不做 markup 处理。
    func testKeepsMarkupTagsVerbatim() {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n<i>斜体</i>{\\an8}\n\n"
        XCTAssertEqual(SRTParser.parse(srt).cues.first?.text, "<i>斜体</i>{\\an8}")
    }
}
