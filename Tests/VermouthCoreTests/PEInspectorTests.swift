import Foundation
import XCTest
@testable import VermouthCore

final class PEInspectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-pe-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Valid PE Binaries

    func testInspectPE32Executable() throws {
        let data = makePEBinary(
            machine: 0x014C,
            characteristics: 0x0102,
            optionalMagic: 0x010B,
            subsystem: 2
        )

        let memoryResult = try PEInspector.inspect(data: data, path: "app32.exe")
        XCTAssertEqual(memoryResult.path, "app32.exe")
        XCTAssertEqual(memoryResult.architecture, .x86_32)
        XCTAssertFalse(memoryResult.isDLL)
        XCTAssertEqual(memoryResult.subsystem, 2)

        let fileURL = try writeTempFile(named: "app32.exe", data: data)
        let fileResult = try PEInspector.inspect(fileAtPath: fileURL.path)
        XCTAssertEqual(fileResult.path, fileURL.path)
        XCTAssertEqual(fileResult.architecture, .x86_32)
        XCTAssertFalse(fileResult.isDLL)
        XCTAssertEqual(fileResult.subsystem, 2)
    }

    func testInspectPE32PlusExecutable() throws {
        let data = makePEBinary(
            machine: 0x8664,
            characteristics: 0x0022,
            optionalMagic: 0x020B,
            subsystem: 3
        )

        let fileURL = try writeTempFile(named: "cli64.exe", data: data)
        let result = try PEInspector.inspect(fileAtPath: fileURL.path)

        XCTAssertEqual(result.path, fileURL.path)
        XCTAssertEqual(result.architecture, .x86_64)
        XCTAssertFalse(result.isDLL)
        XCTAssertEqual(result.subsystem, 3)
    }

    func testInspect64BitDLL() throws {
        let data = makePEBinary(
            machine: 0x8664,
            characteristics: 0x2022, // IMAGE_FILE_DLL (0x2000) | IMAGE_FILE_LARGE_ADDRESS_AWARE | EXECUTABLE_IMAGE
            optionalMagic: 0x020B,
            subsystem: 2
        )

        let fileURL = try writeTempFile(named: "d3d11.dll", data: data)
        let result = try PEInspector.inspect(fileAtPath: fileURL.path)

        XCTAssertEqual(result.architecture, .x86_64)
        XCTAssertTrue(result.isDLL)
        XCTAssertEqual(result.subsystem, 2)
    }

    func testInspectARM64Executable() throws {
        let data = makePEBinary(
            machine: 0xAA64,
            characteristics: 0x0022,
            optionalMagic: 0x020B,
            subsystem: 2
        )

        let fileURL = try writeTempFile(named: "arm64app.exe", data: data)
        let result = try PEInspector.inspect(fileAtPath: fileURL.path)

        XCTAssertEqual(result.architecture, .arm64)
        XCTAssertFalse(result.isDLL)
        XCTAssertEqual(result.subsystem, 2)
    }

    func testInspectUnknownMachineFallsBackToOptionalHeaderMagic() throws {
        let pe32Fallback = makePEBinary(
            machine: 0x0000,
            optionalMagic: 0x010B,
            subsystem: 2
        )
        let res32 = try PEInspector.inspect(data: pe32Fallback)
        XCTAssertEqual(res32.architecture, .x86_32)

        let pe64Fallback = makePEBinary(
            machine: 0x0000,
            optionalMagic: 0x020B,
            subsystem: 3
        )
        let res64 = try PEInspector.inspect(data: pe64Fallback)
        XCTAssertEqual(res64.architecture, .x86_64)

        let unknownBoth = makePEBinary(
            machine: 0x0000,
            optionalMagic: 0x9999,
            subsystem: 0
        )
        let resUnknown = try PEInspector.inspect(data: unknownBoth)
        XCTAssertEqual(resUnknown.architecture, .unknown)

        let noOptionalHeader = makePEBinary(
            machine: 0x8664,
            optionalMagic: nil,
            sizeOfOptionalHeader: 0,
            subsystem: 0
        )
        let resNoOpt = try PEInspector.inspect(data: noOptionalHeader)
        XCTAssertEqual(resNoOpt.architecture, .x86_64)
        XCTAssertEqual(resNoOpt.subsystem, 0)
    }

    func testInspectELfanewBeyond64KBUsesFileSeekFallback() throws {
        // Place PE header past the 65,536-byte initial read window (0x12000 = 73,728 bytes).
        let data = makePEBinary(
            eLfanew: 0x0001_2000,
            machine: 0x8664,
            characteristics: 0x0022,
            optionalMagic: 0x020B,
            subsystem: 3
        )
        XCTAssertGreaterThan(data.count, 65_536)

        let fileURL = try writeTempFile(named: "large-dos-stub.exe", data: data)
        let result = try PEInspector.inspect(fileAtPath: fileURL.path)

        XCTAssertEqual(result.architecture, .x86_64)
        XCTAssertFalse(result.isDLL)
        XCTAssertEqual(result.subsystem, 3)
    }

    func testInspectELfanewStraddling64KBBoundaryUsesFileSeekFallback() throws {
        // Case 1: PE signature + COFF header itself straddles the 65,536-byte boundary (at 65,520).
        let coffStraddle = makePEBinary(
            eLfanew: 65_520,
            machine: 0x014C,
            characteristics: 0x2102,
            optionalMagic: 0x010B,
            subsystem: 2
        )
        let coffFileURL = try writeTempFile(named: "boundary-straddle-coff.dll", data: coffStraddle)
        let coffResult = try PEInspector.inspect(fileAtPath: coffFileURL.path)

        XCTAssertEqual(coffResult.architecture, .x86_32)
        XCTAssertTrue(coffResult.isDLL)
        XCTAssertEqual(coffResult.subsystem, 2)

        // Case 2: COFF fits within 64KB (65,500 + 24 = 65,524), while optional header subsystem spills past 65,536.
        let optStraddle = makePEBinary(
            eLfanew: 65_500,
            machine: 0x8664,
            characteristics: 0x0022,
            optionalMagic: 0x020B,
            subsystem: 3
        )
        let optFileURL = try writeTempFile(named: "boundary-straddle-opt.exe", data: optStraddle)
        let optResult = try PEInspector.inspect(fileAtPath: optFileURL.path)

        XCTAssertEqual(optResult.architecture, .x86_64)
        XCTAssertFalse(optResult.isDLL)
        XCTAssertEqual(optResult.subsystem, 3)
    }

    // MARK: - Negative & Malformed Cases

    func testInspectEmptyFileThrowsInvalidPEFile() throws {
        let emptyURL = try writeTempFile(named: "empty.exe", data: Data())

        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(), path: "empty.exe")
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: emptyURL.path)
        }
    }

    func testInspectNonMZDataThrowsInvalidPEFile() throws {
        // Mach-O 64-bit little-endian magic header
        var nonMZ = [UInt8](repeating: 0, count: 256)
        nonMZ[0] = 0xCF
        nonMZ[1] = 0xFA
        nonMZ[2] = 0xED
        nonMZ[3] = 0xFE

        let fileURL = try writeTempFile(named: "not-a-pe.bin", data: Data(nonMZ))
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: fileURL.path)
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(nonMZ))
        }
    }

    func testInspectTruncatedDOSHeaderThrowsInvalidPEFile() throws {
        var bytes = [UInt8](repeating: 0, count: 63)
        bytes[0] = 0x4D // 'M'
        bytes[1] = 0x5A // 'Z'

        let fileURL = try writeTempFile(named: "truncated-dos.exe", data: Data(bytes))
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: fileURL.path)
        }
    }

    func testInspectTruncatedCOFFHeaderThrowsInvalidPEFile() throws {
        // Valid 64-byte DOS header pointing to offset 0x40, followed by only 10 bytes (< 24 needed)
        var bytes = [UInt8](repeating: 0, count: 0x40 + 10)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        writeUInt32LE(0x40, into: &bytes, at: 0x3C)
        bytes[0x40] = 0x50 // 'P'
        bytes[0x41] = 0x45 // 'E'

        let fileURL = try writeTempFile(named: "truncated-coff.exe", data: Data(bytes))
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: fileURL.path)
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(bytes))
        }
    }

    func testInspectTruncatedOptionalHeaderMagicThrowsInvalidPEFile() throws {
        // Valid DOS + PE + COFF declaring SizeOfOptionalHeader = 224, but file ends right after COFF
        var bytes = [UInt8](repeating: 0, count: 0x80 + 24)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        writeUInt32LE(0x80, into: &bytes, at: 0x3C)
        bytes[0x80] = 0x50
        bytes[0x81] = 0x45
        bytes[0x82] = 0x00
        bytes[0x83] = 0x00
        writeUInt16LE(0x014C, into: &bytes, at: 0x80 + 4)
        writeUInt16LE(224, into: &bytes, at: 0x80 + 20)

        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(bytes))
        }
    }

    func testInspectBogusELfanewBeyondEOFThrowsInvalidPEFile() throws {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        writeUInt32LE(0x0010_0000, into: &bytes, at: 0x3C)

        let fileURL = try writeTempFile(named: "bogus-offset.exe", data: Data(bytes))
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: fileURL.path)
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(bytes))
        }

        // Extreme UInt32.max offset must also fail cleanly without integer overflow traps
        writeUInt32LE(UInt32.max, into: &bytes, at: 0x3C)
        let maxOffsetURL = try writeTempFile(named: "max-offset.exe", data: Data(bytes))
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: maxOffsetURL.path)
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: Data(bytes))
        }
    }

    func testInspectBadPESignatureThrowsInvalidPEFile() throws {
        let data = makePEBinary(
            peSignature: [0x4E, 0x45, 0x00, 0x00], // "NE\0\0" instead of "PE\0\0"
            machine: 0x014C,
            optionalMagic: 0x010B,
            subsystem: 2
        )

        let fileURL = try writeTempFile(named: "bad-sig.exe", data: data)
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(fileAtPath: fileURL.path)
        }
        assertThrowsInvalidPEFile {
            _ = try PEInspector.inspect(data: data)
        }
    }

    func testInspectMissingFileThrowsIOError() {
        let missingPath = tempDir.appendingPathComponent("does-not-exist.exe").path
        XCTAssertThrowsError(try PEInspector.inspect(fileAtPath: missingPath)) { error in
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

    func testInspectDirectoryPathThrowsVermouthErrorCleanly() throws {
        let dirURL = tempDir.appendingPathComponent("not-a-pe-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PEInspector.inspect(fileAtPath: dirURL.path)) { error in
            guard let vermouthError = error as? VermouthError else {
                XCTFail("Expected VermouthError when inspecting a directory path, got \(error)")
                return
            }
            switch vermouthError {
            case .ioError, .invalidPEFile:
                break
            default:
                XCTFail("Expected VermouthError.ioError or .invalidPEFile, got \(vermouthError)")
            }
        }
    }

    // MARK: - Binary Synthesis Helpers

    private func makePEBinary(
        eLfanew: UInt32 = 0x80,
        peSignature: [UInt8] = [0x50, 0x45, 0x00, 0x00],
        machine: UInt16,
        characteristics: UInt16 = 0x0002,
        optionalMagic: UInt16?,
        sizeOfOptionalHeader: UInt16? = nil,
        subsystem: UInt16 = 2
    ) -> Data {
        let resolvedOptSize: UInt16
        if let sizeOfOptionalHeader {
            resolvedOptSize = sizeOfOptionalHeader
        } else if optionalMagic == 0x010B {
            resolvedOptSize = 224
        } else if optionalMagic != nil {
            resolvedOptSize = 240
        } else {
            resolvedOptSize = 0
        }

        let peOffset = Int(eLfanew)
        let totalSize = peOffset + 24 + Int(resolvedOptSize)
        var bytes = [UInt8](repeating: 0, count: totalSize)

        // DOS header magic ("MZ") + e_lfanew
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        writeUInt32LE(eLfanew, into: &bytes, at: 0x3C)

        // PE signature ("PE\0\0")
        for (i, byte) in peSignature.prefix(4).enumerated() {
            bytes[peOffset + i] = byte
        }

        // COFF IMAGE_FILE_HEADER
        writeUInt16LE(machine, into: &bytes, at: peOffset + 4)
        writeUInt16LE(resolvedOptSize, into: &bytes, at: peOffset + 20)
        writeUInt16LE(characteristics, into: &bytes, at: peOffset + 22)

        // Optional header
        let optOffset = peOffset + 24
        if let optionalMagic, resolvedOptSize >= 2 {
            writeUInt16LE(optionalMagic, into: &bytes, at: optOffset)
        }
        if resolvedOptSize >= 70 {
            writeUInt16LE(subsystem, into: &bytes, at: optOffset + 68)
        }

        return Data(bytes)
    }

    private func writeTempFile(named name: String, data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func assertThrowsInvalidPEFile(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> Void
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let vermouthError = error as? VermouthError else {
                XCTFail("Expected VermouthError, got \(error)", file: file, line: line)
                return
            }
            guard case .invalidPEFile = vermouthError else {
                XCTFail("Expected VermouthError.invalidPEFile, got \(vermouthError)", file: file, line: line)
                return
            }
        }
    }

    private func writeUInt16LE(_ value: UInt16, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32LE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(truncatingIfNeeded: value)
        buffer[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buffer[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buffer[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
