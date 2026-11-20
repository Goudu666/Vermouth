import Foundation
import XCTest
@testable import VermouthCore

final class ModelsTests: XCTestCase {
    // MARK: - DllOverride Normalization & Presets (L-011)

    func testDllOverrideNormalizationInInitAndDecoding() throws {
        let fromInit = DllOverride(
            dllName: "  DInput8.DLL  ",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "ASI Loader"
        )
        XCTAssertEqual(fromInit.dllName, "dinput8")
        XCTAssertEqual(fromInit.id, "dinput8")

        let canonical = DllOverride(
            dllName: "dinput8",
            mode: .nativeThenBuiltin,
            enabled: true,
            note: "ASI Loader"
        )
        XCTAssertEqual(fromInit, canonical)

        // Repeated .dll suffixes and mixed whitespace/casing
        XCTAssertEqual(DllOverride.normalizeName("\t VorbisFile.DLL.dll \n"), "vorbisfile")
        XCTAssertEqual(DllOverride(dllName: "  WINHTTP.dll  ").dllName, "winhttp")

        // JSON decoding must apply the exact same normalization (L-011)
        let rawJSON = """
        {
          "dllName": "  DInput8.DLL  ",
          "enabled": true,
          "mode": "n,b",
          "note": "ASI Loader"
        }
        """
        let fromJSON = try VermouthJSON.decode(DllOverride.self, from: Data(rawJSON.utf8))
        XCTAssertEqual(fromJSON.dllName, "dinput8")
        XCTAssertEqual(fromJSON.id, "dinput8")
        XCTAssertEqual(fromJSON, fromInit)
        XCTAssertEqual(fromJSON, canonical)

        // Omitted `enabled` defaults to true during JSON decoding
        let minimalJSON = """
        {
          "dllName": "  Version.DLL ",
          "mode": "b"
        }
        """
        let minimalDecoded = try VermouthJSON.decode(DllOverride.self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(minimalDecoded.dllName, "version")
        XCTAssertEqual(minimalDecoded.id, "version")
        XCTAssertEqual(minimalDecoded.mode, .builtinOnly)
        XCTAssertTrue(minimalDecoded.enabled)
        XCTAssertNil(minimalDecoded.note)

        // Verify all DllOverrideMode raw values round-trip cleanly
        for mode in DllOverrideMode.allCases {
            let item = DllOverride(dllName: "TestMod.DLL", mode: mode, enabled: true)
            let encoded = try VermouthJSON.encode(item)
            let decoded = try VermouthJSON.decode(DllOverride.self, from: encoded)
            XCTAssertEqual(decoded, item)
            XCTAssertEqual(decoded.dllName, "testmod")
        }
    }

    func testDllOverrideCommonPresetsContainRequiredHooks() {
        let presetNames = Set(DllOverride.commonPresets.map(\.dllName))
        XCTAssertTrue(presetNames.contains("dinput8"))
        XCTAssertTrue(presetNames.contains("vorbisfile"))
        XCTAssertTrue(presetNames.contains("winhttp"))
        XCTAssertTrue(presetNames.contains("version"))

        // All preset IDs must be unique and already normalized
        XCTAssertEqual(presetNames.count, DllOverride.commonPresets.count)
        for preset in DllOverride.commonPresets {
            XCTAssertEqual(preset.id, preset.dllName)
            XCTAssertEqual(preset.dllName, DllOverride.normalizeName(preset.dllName))
            XCTAssertFalse(preset.dllName.hasSuffix(".dll"))
        }
    }

    // MARK: - Full Model Codable Round-Trips via VermouthJSON

    func testBottleCodableRoundTrip() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_500.625)
        let lastLaunchedAt = Date(timeIntervalSince1970: 1_700_000_400.375)

        let saveTarget = SnapshotTarget(
            id: UUID(),
            label: "GTA User Files",
            path: "drive_c/users/crossover/Documents/GTA San Andreas User Files"
        )
        let app = AppEntry(
            id: UUID(),
            name: "GTA: San Andreas",
            executablePath: "/tmp/bottles/test/prefix/drive_c/Program Files (x86)/GTA/gta_sa.exe",
            arguments: ["-windowed", "-nosplash"],
            workingDirectory: "/tmp/bottles/test/prefix/drive_c/Program Files (x86)/GTA",
            environmentOverrides: ["DXVK_HUD": "fps"],
            dllOverrides: [
                DllOverride(dllName: "DInput8.DLL", mode: .nativeThenBuiltin, enabled: true, note: "ASI"),
                DllOverride(dllName: "vorbisFile", mode: .nativeThenBuiltin, enabled: false, note: "CLEO"),
            ],
            snapshotTargets: [saveTarget],
            isPinned: true,
            lastLaunchedAt: lastLaunchedAt
        )

