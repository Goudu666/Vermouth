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

/// winetricks 运行库安装：目录完整性与安装计划生成。
final class WinetricksTests: XCTestCase {
    private func basePlan() -> LaunchPlan {
        let engine = WineEngine(
            id: "wine-stable",
            name: "Wine Stable",
            rootPath: "/opt/wine",
            wineBinaryPath: "/opt/wine/bin/wine",
            wineserverPath: "/opt/wine/bin/wineserver",
            version: "wine-11.0",
            source: .custom,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: true,
                supportsMSync: true,
                supportsWineDLLPathPrepend: true
            )
        )
        return LaunchPlan(
            bottleID: UUID(),
            engine: engine,
            executablePath: "/opt/wine/bin/wine",
            arguments: ["winecfg"],
            workingDirectory: "/tmp/prefix/drive_c",
            environment: ["WINEPREFIX": "/tmp/prefix", "WINEMSYNC": "1"],
            logFilePath: "/tmp/logs/20261120-winecfg.log",
            shellCommandPreview: "wine winecfg"
        )
    }

    func testPlanReusesBottleEnvironmentAndPinsEngine() throws {
        let plan = try WinetricksPlanner.makePlan(
            basedOn: basePlan(),
            winetricksPath: "/opt/homebrew/bin/winetricks",
            verbs: ["vcrun2022", " D3DX9 ", "vcrun2022"]
        )
        XCTAssertEqual(plan.executablePath, "/opt/homebrew/bin/winetricks")
        XCTAssertEqual(plan.arguments, ["-q", "vcrun2022", "d3dx9"], "Verbs must be normalized, de-duplicated and order-preserving")
        XCTAssertEqual(plan.environment["WINEPREFIX"], "/tmp/prefix")
        XCTAssertEqual(plan.environment["WINEMSYNC"], "1", "Sync mode must match the bottle (L-003)")
        XCTAssertEqual(plan.environment["WINE"], "/opt/wine/bin/wine")
        XCTAssertEqual(plan.environment["WINESERVER"], "/opt/wine/bin/wineserver")
        XCTAssertEqual(plan.logFilePath, "/tmp/logs/20261120-winecfg-winetricks.log")
        XCTAssertTrue(plan.shellCommandPreview.contains("/opt/homebrew/bin/winetricks"))
        XCTAssertTrue(plan.shellCommandPreview.hasSuffix("-q vcrun2022 d3dx9"))
    }

    func testRejectsInjectionAndEmptyInput() {
        for bad in ["--force", "vcrun2022; rm -rf ~", "$(whoami)", "=x", "a b", "中文"] {
            XCTAssertThrowsError(try WinetricksPlanner.normalize([bad]), "Should reject \(bad)") { error in
                guard case VermouthError.invalidWinetricksVerb = error else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
        }
        XCTAssertThrowsError(try WinetricksPlanner.normalize([]))
        XCTAssertNoThrow(try WinetricksPlanner.normalize(["fontsmooth=rgb"]))
        XCTAssertThrowsError(try WinetricksPlanner.makePlan(basedOn: basePlan(), winetricksPath: "  ", verbs: ["d3dx9"])) { error in
            guard case VermouthError.winetricksNotInstalled = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testCatalogIsValidAndCoversEveryRuntimeTheDiagnoserSuggests() throws {
        let ids = WinetricksCatalog.verbs.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Catalog ids must be unique")
        XCTAssertEqual(try WinetricksPlanner.normalize(ids), ids, "Every catalog id must pass validation")
        XCTAssertFalse(WinetricksCatalog.recommendedIDs.isEmpty)

        // Every runtime that CrashDiagnoser can recommend must be one click away in the installer.
        let diagnoser = CrashDiagnoser()
        var checkedVerbs: Set<String> = []
        let missingDLLs = ["vcruntime140.dll", "msvcp140.dll", "msvcr120.dll", "msvcr110.dll", "msvcr100.dll",
                           "d3dx9_43.dll", "d3dcompiler_47.dll", "d3dcompiler_43.dll", "mfplat.dll", "mscoree.dll"]
        for dll in missingDLLs {
            let line = "0024:err:module:import_dll Library \(dll) (which is needed by L\"C:\\\\game.exe\") not found"
            for finding in diagnoser.diagnoseLine(line) {
                guard case let .copyCommand(_, command)? = finding.quickFix, command.hasPrefix("winetricks") else { continue }
                let verb = command.split(separator: " ").last.map(String.init) ?? ""
                XCTAssertNotNil(WinetricksCatalog.verb(id: verb), "\(dll) → \(verb) missing from WinetricksCatalog")
                checkedVerbs.insert(verb)
            }
        }
        XCTAssertGreaterThanOrEqual(checkedVerbs.count, 5, "Expected the diagnoser to map several DLLs to winetricks verbs: \(checkedVerbs)")
    }
}
