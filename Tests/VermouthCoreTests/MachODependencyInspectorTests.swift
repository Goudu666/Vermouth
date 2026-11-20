import Foundation
import XCTest
@testable import VermouthCore

/// 自定义引擎缺 `@rpath` 依赖（Sikarugir `wswine.bundle` 缺 `libinotify.0.dylib`）的回归测试。
final class MachODependencyInspectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-macho-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    func testParsesDylibWeakDylibAndRpathCommands() throws {
        let data = Self.makeMachO(
            dylibs: ["@rpath/libinotify.0.dylib", "/usr/lib/libSystem.B.dylib"],
            weakDylibs: ["@rpath/libweak.dylib"],
            rpaths: ["@loader_path/../lib"]
        )
        let info = try XCTUnwrap(MachODependencyInspector.parse(data))
        XCTAssertEqual(info.requiredDylibs, ["@rpath/libinotify.0.dylib", "/usr/lib/libSystem.B.dylib"])
        XCTAssertEqual(info.weakDylibs, ["@rpath/libweak.dylib"])
        XCTAssertEqual(info.rpaths, ["@loader_path/../lib"])

        // fat 包装（优先 x86_64 切片）
        let fat = Self.wrapInFat(data)
        XCTAssertEqual(MachODependencyInspector.parse(fat), info)

        XCTAssertNil(MachODependencyInspector.parse(Data("#!/bin/sh\n".utf8)))
    }

    #if os(macOS)
    func testParsesRealSystemBinary() throws {
        let info = try XCTUnwrap(MachODependencyInspector.loadInfo(atPath: "/bin/ls"))
        XCTAssertTrue(info.requiredDylibs.contains("/usr/lib/libSystem.B.dylib"))
    }
    #endif

    func testRegisterCustomEngineRejectsMissingRpathDylibAndListsIt() async throws {
        let root = tempDir.appendingPathComponent("wswine.bundle", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)

        // 与真实 wswine.bundle 一致：wineserver 依赖 @rpath/libinotify.0.dylib，rpath 为 @loader_path/../lib；
        // ntdll.so 依赖弱库（缺失不算错）以及经主程序 rpath 才能解析的库
        try Self.makeMachO(dylibs: ["/usr/lib/libSystem.B.dylib"], rpaths: ["@loader_path/../lib/external"])
            .write(to: root.appendingPathComponent("bin/wine"))
        try Self.makeMachO(
            dylibs: ["@rpath/libinotify.0.dylib", "/usr/lib/libSystem.B.dylib"],
            rpaths: ["@loader_path/../lib"]
        ).write(to: root.appendingPathComponent("bin/wineserver"))
        try Self.makeMachO(
            dylibs: ["@rpath/libgnutls.30.dylib"],
            weakDylibs: ["@rpath/libMoltenVK.dylib"],
            rpaths: ["@loader_path/"]
        ).write(to: root.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"))
        try fm.createDirectory(at: root.appendingPathComponent("lib/external"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("lib/external/libgnutls.30.dylib"))

        let paths = VermouthPaths(baseDirectory: tempDir.appendingPathComponent("home", isDirectory: true))
        try paths.ensureBaseDirectories()
        let manager = EngineManager(
            paths: paths,
            commandRunner: MockCommandRunner(defaultResult: CommandResult(exitCode: 0, stdout: "wine-10.0\n", stderr: "")),
            systemProber: MockSystemProber(),
            candidateRoots: []
        )

        do {
            _ = try await manager.registerCustomEngine(name: "Sikarugir Wine 10", rootPath: root.path)
            XCTFail("Expected invalidEngineRoot for missing libinotify")
        } catch let VermouthError.invalidEngineRoot(_, reason) {
            XCTAssertTrue(reason.contains("bin/wineserver → @rpath/libinotify.0.dylib"), reason)
            XCTAssertFalse(reason.contains("libgnutls"), reason)
            XCTAssertFalse(reason.contains("libMoltenVK"), reason)
        }
        let enginesAfterRejection = try await manager.listEngines()
        XCTAssertTrue(enginesAfterRejection.isEmpty)

        // 补上缺的库后可以登记
        try Data().write(to: root.appendingPathComponent("lib/libinotify.0.dylib"))
        let engine = try await manager.registerCustomEngine(name: "Sikarugir Wine 10", rootPath: root.path)
        XCTAssertEqual(engine.source, .custom)
    }

    // MARK: - Mach-O Fixture Builders

    private static func makeMachO(dylibs: [String], weakDylibs: [String] = [], rpaths: [String] = []) -> Data {
        var commands: [UInt8] = []
        var count: UInt32 = 0
        func append(cmd: UInt32, string: String, stringOffset: UInt32) {
            var body = Array(string.utf8) + [0]
            let headerSize = Int(stringOffset)
            while (headerSize + body.count) % 8 != 0 { body.append(0) }
            let size = UInt32(headerSize + body.count)
            var command = le(cmd) + le(size) + le(stringOffset)
            command += [UInt8](repeating: 0, count: headerSize - command.count)
            commands += command + body
            count += 1
        }
        for dylib in dylibs { append(cmd: 0xC, string: dylib, stringOffset: 24) }
        for dylib in weakDylibs { append(cmd: 0x8000_0018, string: dylib, stringOffset: 24) }
        for rpath in rpaths { append(cmd: 0x8000_001C, string: rpath, stringOffset: 12) }

        // mach_header_64: magic, cputype(x86_64), cpusubtype, filetype(MH_EXECUTE), ncmds, sizeofcmds, flags, reserved
        let header = le(0xFEED_FACF) + le(0x0100_0007) + le(3) + le(2) + le(count) + le(UInt32(commands.count)) + le(0) + le(0)
        return Data(header + commands)
    }

    private static func wrapInFat(_ thin: Data) -> Data {
        let offset: UInt32 = 4096
        // fat_header + 一个 arm64 占位切片 + x86_64 切片，均为大端
        var bytes = be(0xCAFE_BABE) + be(2)
        bytes += be(0x0100_000C) + be(0) + be(offset) + be(8) + be(12)
        bytes += be(0x0100_0007) + be(3) + be(offset * 2) + be(UInt32(thin.count)) + be(12)
        bytes += [UInt8](repeating: 0, count: Int(offset) - bytes.count)
        bytes += [0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0]
        bytes += [UInt8](repeating: 0, count: Int(offset * 2) - bytes.count)
        return Data(bytes) + thin
    }

    private static func le(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private static func be(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}
