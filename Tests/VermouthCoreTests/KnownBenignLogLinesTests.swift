import XCTest
@testable import VermouthCore

/// Steam 真机排障中确认的无害报错：`bin\gldriverquery.exe` 缺 `SDL2.dll`。
final class KnownBenignLogLinesTests: XCTestCase {
    // 原样取自真实 Steam 容器日志
    private let steamProbeImportLine =
        #"02f4:err:module:import_dll Library SDL2.dll (which is needed by L"C:\\Program Files (x86)\\Steam\\bin\\gldriverquery.exe") not found"#
    private let steamProbeLoaderLine =
        #"02f4:err:module:loader_init Importing dlls for L"C:\\Program Files (x86)\\Steam\\bin\\gldriverquery.exe" failed, status c0000135"#
    private let mainProgramImportLine =
        #"0110:err:module:import_dll Library SDL2.dll (which is needed by L"C:\\Games\\Foo\\foo.exe") not found"#

    func testMatchesSteamGPUProbeMissingSDL2() {
        XCTAssertNotNil(KnownBenignLogLines.match(steamProbeImportLine))
        XCTAssertNotNil(KnownBenignLogLines.match(steamProbeLoaderLine))
        XCTAssertNotNil(KnownBenignLogLines.match("[stderr] " + steamProbeImportLine))
    }

    func testDoesNotMatchSameDLLForOtherImporterOrOtherDLLForProbe() {
        XCTAssertNil(KnownBenignLogLines.match(mainProgramImportLine))
        XCTAssertNil(KnownBenignLogLines.match(
            #"02f4:err:module:import_dll Library vcruntime140.dll (which is needed by L"C:\\Program Files (x86)\\Steam\\bin\\gldriverquery.exe") not found"#
        ))
        XCTAssertNil(KnownBenignLogLines.match(
            #"02f4:err:module:loader_init Importing dlls for L"C:\\Games\\Foo\\foo.exe" failed, status c0000135"#
        ))
    }

    func testCrashDiagnoserIgnoresBenignLineButStillReportsMainProgram() {
        let diagnoser = CrashDiagnoser()
        XCTAssertTrue(diagnoser.diagnoseLine(steamProbeImportLine).isEmpty)
        XCTAssertTrue(diagnoser.diagnoseLine(steamProbeLoaderLine).isEmpty)

        // 两种出现顺序都必须报出主程序缺 SDL2.dll
        for order in [[steamProbeImportLine, mainProgramImportLine], [mainProgramImportLine, steamProbeImportLine]] {
            let findings = diagnoser.diagnose(logs: order)
            XCTAssertEqual(findings.map(\.id), ["missing-dll-sdl2.dll"])
            XCTAssertEqual(findings.first?.severity, .error)
            XCTAssertEqual(findings.first?.matchedLine, mainProgramImportLine)
        }
    }

    func testClassifierDowngradesBenignErrorLinesToInfo() {
        XCTAssertEqual(WineLogClassifier.classify(steamProbeImportLine).level, .info)
        XCTAssertEqual(WineLogClassifier.classify(steamProbeLoaderLine).level, .info)
        XCTAssertEqual(WineLogClassifier.classify(steamProbeImportLine).channel, "module")
        XCTAssertEqual(WineLogClassifier.classify(mainProgramImportLine).level, .error)
    }

    func testDXVKAdapterMismatchGetsDedicatedDiagnosis() throws {
        let finding = try XCTUnwrap(
            CrashDiagnoser().diagnoseLine("warn:  D3D11CoreCreateDevice: Adapter is not a DXVK adapter").first
        )
        XCTAssertEqual(finding.id, "dxvk-adapter-mismatch")
        XCTAssertEqual(finding.category, .graphicsInitFailed)
        XCTAssertEqual(finding.quickFix, .switchGraphicsBackend(.wined3d))
    }
}
