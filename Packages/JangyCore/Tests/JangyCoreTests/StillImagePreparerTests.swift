import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import JangyCore

/// 图片预合成：等比 aspect-fit 居中贴到画布黑底，消除 Kadr 的拉伸变形。
final class StillImagePreparerTests: XCTestCase {

    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    /// 造一张纯色 PNG（w×h 像素），返回文件 URL。
    private func makePNG(width: Int, height: Int, color: CGColor) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = workDir.appendingPathComponent("\(UUID().uuidString).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// 读 CGImage 上单点像素（RGBA，8bit）。
    private func pixel(_ cg: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = cg.width, h = cg.height
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { buf.deallocate() }
        let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let o = (y * w + x) * 4
        return (buf[o], buf[o + 1], buf[o + 2])
    }

    func testLetterboxesWideImageWithBlackBars() throws {
        // 200×100（2:1）纯红图 → 画布 1080×1920（9:16）。
        // aspect-fit：贴满宽 → 高 = 1080/2 = 540，居中于 y∈[690,1230]，上下为黑边。
        let url = try makePNG(width: 200, height: 100, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let cg = try XCTUnwrap(StillImagePreparer.prepareCGImage(url: url, canvas: CGSize(width: 1080, height: 1920)))
        XCTAssertEqual(cg.width, 1080)
        XCTAssertEqual(cg.height, 1920)

        let center = pixel(cg, x: 540, y: 960)
        XCTAssertGreaterThan(center.r, 200)
        XCTAssertLessThan(center.g, 60)
        XCTAssertLessThan(center.b, 60)
        // 顶部/底部黑边
        let top = pixel(cg, x: 540, y: 100)
        XCTAssertLessThan(top.r, 30)
        XCTAssertLessThan(top.g, 30)
        XCTAssertLessThan(top.b, 30)
        let bottom = pixel(cg, x: 540, y: 1820)
        XCTAssertLessThan(bottom.r, 30)
    }

    func testCanvasSizedImageFillsEntireFrame() throws {
        // 输入恰好等于画布宽高比：不留黑边（整帧红）。
        let url = try makePNG(width: 108, height: 192, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let cg = try XCTUnwrap(StillImagePreparer.prepareCGImage(url: url, canvas: CGSize(width: 1080, height: 1920)))
        let top = pixel(cg, x: 540, y: 20)
        XCTAssertGreaterThan(top.r, 200)
        XCTAssertLessThan(top.g, 60)
    }

    func testUndecodableFileReturnsNil() throws {
        let bogus = workDir.appendingPathComponent("not-an-image.txt")
        try Data("hello".utf8).write(to: bogus)
        XCTAssertNil(StillImagePreparer.prepareCGImage(url: bogus, canvas: CGSize(width: 1080, height: 1920)))
    }
}
