import Foundation
import XCTest
@testable import VermouthCore

final class ShellLinkParserTests: XCTestCase {
    private var tempDir: URL!

    private static let validCLSID: [UInt8] = [
        0x01, 0x14, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x46,
    ]

    private static let flagHasLinkTargetIDList: UInt32 = 1 << 0
    private static let flagHasLinkInfo: UInt32 = 1 << 1
    private static let flagHasName: UInt32 = 1 << 2
    private static let flagHasRelativePath: UInt32 = 1 << 3
    private static let flagHasWorkingDir: UInt32 = 1 << 4
    private static let flagHasArguments: UInt32 = 1 << 5
    private static let flagHasIconLocation: UInt32 = 1 << 6
    private static let flagIsUnicode: UInt32 = 1 << 7

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-lnk-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Valid MS-SHLLINK Binaries

    func testParseUnicodeShortcutWithIDListLinkInfoAndStringData() throws {
        let flags: UInt32 =
            Self.flagHasLinkTargetIDList
            | Self.flagHasLinkInfo
            | Self.flagHasName
            | Self.flagHasWorkingDir
            | Self.flagHasArguments
            | Self.flagHasIconLocation
            | Self.flagIsUnicode

        var bytes = makeHeader(linkFlags: flags)

        // LinkTargetIDList: synthetic item ID + 0x0000 terminator
        let idListPayload: [UInt8] = [0x0A, 0x00, 0x1F, 0x50, 0xE0, 0x4F, 0xD0, 0x20, 0xEA, 0x3A, 0x00, 0x00]
        appendUInt16LE(UInt16(idListPayload.count), to: &bytes)
        bytes.append(contentsOf: idListPayload)

        // LinkInfo with Unicode LocalBasePath + CommonPathSuffix (plus ANSI placeholders verifying Unicode precedence)
        let linkInfo = makeUnicodeLinkInfo(
            ansiLocalBasePath: "C:\\Fallback\\ANSI",
            ansiCommonPathSuffix: "old.exe",
            unicodeLocalBasePath: "C:\\Program Files\\中文游戏",
            unicodeCommonPathSuffix: "bin\\GameLauncher.exe"
        )
        bytes.append(contentsOf: linkInfo)

        // StringData in strict MS-SHLLINK §2.4 order: Name, WorkingDir, Arguments, IconLocation
        appendStringData("启动测试游戏", isUnicode: true, to: &bytes)
        appendStringData("C:\\Program Files\\中文游戏\\bin", isUnicode: true, to: &bytes)
        appendStringData("-windowed -lang zh", isUnicode: true, to: &bytes)
        appendStringData("C:\\Program Files\\中文游戏\\bin\\GameLauncher.exe", isUnicode: true, to: &bytes)

        let data = Data(bytes)
        let memoryInfo = try ShellLinkParser.parse(data: data, path: "game.lnk")
        XCTAssertEqual(memoryInfo.targetPath, "C:\\Program Files\\中文游戏\\bin\\GameLauncher.exe")
        XCTAssertEqual(memoryInfo.description, "启动测试游戏")
        XCTAssertEqual(memoryInfo.workingDirectory, "C:\\Program Files\\中文游戏\\bin")
        XCTAssertEqual(memoryInfo.arguments, "-windowed -lang zh")

        let fileURL = try writeTempFile(named: "game.lnk", data: data)
        let fileInfo = try ShellLinkParser.parse(fileAtPath: fileURL.path)
        XCTAssertEqual(fileInfo, memoryInfo)
    }

