//
//  PageSizeReaderTests.swift
//  AidokuTests
//
//  SUWA-17 E4, E5: the size of a page from the header of an entry of a downloaded chapter (.cbz).
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
import ZIPFoundation

@testable import Aidoku

@Suite struct PageSizeReaderTests {
    private func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 255), UInt8(value >> 8 & 255), UInt8(value >> 16 & 255), UInt8(value >> 24 & 255)]
    }

    private func chunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
        Array(tag.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? [0] : [])
    }

    /// A WebP 1 px wide and 2 high whose EXIF (orientation 6: a quarter turn, shown 2 wide and 1 high) is at the
    /// end, after 64 KB of other data, as WebP puts it.
    private func webpWithOrientationAtTheEnd() -> Data {
        // a 1 x 2 lossless image (cwebp -lossless)
        let vp8l: [UInt8] = [0x2f, 0x00, 0x40, 0x00, 0x00, 0x07, 0x10, 0xfd, 0x8f, 0xfe, 0x07, 0x22, 0xa2, 0xff, 0x01]
        let tiff: [UInt8] = Array("II".utf8) + [42, 0] + le32(8) + [1, 0] + [0x12, 0x01, 3, 0] + le32(1) + [6, 0, 0, 0] + le32(0)
        // VP8X: EXIF present, canvas 1 x 2 (stored minus one)
        let vp8x = chunk("VP8X", [0x08, 0, 0, 0] + [0, 0, 0] + [1, 0, 0])
        let body = Array("WEBP".utf8) + vp8x + chunk("VP8L", vp8l)
            + chunk("ZPAD", [UInt8](repeating: 0, count: 64 * 1024)) + chunk("EXIF", tiff)
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pagesize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// E4: the EXIF of a WebP is at the end: read from the start of the archive entry, the page is either measured
    /// with its orientation (shown 2 wide, 1 high) or not measured (as before SUWA-17 C), never upright.
    @Test func aWebPWithItsOrientationAtTheEndIsNotMeasuredUpright() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("0.webp")
        try webpWithOrientationAtTheEnd().write(to: file)
        // the whole file: ImageIO sees the orientation
        let whole = try #require(PageSizeReader.ratio(fileURL: file))
        #expect(abs(whole - 0.5) < 0.01, "whole file \(whole)")
        let zip = folder.appendingPathComponent("c.cbz")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: "0.webp", relativeTo: folder, compressionMethod: .deflate)
        let fromEntry = PageSizeReader.ratio(archive: zip, path: "0.webp")
        #expect(fromEntry == nil || abs(fromEntry! - 0.5) < 0.01, "from the archive entry \(String(describing: fromEntry))")
    }
}
