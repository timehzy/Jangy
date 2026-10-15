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
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "第一段：开场")
        XCTAssertEqual(cues[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 2.5, accuracy: 0.001)
        XCTAssertEqual(cues[1].text, "第二段：中景")
        XCTAssertEqual(cues[1].start, 2.5, accuracy: 0.001)
    }

    func testJoinsMultilineText() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\n第一行\n第二行\n\n"
        XCTAssertEqual(SRTParser.parse(srt).first?.text, "第一行\n第二行")
    }

    func testToleratesDotMillisecondSeparatorAndCRLF() {
        let srt = "1\r\n00:00:01.000 --> 00:00:02.000\r\n你好\r\n\r\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].duration, 1.0, accuracy: 0.001)
    }

    func testSkipsMalformedBlocks() {
        let srt = "garbage without timeline\n\n1\n00:00:01,000 --> 00:00:02,000\n有效\n\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "有效")
    }

    func testEmptyInputGivesNoCues() {
        XCTAssertTrue(SRTParser.parse("").isEmpty)
    }
}
