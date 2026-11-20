import Foundation
import XCTest
@testable import VermouthCore

/// UI 展示层依赖的纯逻辑模型：Wine 日志级别识别与转译链路推导。
final class PresentationModelTests: XCTestCase {
    // MARK: - WineLogClassifier

    func testClassifiesStandardWineDebugLines() {
        let err = WineLogClassifier.classify("0024:err:module:import_dll Library vcruntime140.dll not found")
        XCTAssertEqual(err.level, .error)
        XCTAssertEqual(err.channel, "module")
        XCTAssertEqual(err.message, "import_dll Library vcruntime140.dll not found")

        XCTAssertEqual(WineLogClassifier.classify("00e4:warn:d3d:wined3d_adapter_init Something").level, .warning)
        XCTAssertEqual(WineLogClassifier.classify("0130:fixme:ntdll:NtQuerySystemInformation info_class").level, .fixme)
        XCTAssertEqual(WineLogClassifier.classify("0130:trace:loaddll:build_module Loaded L\"C:\\\\x.dll\"").level, .trace)
    }

    func testClassifiesTimestampedAndThreadlessFormatsAndKeepsColonsInMessage() {
        let stamped = WineLogClassifier.classify("1234.567:0024:err:ole:CoCreateInstance class {a:b} not registered")
        XCTAssertEqual(stamped.level, .error)
        XCTAssertEqual(stamped.channel, "ole")
        XCTAssertEqual(stamped.message, "CoCreateInstance class {a:b} not registered")

        let threadless = WineLogClassifier.classify("warn:seh:dispatch_exception code=c0000005")
        XCTAssertEqual(threadless.level, .warning)
        XCTAssertEqual(threadless.channel, "seh")
    }

    func testClassifiesMoltenVKAndFatalMessagesAndFallsBackToInfo() {
        XCTAssertEqual(WineLogClassifier.classify("[mvk-error] VK_ERROR_INITIALIZATION_FAILED").level, .error)
        XCTAssertEqual(WineLogClassifier.classify("[mvk-warn] Unsupported format").level, .warning)
        XCTAssertEqual(WineLogClassifier.classify("wine: Unhandled page fault on read access to 00000000").level, .error)

        let plain = WineLogClassifier.classify("Game initialised: 1920x1080 @ 60Hz")
        XCTAssertEqual(plain.level, .info)
        XCTAssertNil(plain.channel)
        XCTAssertEqual(plain.message, "Game initialised: 1920x1080 @ 60Hz")

        // Look-alikes must not be misread as Wine debug lines.
        XCTAssertEqual(WineLogClassifier.classify("error: something: else").level, .info)
        XCTAssertEqual(WineLogClassifier.classify("0024:err::empty channel").level, .info)
    }

    func testLevelsAreOrderedBySeverity() {
        XCTAssertEqual(WineLogLevel.allCases.sorted(), [.error, .warning, .fixme, .trace, .info])
        XCTAssertTrue(WineLogLevel.error < .warning)
    }

    // MARK: - TranslationPipeline

    private func engine(version: String) -> WineEngine {
        WineEngine(
            id: "wine-stable",
            name: "Wine Stable",
            rootPath: "/Applications/Wine Stable.app/Contents/Resources/wine",
            wineBinaryPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            wineserverPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wineserver",
            version: version,
            source: .custom,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: true,
                supportsMSync: true,
                supportsWineDLLPathPrepend: true
            )
        )
    }

    func testDXMTPipelineGoesStraightToMetal() {
        let stages = TranslationPipeline.stages(backend: .dxmt, engine: engine(version: "wine-11.0"), programArchitecture: .x86_64)
        XCTAssertEqual(stages.map(\.title), ["64 位程序", "Rosetta 2", "Wine 11.0", "DXMT", "Metal"])
        XCTAssertTrue(stages.allSatisfy(\.isReady))
    }

    func testDXVKAndWineD3DPipelinesIncludeIntermediateAPIs() {
        let dxvk = TranslationPipeline.stages(backend: .dxvk, engine: engine(version: "wine-10.18 (Staging)"))
        XCTAssertEqual(dxvk.map(\.kind), [.windowsProgram, .instructionTranslation, .wine, .graphicsTranslation, .intermediateAPI, .metal])
        XCTAssertEqual(dxvk[2].title, "Wine 10.18")
        XCTAssertEqual(dxvk[4].title, "MoltenVK")

        let wined3d = TranslationPipeline.stages(backend: .wined3d, engine: nil, programArchitecture: .x86_32, rosettaReady: false)
        XCTAssertEqual(wined3d.map(\.title), ["32 位程序", "Rosetta 2", "Wine", "WineD3D", "OpenGL", "Metal"])
        XCTAssertFalse(wined3d[1].isReady, "Missing Rosetta must be flagged")
        XCTAssertFalse(wined3d[2].isReady, "Missing engine must be flagged")
    }

    func testARM64ProgramsSkipRosettaAndOddVersionStringsFallBack() {
        let arm = TranslationPipeline.stages(backend: .dxmt, engine: engine(version: "custom-build"), programArchitecture: .arm64)
        XCTAssertFalse(arm.contains { $0.kind == .instructionTranslation })
        XCTAssertEqual(arm[1].title, "Wine")
    }
}
