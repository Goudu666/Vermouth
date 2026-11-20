import Foundation
import XCTest
@testable import VermouthCore

private final class RegTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

final class RegistryPatcherTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = try createTempDirectory(prefix: "vermouth-regpatcher-test")
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func assertStrictCRLF(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            script.hasPrefix("Windows Registry Editor Version 5.00\r\n"),
            "Registry script must begin with Version 5.00 header followed by CRLF",
            file: file,
            line: line
        )
        let stripped = script.replacingOccurrences(of: "\r\n", with: "")
        XCTAssertFalse(stripped.contains("\n"), "Script must not contain bare LF line endings", file: file, line: line)
        XCTAssertFalse(stripped.contains("\r"), "Script must not contain bare CR line endings", file: file, line: line)
    }

    private func makeFixtureBottleAndPlan(
        config: BottleConfig,
        regFileURL: URL
    ) -> (bottle: Bottle, engine: WineEngine, plan: LaunchPlan) {
        let prefixPath = tempRoot.appendingPathComponent("prefix", isDirectory: true).path
        let bottle = Bottle(
            name: "Registry Test Bottle",
            prefixPath: prefixPath,
            config: config
        )
        let engine = WineEngine(
            id: "test-wine",
            name: "Wine Stable 11.0",
            rootPath: "/tmp/wine",
            wineBinaryPath: "/tmp/wine/bin/wine",
            wineserverPath: "/tmp/wine/bin/wineserver",
            version: "wine-11.0",
            source: .custom,
            capabilities: EngineCapabilities(supports32Bit: true, supports64Bit: true, isNewWoW64: true)
        )
        let plan = LaunchPlan(
            bottleID: bottle.id,
            engine: engine,
            executablePath: engine.wineBinaryPath,
            arguments: ["regedit", "/S", ShellQuoting.toWindowsPath(unixPath: regFileURL.path, prefixPath: prefixPath)],
            workingDirectory: prefixPath,
            environment: ["WINEPREFIX": prefixPath, "WINEMSYNC": "1"],
            logFilePath: tempRoot.appendingPathComponent("regedit.log").path,
            shellCommandPreview: "wine regedit /S ..."
        )
        return (bottle, engine, plan)
    }

    // MARK: - REG_MULTI_SZ Encoding (L-009)

    func testEncodeRegMultiSZExactUTF16LEHexBytes() {
        // Exact UTF-16LE bytes for ["STHeiti", "PingFang SC"] with per-string 00,00 and trailing double-null 00,00
        let encoded = RegistryPatcher.encodeRegMultiSZ(["STHeiti", "PingFang SC"])
        let expected = "hex(7):53,00,54,00,48,00,65,00,69,00,74,00,69,00,00,00,50,00,69,00,6e,00,67,00,46,00,61,00,6e,00,67,00,20,00,53,00,43,00,00,00,00,00"
        XCTAssertEqual(encoded, expected)

        // Verify per-string null terminator (00,00) + final list double-null terminator (00,00)
        XCTAssertTrue(encoded.hasSuffix(",00,00,00,00"))

        // Non-ASCII UTF-16LE little-endian check: "宋体" = U+5B8B (8b,5b), U+4F53 (53,4f)
        XCTAssertEqual(
            RegistryPatcher.encodeRegMultiSZ(["宋体"]),
            "hex(7):8b,5b,53,4f,00,00,00,00"
        )

        // Empty list produces minimal double-null terminator
        XCTAssertEqual(RegistryPatcher.encodeRegMultiSZ([]), "hex(7):00,00")
    }

    // MARK: - buildRegistryScript (Windows Version, Retina, DPI, Virtual Desktop, CJK, CRLF)

    func testBuildRegistryScriptWindowsVersionsRetinaAndDPIClamping() {
        // 1. All 4 WindowsVersion values
        for version in WindowsVersion.allCases {
            let config = BottleConfig(windowsVersion: version)
            let script = RegistryPatcher.buildRegistryScript(for: config, resolvedCJKFont: "STHeiti")
            assertStrictCRLF(script)
            XCTAssertTrue(
                script.contains("[HKEY_CURRENT_USER\\Software\\Wine]\r\n\"Version\"=\"\(version.rawValue)\"\r\n"),
                "Missing expected WindowsVersion \(version.rawValue)"
            )
        }

        // 2. RetinaMode true ("y") vs false ("n")
        let retinaOn = RegistryPatcher.buildRegistryScript(
            for: BottleConfig(display: DisplayConfig(retinaMode: true)),
            resolvedCJKFont: "STHeiti"
        )
        XCTAssertTrue(retinaOn.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n\"RetinaMode\"=\"y\"\r\n"))

        let retinaOff = RegistryPatcher.buildRegistryScript(
            for: BottleConfig(display: DisplayConfig(retinaMode: false)),
            resolvedCJKFont: "STHeiti"
        )
        XCTAssertTrue(retinaOff.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n\"RetinaMode\"=\"n\"\r\n"))

        // 3. DPI standard values and clamping (< 72 -> 72 = 0x48, > 384 -> 384 = 0x180)
        let dpiExpectations: [(dpi: Int, expectedHex: String)] = [
            (96, "00000060"),
            (144, "00000090"),
            (192, "000000c0"),
            (10, "00000048"),
            (-50, "00000048"),
            (71, "00000048"),
            (385, "00000180"),
            (999, "00000180"),
        ]
        for entry in dpiExpectations {
            let script = RegistryPatcher.buildRegistryScript(
                for: BottleConfig(display: DisplayConfig(dpi: entry.dpi)),
                resolvedCJKFont: "STHeiti"
            )
            XCTAssertTrue(
                script.contains("[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n\"LogPixels\"=dword:\(entry.expectedHex)\r\n"),
                "DPI \(entry.dpi) expected dword:\(entry.expectedHex)"
            )
        }
    }

    func testBuildRegistryScriptVirtualDesktopEnabledAndDisabledDeletion() {
        // Enabled: writes "Desktop"="Default" and "Default"="1280x720"
        let enabledConfig = BottleConfig(
            display: DisplayConfig(
                virtualDesktop: VirtualDesktopConfig(enabled: true, width: 1280, height: 720)
            )
        )
        let enabledScript = RegistryPatcher.buildRegistryScript(for: enabledConfig, resolvedCJKFont: "STHeiti")
        assertStrictCRLF(enabledScript)
        XCTAssertTrue(enabledScript.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]\r\n\"Desktop\"=\"Default\"\r\n"))
        XCTAssertTrue(enabledScript.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops]\r\n\"Default\"=\"1280x720\"\r\n"))

        // Enabled with undersized dimensions clamps to minimum 320x240
        let tinyConfig = BottleConfig(
            display: DisplayConfig(
                virtualDesktop: VirtualDesktopConfig(enabled: true, width: 100, height: 80)
            )
        )
        let tinyScript = RegistryPatcher.buildRegistryScript(for: tinyConfig, resolvedCJKFont: "STHeiti")
        XCTAssertTrue(tinyScript.contains("\"Default\"=\"320x240\"\r\n"))

        // Disabled (L-009): explicit "Desktop"=- and "Default"=- deletion entries
        let disabledConfig = BottleConfig(
            display: DisplayConfig(
                virtualDesktop: VirtualDesktopConfig(enabled: false, width: 1280, height: 720)
            )
        )
        let disabledScript = RegistryPatcher.buildRegistryScript(for: disabledConfig, resolvedCJKFont: "STHeiti")
        assertStrictCRLF(disabledScript)
        XCTAssertTrue(disabledScript.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Explorer]\r\n\"Desktop\"=-\r\n"))
        XCTAssertTrue(disabledScript.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Explorer\\Desktops]\r\n\"Default\"=-\r\n"))
    }

    func testBuildRegistryScriptChineseLocalizationEnabledAndDisabledDeletion() {
        // Enabled: FontLink\SystemLink uses REG_MULTI_SZ hex(7):... and FontSubstitutes maps Chinese font keys
        let enabledConfig = BottleConfig(
            locale: LocaleConfig(
                chineseLocalizationEnabled: true,
                lcAll: "zh_CN.UTF-8",
                fallbackFontName: "PingFang SC"
            )
        )
        let enabledScript = RegistryPatcher.buildRegistryScript(for: enabledConfig)
        assertStrictCRLF(enabledScript)

        let expectedMultiSZ = RegistryPatcher.encodeRegMultiSZ(["PingFang SC"])
        XCTAssertTrue(
            enabledScript.contains("[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink]\r\n")
        )
        XCTAssertTrue(enabledScript.contains("\"Tahoma\"=\(expectedMultiSZ)\r\n"))
        XCTAssertTrue(enabledScript.contains("\"Microsoft Sans Serif\"=\(expectedMultiSZ)\r\n"))
        XCTAssertTrue(enabledScript.contains("\"Segoe UI\"=\(expectedMultiSZ)\r\n"))
        XCTAssertTrue(enabledScript.contains("\"MS Shell Dlg\"=\(expectedMultiSZ)\r\n"))
        XCTAssertTrue(enabledScript.contains("\"MS Shell Dlg 2\"=\(expectedMultiSZ)\r\n"))

        XCTAssertTrue(
            enabledScript.contains("[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes]\r\n")
        )
        XCTAssertTrue(enabledScript.contains("\"宋体\"=\"PingFang SC\"\r\n"))
        XCTAssertTrue(enabledScript.contains("\"微软雅黑\"=\"PingFang SC\"\r\n"))
        XCTAssertTrue(enabledScript.contains("\"SimSun\"=\"PingFang SC\"\r\n"))
        XCTAssertTrue(enabledScript.contains("\"黑体\"=\"PingFang SC\"\r\n"))

        // Explicit resolvedCJKFont parameter overrides config.locale.fallbackFontName
        let overriddenScript = RegistryPatcher.buildRegistryScript(for: enabledConfig, resolvedCJKFont: "Hiragino Sans GB")
        let overriddenMultiSZ = RegistryPatcher.encodeRegMultiSZ(["Hiragino Sans GB"])
        XCTAssertTrue(overriddenScript.contains("\"Tahoma\"=\(overriddenMultiSZ)\r\n"))
        XCTAssertTrue(overriddenScript.contains("\"宋体\"=\"Hiragino Sans GB\"\r\n"))

        // Disabled (L-009): explicit "-" deletion syntax for BOTH FontLink\SystemLink and FontSubstitutes
        let disabledConfig = BottleConfig(
            locale: LocaleConfig(chineseLocalizationEnabled: false)
        )
        let disabledScript = RegistryPatcher.buildRegistryScript(for: disabledConfig, resolvedCJKFont: "STHeiti")
        assertStrictCRLF(disabledScript)
        XCTAssertTrue(disabledScript.contains("\"Tahoma\"=-\r\n"))
        XCTAssertTrue(disabledScript.contains("\"MS Shell Dlg\"=-\r\n"))
        XCTAssertTrue(disabledScript.contains("\"宋体\"=-\r\n"))
        XCTAssertTrue(disabledScript.contains("\"微软雅黑\"=-\r\n"))
        XCTAssertTrue(disabledScript.contains("\"SimSun\"=-\r\n"))
        XCTAssertFalse(disabledScript.contains("hex(7):"))
    }

    // MARK: - UTF-16LE + BOM Encoding (L-009)

    func testEncodeUTF16LEWithBOMRoundTripsChineseRegistryScript() throws {
        let config = BottleConfig(
            locale: LocaleConfig(chineseLocalizationEnabled: true, fallbackFontName: "STHeiti")
        )
        let script = RegistryPatcher.buildRegistryScript(for: config)
        let encoded = RegistryPatcher.encodeUTF16LEWithBOM(script)

        // Exact UTF-16LE BOM header: 0xFF, 0xFE
        XCTAssertGreaterThanOrEqual(encoded.count, 2)
        XCTAssertEqual(encoded[0], 0xFF)
        XCTAssertEqual(encoded[1], 0xFE)

        // Decoding bytes after BOM must reproduce exact script including Chinese keys "宋体" and "微软雅黑"
        let bodyData = Data(encoded.dropFirst(2))
        let decoded = try XCTUnwrap(String(data: bodyData, encoding: .utf16LittleEndian))
        XCTAssertEqual(decoded, script)
        XCTAssertTrue(decoded.contains("\"宋体\"=\"STHeiti\""))
        XCTAssertTrue(decoded.contains("\"微软雅黑\"=\"STHeiti\""))

        // Mixed LF/CR inputs passed directly to encodeUTF16LEWithBOM are normalized to CRLF
        let mixedInput = "Line1\nLine2\rLine3\r\n宋体"
        let mixedEncoded = RegistryPatcher.encodeUTF16LEWithBOM(mixedInput)
        XCTAssertEqual(mixedEncoded[0], 0xFF)
        XCTAssertEqual(mixedEncoded[1], 0xFE)
        let mixedDecoded = try XCTUnwrap(String(data: Data(mixedEncoded.dropFirst(2)), encoding: .utf16LittleEndian))
        XCTAssertEqual(mixedDecoded, "Line1\r\nLine2\r\nLine3\r\n宋体")
    }

    // MARK: - CJK Font Fallback Chain

    func testDetectAvailableCJKFontFallbackChain() {
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { $0 == "/System/Library/Fonts/STHeiti Light.ttc" },
            "STHeiti"
        )
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { $0 == "/System/Library/Fonts/Hiragino Sans GB.ttc" },
            "Hiragino Sans GB"
        )
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { $0 == "/System/Library/Fonts/Supplemental/Songti.ttc" },
            "Songti SC"
        )
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { $0 == "/System/Library/Fonts/PingFang.ttc" },
            "PingFang SC"
        )
        // Priority order: Hiragino Sans GB beats PingFang SC when STHeiti is absent
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { path in
                path == "/System/Library/Fonts/Hiragino Sans GB.ttc" || path == "/System/Library/Fonts/PingFang.ttc"
            },
            "Hiragino Sans GB"
        )
        // When no font matches, falls back safely to "STHeiti"
        XCTAssertEqual(
            RegistryPatcher.detectAvailableCJKFont { _ in false },
            "STHeiti"
        )
    }

    // MARK: - apply(...) End-to-End with MockCommandRunner (L-009, L-016)

    func testApplyWritesUTF16LEBOMFileBeforeRegeditAndCleansUpOnSuccess() async throws {
        let regFileURL = tempRoot.appendingPathComponent("reg/vermouth-patch.reg", isDirectory: false)
        let config = BottleConfig(
            windowsVersion: .win7,
            display: DisplayConfig(
                retinaMode: true,
                dpi: 144,
                virtualDesktop: VirtualDesktopConfig(enabled: true, width: 1280, height: 720)
            ),
            locale: LocaleConfig(chineseLocalizationEnabled: true, fallbackFontName: "PingFang SC")
        )
        let (bottle, engine, plan) = makeFixtureBottleAndPlan(config: config, regFileURL: regFileURL)
        let expectedScript = RegistryPatcher.buildRegistryScript(for: config)

        struct ObservedRegFile: Sendable {
            let existedDuringRun: Bool
            let rawBytes: Data?
            let siblingEntries: [String]
        }
        let observedBox = RegTestBox<ObservedRegFile?>(nil)

        let mockRunner = MockCommandRunner(runHandler: { _ in
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: regFileURL.path)
            let bytes = exists ? try? Data(contentsOf: regFileURL) : nil
            let entries = (try? fm.contentsOfDirectory(atPath: regFileURL.deletingLastPathComponent().path)) ?? []
            observedBox.withLock {
                $0 = ObservedRegFile(existedDuringRun: exists, rawBytes: bytes, siblingEntries: entries)
            }
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        })

        try await RegistryPatcher.apply(
            bottle: bottle,
            engine: engine,
            launchPlan: plan,
            regFileURL: regFileURL,
            commandRunner: mockRunner
        )

        // Verify regedit was invoked with launchPlan parameters
        XCTAssertEqual(mockRunner.recordedRequests.count, 1)
        let recorded = try XCTUnwrap(mockRunner.recordedRequests.first)
        XCTAssertEqual(recorded.executablePath, plan.executablePath)
        XCTAssertEqual(recorded.arguments, plan.arguments)
        XCTAssertEqual(recorded.environment, plan.environment)
        XCTAssertEqual(recorded.workingDirectory, plan.workingDirectory)

        // Verify UTF-16LE BOM .reg file was written atomically BEFORE command executed
        let observed = try XCTUnwrap(observedBox.withLock { $0 })
        XCTAssertTrue(observed.existedDuringRun, ".reg file must exist on disk before regedit executes")
        XCTAssertEqual(observed.siblingEntries, ["vermouth-patch.reg"], "Atomic write must leave no stray .tmp files")
        let bytes = try XCTUnwrap(observed.rawBytes)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0xFE)
        let decoded = try XCTUnwrap(String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian))
        XCTAssertEqual(decoded, expectedScript)

        // Verify .reg file is cleaned up after apply completes
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: regFileURL.path),
            "Temporary .reg file must be removed after apply succeeds"
        )
    }

    func testApplyNonZeroExitAndSpawnErrorThrowRegistryPatchFailedAndStillCleanUpFile() async throws {
        let regFileURL = tempRoot.appendingPathComponent("reg/vermouth-fail.reg", isDirectory: false)
        let config = BottleConfig(locale: LocaleConfig(chineseLocalizationEnabled: true))
        let (bottle, engine, plan) = makeFixtureBottleAndPlan(config: config, regFileURL: regFileURL)

        // 1. Non-zero regedit exit code throws VermouthError.registryPatchFailed (L-016) and cleans up .reg file
        let sawFileBeforeFail = RegTestBox(false)
        let failingRunner = MockCommandRunner(runHandler: { _ in
            let exists = FileManager.default.fileExists(atPath: regFileURL.path)
            sawFileBeforeFail.withLock { $0 = exists }
            return CommandResult(exitCode: 1, stdout: "", stderr: "regedit: failed to import key")
        })

        do {
            try await RegistryPatcher.apply(
                bottle: bottle,
                engine: engine,
                launchPlan: plan,
                regFileURL: regFileURL,
                commandRunner: failingRunner
            )
            XCTFail("Expected VermouthError.registryPatchFailed on non-zero regedit exit")
        } catch let error as VermouthError {
            guard case .registryPatchFailed(let reason) = error else {
                XCTFail("Expected VermouthError.registryPatchFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("1"))
            XCTAssertTrue(reason.contains("failed to import key"))
        }

        XCTAssertTrue(sawFileBeforeFail.withLock { $0 })
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: regFileURL.path),
            "Temporary .reg file must be cleaned up even when regedit exits non-zero"
        )

        // 2. Underlying runner throw wraps in VermouthError.registryPatchFailed and cleans up .reg file
        let throwingRunner = MockCommandRunner(runHandler: { _ in
            throw VermouthError.ioError(
                operation: "spawnProcess",
                path: plan.executablePath,
                underlyingDescription: "No such file"
            )
        })

        do {
            try await RegistryPatcher.apply(
                bottle: bottle,
                engine: engine,
                launchPlan: plan,
                regFileURL: regFileURL,
                commandRunner: throwingRunner
            )
            XCTFail("Expected VermouthError.registryPatchFailed when command runner throws")
        } catch let error as VermouthError {
            guard case .registryPatchFailed(let reason) = error else {
                XCTFail("Expected VermouthError.registryPatchFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains(engine.name))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: regFileURL.path),
            "Temporary .reg file must be cleaned up even when command runner throws"
        )
    }
}