    func testParseANSIShortcutWithLinkInfoAndArguments() throws {
        let flags: UInt32 = Self.flagHasLinkInfo | Self.flagHasArguments

        var bytes = makeHeader(linkFlags: flags)
        bytes.append(
            contentsOf: makeANSILinkInfo(
                localBasePath: "C:\\Games\\GTASA\\gta_sa.exe",
                commonPathSuffix: nil
            )
        )
        appendStringData("-fullscreen -skipintro", isUnicode: false, to: &bytes)

        let fileURL = try writeTempFile(named: "gtasa.lnk", data: Data(bytes))
        let info = try ShellLinkParser.parse(fileAtPath: fileURL.path)

        XCTAssertEqual(info.targetPath, "C:\\Games\\GTASA\\gta_sa.exe")
        XCTAssertEqual(info.arguments, "-fullscreen -skipintro")
        XCTAssertNil(info.workingDirectory)
        XCTAssertNil(info.description)
    }

    func testParseRelativePathOnlyFallbackWithoutLinkInfo() throws {
        let flags: UInt32 = Self.flagHasRelativePath | Self.flagHasWorkingDir | Self.flagIsUnicode

        var bytes = makeHeader(linkFlags: flags)
        appendStringData("..\\Tools\\ModManager.exe", isUnicode: true, to: &bytes)
        appendStringData("..\\Tools", isUnicode: true, to: &bytes)

        let fileURL = try writeTempFile(named: "relative.lnk", data: Data(bytes))
        let info = try ShellLinkParser.parse(fileAtPath: fileURL.path)

        XCTAssertEqual(info.targetPath, "..\\Tools\\ModManager.exe")
        XCTAssertEqual(info.workingDirectory, "..\\Tools")
        XCTAssertNil(info.arguments)
        XCTAssertNil(info.description)
    }

    func testLinkInfoCombinesPathSeparatorsWithoutDuplicateBackslash() throws {
        let flags: UInt32 = Self.flagHasLinkInfo | Self.flagIsUnicode
        var bytes = makeHeader(linkFlags: flags)
        bytes.append(
            contentsOf: makeUnicodeLinkInfo(
                unicodeLocalBasePath: "C:\\Apps\\Tool\\",
                unicodeCommonPathSuffix: "\\bin\\tool.exe"
            )
        )

        let info = try ShellLinkParser.parse(data: Data(bytes))
        XCTAssertEqual(info.targetPath, "C:\\Apps\\Tool\\bin\\tool.exe")
    }

    func testOutOfBoundsInternalLinkInfoFieldOffsetsDoNotTrapAndFallBackCleanly() throws {
        // LinkInfoSize is valid (40 bytes), but internal string offsets exceed LinkInfoSize.
        // Parser must safely ignore out-of-bounds internal offsets without crashing and fall back to RelativePath.
        let flags: UInt32 = Self.flagHasLinkInfo | Self.flagHasRelativePath | Self.flagIsUnicode
        var bytes = makeHeader(linkFlags: flags)

        var linkInfo = [UInt8](repeating: 0, count: 40)
        writeUInt32LE(40, into: &linkInfo, at: 0)          // LinkInfoSize
        writeUInt32LE(0x24, into: &linkInfo, at: 4)        // LinkInfoHeaderSize
        writeUInt32LE(0x01, into: &linkInfo, at: 8)        // VolumeIDAndLocalBasePath
        writeUInt32LE(500, into: &linkInfo, at: 16)        // LocalBasePathOffset out of LinkInfo bounds
        writeUInt32LE(600, into: &linkInfo, at: 24)        // CommonPathSuffixOffset out of LinkInfo bounds
        writeUInt32LE(UInt32.max, into: &linkInfo, at: 28) // LocalBasePathOffsetUnicode overflow
        writeUInt32LE(40, into: &linkInfo, at: 32)         // CommonPathSuffixOffsetUnicode == linkInfoSize
        bytes.append(contentsOf: linkInfo)

        appendStringData(".\\fallback.exe", isUnicode: true, to: &bytes)

        let info = try ShellLinkParser.parse(data: Data(bytes))
        XCTAssertEqual(info.targetPath, ".\\fallback.exe")
    }

    // MARK: - Negative & Malformed Cases