        let config = BottleConfig(
            engineID: "app-wine-stable",
            windowsVersion: .win7,
            syncMode: .msync,
            graphicsBackend: .dxmt,
            graphicsLayerVersionID: "dxmt-v0.80",
            display: DisplayConfig(
                retinaMode: true,
                dpi: 144,
                metalHUD: true,
                virtualDesktop: VirtualDesktopConfig(enabled: true, width: 1920, height: 1080)
            ),
            locale: LocaleConfig(
                chineseLocalizationEnabled: true,
                lcAll: "zh_CN.UTF-8",
                fallbackFontName: "PingFang SC"
            ),
            dllOverrides: [
                DllOverride(dllName: "winhttp.dll", mode: .nativeThenBuiltin, enabled: true, note: "BepInEx"),
            ],
            environmentVariables: ["CUSTOM_FLAG": "1", "PATH_EXTRA": "/opt/local/bin"],
            wineDebugChannels: "-all,err+all,fixme-all"
        )

        let bottle = Bottle(
            schemaVersion: Bottle.currentSchemaVersion,
            id: UUID(),
            name: "Classic Gaming Bottle",
            createdAt: createdAt,
            updatedAt: updatedAt,
            prefixPath: "/tmp/bottles/test/prefix",
            isExternalPrefix: false,
            config: config,
            apps: [app],
            appliedRecipeID: "gtasa-pc-1.0"
        )