    func testParseTooSmallFileThrowsInvalidShellLink() throws {
        let emptyURL = try writeTempFile(named: "empty.lnk", data: Data())
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(fileAtPath: emptyURL.path)
        }
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(repeating: 0, count: 75))
        }
    }

    func testParseBadHeaderSizeThrowsInvalidShellLink() {
        var bytes = makeHeader(linkFlags: 0)
        writeUInt32LE(0x0000_0050, into: &bytes, at: 0) // Expected 0x0000004C

        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(bytes))
        }

        writeUInt32LE(0, into: &bytes, at: 0)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(bytes))
        }
    }

    func testParseWrongCLSIDThrowsInvalidShellLink() {
        var bytes = makeHeader(linkFlags: 0)
        bytes[4] ^= 0xFF // Corrupt first byte of LinkCLSID

        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(bytes))
        }

        bytes = makeHeader(linkFlags: 0)
        bytes[19] = 0x47 // Corrupt last byte of LinkCLSID (expected 0x46)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(bytes))
        }
    }

    func testParseTruncatedIDListThrowsInvalidShellLink() {
        // Case 1: Only 1 byte present for 2-byte IDListSize field
        var truncatedSize = makeHeader(linkFlags: Self.flagHasLinkTargetIDList)
        truncatedSize.append(0x10)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(truncatedSize))
        }

        // Case 2: IDListSize claims 100 bytes, only 12 bytes follow
        var truncatedPayload = makeHeader(linkFlags: Self.flagHasLinkTargetIDList)
        appendUInt16LE(100, to: &truncatedPayload)
        truncatedPayload.append(contentsOf: [UInt8](repeating: 0xAA, count: 12))
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(truncatedPayload))
        }
    }

    func testParseOutOfBoundsLinkInfoSizeThrowsInvalidShellLink() {
        // Case 1: Missing LinkInfoSize bytes altogether
        let missingLinkInfo = makeHeader(linkFlags: Self.flagHasLinkInfo)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(missingLinkInfo))
        }

        // Case 2: LinkInfoSize < 4
        var tooSmallLinkInfo = makeHeader(linkFlags: Self.flagHasLinkInfo)
        appendUInt32LE(2, to: &tooSmallLinkInfo)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(tooSmallLinkInfo))
        }

        // Case 3: LinkInfoSize exceeds remaining file buffer
        var oversizedLinkInfo = makeHeader(linkFlags: Self.flagHasLinkInfo)
        appendUInt32LE(1024, to: &oversizedLinkInfo)
        oversizedLinkInfo.append(contentsOf: [UInt8](repeating: 0, count: 24))
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(oversizedLinkInfo))
        }

        // Case 4: LinkInfoSize == UInt32.max (must not overflow)
        var maxLinkInfo = makeHeader(linkFlags: Self.flagHasLinkInfo)
        appendUInt32LE(UInt32.max, to: &maxLinkInfo)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(maxLinkInfo))
        }
    }

    func testParseTruncatedStringDataThrowsInvalidShellLink() {
        // Missing StringData character count
        let missingCount = makeHeader(linkFlags: Self.flagHasName | Self.flagIsUnicode)
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(missingCount))
        }

        // CountCharacters = 20 UTF-16 chars (40 bytes required), only 8 bytes present
        var truncatedPayload = makeHeader(linkFlags: Self.flagHasName | Self.flagIsUnicode)
        appendUInt16LE(20, to: &truncatedPayload)
        truncatedPayload.append(contentsOf: [UInt8](repeating: 0x41, count: 8))
        assertThrowsInvalidShellLink {
            _ = try ShellLinkParser.parse(data: Data(truncatedPayload))
        }
    }

    func testParseMissingFileThrowsIOError() {
        let missingPath = tempDir.appendingPathComponent("missing.lnk").path
        XCTAssertThrowsError(try ShellLinkParser.parse(fileAtPath: missingPath)) { error in
            guard let vermouthError = error as? VermouthError else {
                XCTFail("Expected VermouthError, got \(error)")
                return
            }
            guard case .ioError = vermouthError else {
                XCTFail("Expected VermouthError.ioError, got \(vermouthError)")
                return
            }
        }
    }

    // MARK: - MS-SHLLINK Binary Synthesis Helpers

    private func makeHeader(linkFlags: UInt32) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 76)
        writeUInt32LE(0x0000_004C, into: &header, at: 0)
        for (i, byte) in Self.validCLSID.enumerated() {
            header[4 + i] = byte
        }
        writeUInt32LE(linkFlags, into: &header, at: 20)
        return header
    }

    private func makeANSILinkInfo(localBasePath: String?, commonPathSuffix: String?) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 28)
        writeUInt32LE(0x1C, into: &buffer, at: 4) // LinkInfoHeaderSize = 28
        writeUInt32LE(0x01, into: &buffer, at: 8) // VolumeIDAndLocalBasePath

        if let localBasePath {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 16)
            buffer.append(contentsOf: localBasePath.utf8)
            buffer.append(0x00)
        }

        if let commonPathSuffix {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 24)
            buffer.append(contentsOf: commonPathSuffix.utf8)
            buffer.append(0x00)
        }

        writeUInt32LE(UInt32(buffer.count), into: &buffer, at: 0)
        return buffer
    }

    private func makeUnicodeLinkInfo(
        ansiLocalBasePath: String? = nil,
        ansiCommonPathSuffix: String? = nil,
        unicodeLocalBasePath: String?,
        unicodeCommonPathSuffix: String?
    ) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 36)
        writeUInt32LE(0x24, into: &buffer, at: 4) // LinkInfoHeaderSize = 36 (extended Unicode header)
        writeUInt32LE(0x01, into: &buffer, at: 8) // VolumeIDAndLocalBasePath

        if let ansiLocalBasePath {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 16)
            buffer.append(contentsOf: ansiLocalBasePath.utf8)
            buffer.append(0x00)
        }

        if let ansiCommonPathSuffix {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 24)
            buffer.append(contentsOf: ansiCommonPathSuffix.utf8)
            buffer.append(0x00)
        }

        if let unicodeLocalBasePath {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 28)
            buffer.append(contentsOf: encodeUTF16LE(unicodeLocalBasePath))
            buffer.append(contentsOf: [0x00, 0x00])
        }

        if let unicodeCommonPathSuffix {
            let offset = UInt32(buffer.count)
            writeUInt32LE(offset, into: &buffer, at: 32)
            buffer.append(contentsOf: encodeUTF16LE(unicodeCommonPathSuffix))
            buffer.append(contentsOf: [0x00, 0x00])
        }

        writeUInt32LE(UInt32(buffer.count), into: &buffer, at: 0)
        return buffer
    }

    private func appendStringData(_ value: String, isUnicode: Bool, to buffer: inout [UInt8]) {
        if isUnicode {
            let encoded = encodeUTF16LE(value)
            appendUInt16LE(UInt16(value.utf16.count), to: &buffer)
            buffer.append(contentsOf: encoded)
        } else {
            let encoded = Array(value.utf8)
            appendUInt16LE(UInt16(encoded.count), to: &buffer)
            buffer.append(contentsOf: encoded)
        }
    }

    private func encodeUTF16LE(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf16.count * 2)
        for unit in string.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return bytes
    }

    private func writeTempFile(named name: String, data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertThrowsInvalidShellLink(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> Void
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let vermouthError = error as? VermouthError else {
                XCTFail("Expected VermouthError, got \(error)", file: file, line: line)
                return
            }
            guard case .invalidShellLink = vermouthError else {
                XCTFail("Expected VermouthError.invalidShellLink, got \(vermouthError)", file: file, line: line)
                return
            }
        }
    }

    private func appendUInt16LE(_ value: UInt16, to buffer: inout [UInt8]) {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendUInt32LE(_ value: UInt32, to buffer: inout [UInt8]) {
        buffer.append(UInt8(truncatingIfNeeded: value))
        buffer.append(UInt8(truncatingIfNeeded: value >> 8))
        buffer.append(UInt8(truncatingIfNeeded: value >> 16))
        buffer.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func writeUInt32LE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