        let encoded = try VermouthJSON.encode(bottle)
        let decoded = try VermouthJSON.decode(Bottle.self, from: encoded)
        XCTAssertEqual(decoded, bottle)
    }

    func testWineEngineAndPreflightReportCodableRoundTrip() throws {
        let engine = WineEngine(
            id: "app-wine-stable",
            name: "Wine Stable 11.0 (WoW64)",
            rootPath: "/Applications/Wine Stable.app/Contents/Resources/wine",
            wineBinaryPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            wineserverPath: "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wineserver",
            version: "wine-11.0",
            source: .homebrewCask,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: true,
                supportsMSync: true,
                supportsWineDLLPathPrepend: true
            ),
            isQuarantined: false
        )

        let encodedEngine = try VermouthJSON.encode(engine)
        let decodedEngine = try VermouthJSON.decode(WineEngine.self, from: encodedEngine)
        XCTAssertEqual(decodedEngine, engine)

        let report = PreflightReport(
            checkedAt: Date(timeIntervalSince1970: 1_700_000_200.500),
            architecture: .arm64,
            osVersion: OSVersionInfo(major: 15, minor: 3, patch: 1, displayString: "macOS 15.3.1"),
            rosetta2Ready: true,
            homebrewPath: "/opt/homebrew/bin/brew",
            winetricksPath: "/opt/homebrew/bin/winetricks",
            discoveredEngines: [engine],
            items: [
                PreflightCheckItem(
                    id: "rosetta2",
                    title: "Rosetta 2",
                    status: .pass,
                    detail: "Rosetta 2 is installed",
                    remediationCommand: nil
                ),
                PreflightCheckItem(
                    id: "winetricks",
                    title: "Winetricks",
                    status: .warning,
                    detail: "Optional helper missing",
                    remediationCommand: "brew install winetricks"
                ),
            ],
            isReadyToLaunch: true
        )

        let encodedReport = try VermouthJSON.encode(report)
        let decodedReport = try VermouthJSON.decode(PreflightReport.self, from: encodedReport)
        XCTAssertEqual(decodedReport, report)
    }

    func testGraphicsLayerPackageAndDeploymentModelsCodableRoundTrip() throws {
        let package = GraphicsLayerPackage(
            id: "dxmt-v0.80",
            backend: .dxmt,
            version: "v0.80",
            format: .wineBuiltin,
            installPath: "/tmp/vermouth/graphics/dxmt/v0.80",
            sourceURL: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            installedAt: Date(timeIntervalSince1970: 1_700_000_300.750),
            containedDLLs: ["d3d10core", "d3d11", "dxgi", "winemetal"]
        )

        let encodedPkg = try VermouthJSON.encode(package)
        let decodedPkg = try VermouthJSON.decode(GraphicsLayerPackage.self, from: encodedPkg)
        XCTAssertEqual(decodedPkg, package)

        let record = GraphicsDeploymentRecord(
            schemaVersion: GraphicsDeploymentRecord.currentSchemaVersion,
            backend: .dxvk,
            packageID: "dxvk-v1.10.3-repack",
            strategy: .prefixCopyWithBackup,
            deployedFiles: ["drive_c/windows/system32/d3d11.dll", "drive_c/windows/system32/d3d10core.dll"],
            backedUpFiles: ["drive_c/windows/system32/d3d11.dll": "system32/d3d11.dll.orig"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_400.250)
        )
        let encodedRec = try VermouthJSON.encode(record)
        let decodedRec = try VermouthJSON.decode(GraphicsDeploymentRecord.self, from: encodedRec)
        XCTAssertEqual(decodedRec, record)

        let releaseURL = try XCTUnwrap(URL(string: "https://example.com/dxmt-v0.80-builtin.tar.gz"))
        let release = RemoteGraphicsRelease(
            backend: .dxmt,
            tagName: "v0.80",
            version: "0.80",
            assetName: "dxmt-v0.80-builtin.tar.gz",
            downloadURL: releaseURL,
            sizeBytes: 4_194_304,
            format: .wineBuiltin,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_100.125)
        )
        XCTAssertEqual(release.id, "dxmt-v0.80-dxmt-v0.80-builtin.tar.gz")
        let encodedRelease = try VermouthJSON.encode(release)
        let decodedRelease = try VermouthJSON.decode(RemoteGraphicsRelease.self, from: encodedRelease)
        XCTAssertEqual(decodedRelease, release)

        // DownloadProgress clamping and nil-total edge cases
        XCTAssertNil(DownloadProgress(bytesWritten: 100, totalBytesExpected: nil).fractionCompleted)
        XCTAssertNil(DownloadProgress(bytesWritten: 100, totalBytesExpected: 0).fractionCompleted)
        XCTAssertNil(DownloadProgress(bytesWritten: 100, totalBytesExpected: -5).fractionCompleted)
        XCTAssertEqual(DownloadProgress(bytesWritten: 50, totalBytesExpected: 200).fractionCompleted, 0.25)
        XCTAssertEqual(DownloadProgress(bytesWritten: 500, totalBytesExpected: 200).fractionCompleted, 1.0)
        XCTAssertEqual(DownloadProgress(bytesWritten: -10, totalBytesExpected: 200).fractionCompleted, 0.0)
    }

    func testDiagnosticFindingWithAllQuickFixesCodableRoundTrip() throws {
        let findings: [DiagnosticFinding] = [
            DiagnosticFinding(
                id: "diag-quarantine",
                category: .quarantineBlocked,
                severity: .error,
                title: "Quarantine Attribute Detected",
                explanation: "Executable carries com.apple.quarantine",
                suggestion: "Remove quarantine on the executable",
                matchedLine: "Gatekeeper blocked launch",
                missingDLLName: nil,
                recommendedRuntime: nil,
                quickFix: .removeQuarantine(path: "/tmp/game.exe", recursive: false)
            ),
            DiagnosticFinding(
                id: "diag-graphics",
                category: .graphicsInitFailed,
                severity: .error,
                title: "DXMT Init Failed",
                explanation: "Failed to initialize Metal device",
                suggestion: "Switch to DXVK or WineD3D",
                quickFix: .switchGraphicsBackend(.wined3d)
            ),
            DiagnosticFinding(
                id: "diag-sync",
                category: .syncMismatch,
                severity: .error,
                title: "MSync Protocol Mismatch",
                explanation: "wineserver already running with different sync mode",
                suggestion: "Restart wineserver",
                matchedLine: "msync_init: failed",
                quickFix: .killWineServer
            ),
            DiagnosticFinding(
                id: "diag-arch",
                category: .architectureMismatch,
                severity: .error,
                title: "32-bit Executable on 64-bit Only Engine",
                explanation: "Engine lacks WoW64 support",
                suggestion: "Select a 32-bit capable engine",
                quickFix: .select32BitCapableEngine
            ),
            DiagnosticFinding(
                id: "diag-override",
                category: .dllOverrideConflict,
                severity: .warning,
                title: "Conflicting DLL Override",
                explanation: "d3d11=n,b conflicts with DXMT builtin",
                suggestion: "Remove conflicting override",
                quickFix: .removeConflictingDllOverrides(["d3d11", "dxgi"])
            ),
            DiagnosticFinding(
                id: "diag-locale",
                category: .fontOrLocale,
                severity: .info,
                title: "CJK Font Fallback Missing",
                explanation: "Chinese UI may render tofu boxes",
                suggestion: "Enable Chinese localization",
                quickFix: .enableChineseLocalization
            ),
            DiagnosticFinding(
                id: "diag-missing-dll",
                category: .missingDLL,
                severity: .error,
                title: "Missing vcruntime140.dll",
                explanation: "Visual C++ 2015-2022 runtime not installed",
                suggestion: "Install vcrun2022 via winetricks",
                matchedLine: "err:module:import_dll Library vcruntime140.dll not found",
                missingDLLName: "vcruntime140.dll",
                recommendedRuntime: "vcrun2022",
                quickFix: .copyCommand(label: "Install vcrun2022", command: "winetricks vcrun2022")
            ),
            DiagnosticFinding(
                id: "diag-no-quickfix",
                category: .rosettaMissing,
                severity: .warning,
                title: "Advisory Notice",
                explanation: "Informational item without quick fix",
                suggestion: "No action required",
                quickFix: nil
            ),
        ]

        let encoded = try VermouthJSON.encode(findings)
        let decoded = try VermouthJSON.decode([DiagnosticFinding].self, from: encoded)
        XCTAssertEqual(decoded, findings)
    }

    func testSnapshotRecordCodableRoundTrip() throws {
        let dirSnapshot = SnapshotRecord(
            id: UUID(),
            targetID: UUID(),
            label: "Before SilentPatch",
            sourcePath: "/tmp/bottles/b1/prefix/drive_c/users/crossover/Documents/GTA",
            isDirectory: true,
            note: "Clean vanilla save directory",
            createdAt: Date(timeIntervalSince1970: 1_700_000_700.875),
            archivePath: "/tmp/bottles/b1/snapshots/snap-001.tar.gz",
            fileCount: 14,
            totalBytes: 524_288,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        let fileSnapshot = SnapshotRecord(
            id: UUID(),
            targetID: UUID(),
            label: "settings.ini",
            sourcePath: "/tmp/bottles/b1/prefix/drive_c/Game/settings.ini",
            isDirectory: false,
            note: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_800.125),
            archivePath: "/tmp/bottles/b1/snapshots/snap-002.tar.gz",
            fileCount: 1,
            totalBytes: 2_048,
            sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )

        let records = [dirSnapshot, fileSnapshot]
        let encoded = try VermouthJSON.encode(records)
        let decoded = try VermouthJSON.decode([SnapshotRecord].self, from: encoded)
        XCTAssertEqual(decoded, records)
    }

    func testRecipeCodableRoundTrip() throws {
        let recipe = Recipe(
            schemaVersion: Recipe.currentSchemaVersion,
            id: "custom-dx11-rpg",
            name: "Custom DX11 RPG",
            summary: "64-bit DX11 preset with optional ModLoader hook",
            targetArchitecture: .x86_64,
            recommendedWindowsVersion: .win10,
            recommendedBackend: .dxmt,
            recommendedSyncMode: .msync,
            chineseLocalizationSuggested: true,
            dllOverrides: [
                DllOverride(dllName: "WINHTTP.DLL", mode: .nativeThenBuiltin, enabled: false, note: "BepInEx"),
                DllOverride(dllName: "version", mode: .nativeThenBuiltin, enabled: true, note: "ModLoader"),
            ],
            environmentVariables: ["DXMT_ENABLE_NVEXT": "0"],
            wineDebugChannels: "-all,err+all",
            notes: ["Use a Wine engine supporting WINEDLLPATH_PREPEND."],
            knownIssues: ["Requires macOS 14+ with Apple Silicon Metal GPU."]
        )

        let encoded = try VermouthJSON.encode(recipe)
        let decoded = try VermouthJSON.decode(Recipe.self, from: encoded)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.dllOverrides.map(\.dllName), ["winhttp", "version"])
    }

    func testLaunchModelsCodableRoundTrip() throws {
        let engine = WineEngine(
            id: "custom-wine",
            name: "Custom Wine",
            rootPath: "/tmp/wine",
            wineBinaryPath: "/tmp/wine/bin/wine",
            wineserverPath: "/tmp/wine/bin/wineserver",
            version: "wine-11.0",
            source: .custom,
            capabilities: EngineCapabilities(supports32Bit: true, supports64Bit: true, isNewWoW64: true)
        )
        let plan = LaunchPlan(
            bottleID: UUID(),
            engine: engine,
            executablePath: "/tmp/wine/bin/wine",
            arguments: ["msiexec", "/i", "Z:\\Users\\tester\\setup.msi"],
            workingDirectory: "/tmp/bottles/b1/prefix/drive_c",
            environment: ["WINEPREFIX": "/tmp/bottles/b1/prefix", "WINEMSYNC": "1"],
            warnings: [
                DiagnosticFinding(
                    id: "warn-1",
                    category: .fontOrLocale,
                    severity: .info,
                    title: "Locale info",
                    explanation: "Using zh_CN.UTF-8",
                    suggestion: "No change needed"
                ),
            ],
            logFilePath: "/tmp/bottles/b1/logs/20250101-setup.log",
            shellCommandPreview: "WINEMSYNC=1 WINEPREFIX=/tmp/bottles/b1/prefix /tmp/wine/bin/wine msiexec /i 'Z:\\Users\\tester\\setup.msi'"
        )
        let encodedPlan = try VermouthJSON.encode(plan)
        let decodedPlan = try VermouthJSON.decode(LaunchPlan.self, from: encodedPlan)
        XCTAssertEqual(decodedPlan, plan)

        let logLine = LogLine(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_900.500),
            stream: .system,
            text: "Process exited with code 0",
            exitCode: 0
        )
        XCTAssertEqual(try VermouthJSON.decode(LogLine.self, from: try VermouthJSON.encode(logLine)), logLine)

        let targets: [LaunchTarget] = [
            .executable(path: "/tmp/app.exe", workingDirectory: "/tmp"),
            .appEntry(AppEntry(name: "App", executablePath: "/tmp/app.exe")),
            .installer(path: "/tmp/setup.msi"),
            .builtinTool(.winecfg, extraArguments: ["-v", "win10"]),
        ]
        XCTAssertEqual(try VermouthJSON.decode([LaunchTarget].self, from: try VermouthJSON.encode(targets)), targets)

        let discovered = DiscoveredExecutable(
            name: "Game",
            executablePath: "/tmp/Prefix/Drive_C/Game.exe",
            arguments: ["-fullscreen"],
            workingDirectory: "/tmp/Prefix/Drive_C",
            source: .startMenuShortcut,
            architecture: .x86_32
        )
        XCTAssertEqual(discovered.id, "/tmp/prefix/drive_c/game.exe")
        XCTAssertEqual(
            try VermouthJSON.decode(DiscoveredExecutable.self, from: try VermouthJSON.encode(discovered)),
            discovered
        )
    }

    // MARK: - OSVersionInfo.isAtLeast

    func testOSVersionInfoIsAtLeastEdgeCases() throws {
        let sonoma14_0 = OSVersionInfo(major: 14, minor: 0, patch: 0, displayString: "macOS 14.0")
        XCTAssertTrue(sonoma14_0.isAtLeast(major: 13, minor: 9))
        XCTAssertTrue(sonoma14_0.isAtLeast(major: 14, minor: 0))
        XCTAssertTrue(sonoma14_0.isAtLeast(major: 14))
        XCTAssertFalse(sonoma14_0.isAtLeast(major: 14, minor: 1))
        XCTAssertFalse(sonoma14_0.isAtLeast(major: 15, minor: 0))

        let ventura13_9 = OSVersionInfo(major: 13, minor: 9, patch: 5, displayString: "macOS 13.9.5")
        XCTAssertFalse(ventura13_9.isAtLeast(major: 14, minor: 0))
        XCTAssertTrue(ventura13_9.isAtLeast(major: 13, minor: 9))
        XCTAssertTrue(ventura13_9.isAtLeast(major: 13, minor: 0))
        XCTAssertFalse(ventura13_9.isAtLeast(major: 13, minor: 10))

        let future26_5_1 = OSVersionInfo(major: 26, minor: 5, patch: 1, displayString: "macOS 26.5.1")
        XCTAssertTrue(future26_5_1.isAtLeast(major: 14, minor: 0))
        XCTAssertTrue(future26_5_1.isAtLeast(major: 26, minor: 5))
        XCTAssertTrue(future26_5_1.isAtLeast(major: 26, minor: 0))
        XCTAssertFalse(future26_5_1.isAtLeast(major: 26, minor: 6))
        XCTAssertFalse(future26_5_1.isAtLeast(major: 27, minor: 0))

        let encoded = try VermouthJSON.encode(future26_5_1)
        let decoded = try VermouthJSON.decode(OSVersionInfo.self, from: encoded)
        XCTAssertEqual(decoded, future26_5_1)
    }
}
