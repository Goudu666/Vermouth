import Foundation
import XCTest
@testable import VermouthCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [DownloadProgress] = []

    func record(_ progress: DownloadProgress) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(progress)
    }

    func snapshot() -> [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

final class GraphicsStackManagerTests: XCTestCase {
    private var tempDir: URL!
    private var vermouthHome: URL!
    private var paths: VermouthPaths!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = try createTempDirectory(prefix: "vermouth-graphics-test")
        vermouthHome = tempDir.appendingPathComponent("vermouth-home", isDirectory: true)
        paths = VermouthPaths(baseDirectory: vermouthHome)
        try paths.ensureBaseDirectories()
    }

    override func tearDownWithError() throws {
        removeTempDirectory(tempDir)
        tempDir = nil
        vermouthHome = nil
        paths = nil
        try super.tearDownWithError()
    }

    // MARK: - Remote GitHub Releases Fetching

    func testFetchAvailableReleasesParsesDXMTAndDXVKAndFiltersAssets() async throws {
        let dxmtURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/3Shain/dxmt/releases?per_page=10"))
        let dxvkURL = try XCTUnwrap(URL(string: "https://api.github.com/repos/Gcenx/DXVK-macOS/releases?per_page=10"))

        let dxmtJSON = """
        [
          {
            "tag_name": "v0.80",
            "draft": false,
            "published_at": "2026-02-10T08:30:00Z",
            "assets": [
              {
                "name": "dxmt-v0.80-builtin.tar.gz",
                "size": 2457600,
                "browser_download_url": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
              },
              {
                "name": "dxmt-v0.80-checksums.txt",
                "size": 256,
                "browser_download_url": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-checksums.txt"
              }
            ]
          },
          {
            "tag_name": "v0.81-draft",
            "draft": true,
            "published_at": "2026-02-12T00:00:00Z",
            "assets": [
              {
                "name": "dxmt-v0.81-builtin.tar.gz",
                "size": 1024,
                "browser_download_url": "https://github.com/3Shain/dxmt/releases/download/v0.81-draft/dxmt-v0.81-builtin.tar.gz"
              }
            ]
          }
        ]
        """

        let dxvkJSON = """
        [
          {
            "tag_name": "v1.10.3-20230507-repack",
            "draft": false,
            "published_at": "2023-05-07T15:00:00Z",
            "assets": [
              {
                "name": "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
                "size": 5242880,
                "browser_download_url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"
              },
              {
                "name": "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
                "size": 4194304,
                "browser_download_url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
              },
              {
                "name": "README.md",
                "size": 512,
                "browser_download_url": "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/README.md"
              }
            ]
          }
        ]
        """

        let httpFetcher = MockHTTPFetcher(
            responses: [
                dxmtURL: Data(dxmtJSON.utf8),
                dxvkURL: Data(dxvkJSON.utf8),
            ]
        )
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: MockCommandRunner(),
            httpFetcher: httpFetcher
        )

        // WineD3D is Wine built-in -> returns empty list without hitting HTTP
        let wined3dReleases = try await manager.fetchAvailableReleases(for: .wined3d)
        XCTAssertTrue(wined3dReleases.isEmpty)
        XCTAssertTrue(httpFetcher.recordedDataRequests.isEmpty)

        // DXMT release: draft & .txt filtered out, builtin tarball classified as .wineBuiltin
        let dxmtReleases = try await manager.fetchAvailableReleases(for: .dxmt)
        XCTAssertEqual(dxmtReleases.count, 1)
        let dxmt = try XCTUnwrap(dxmtReleases.first)
        XCTAssertEqual(dxmt.backend, .dxmt)
        XCTAssertEqual(dxmt.tagName, "v0.80")
        XCTAssertEqual(dxmt.version, "v0.80")
        XCTAssertEqual(dxmt.assetName, "dxmt-v0.80-builtin.tar.gz")
        XCTAssertEqual(dxmt.format, .wineBuiltin)
        XCTAssertEqual(dxmt.sizeBytes, 2_457_600)
        XCTAssertNotNil(dxmt.publishedAt)
        XCTAssertEqual(
            httpFetcher.recordedDataRequests.first?.headers["Accept"],
            "application/vnd.github+json"
        )

        // DXVK release: both builtin (.wineBuiltin) and native (.nativeDLLs) classified accurately; README skipped
        let dxvkReleases = try await manager.fetchAvailableReleases(for: .dxvk)
        XCTAssertEqual(dxvkReleases.count, 2)

        let dxvkBuiltin = try XCTUnwrap(dxvkReleases.first(where: { $0.format == .wineBuiltin }))
        XCTAssertEqual(dxvkBuiltin.assetName, "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")
        // 同一 tag 下的 builtin 资产必须得到独立版本号，否则安装时会覆盖 repack 包
        XCTAssertEqual(dxvkBuiltin.version, "v1.10.3-20230507-repack-builtin")
        XCTAssertEqual(dxvkBuiltin.expectedPackageID, "dxvk-v1.10.3-20230507-repack-builtin")

        let dxvkNative = try XCTUnwrap(dxvkReleases.first(where: { $0.format == .nativeDLLs }))
        XCTAssertEqual(dxvkNative.assetName, "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")
        // 主资产沿用 tag，保持已安装包 id `dxvk-v1.10.3-20230507-repack` 不变
        XCTAssertEqual(dxvkNative.version, "v1.10.3-20230507-repack")
        XCTAssertEqual(dxvkNative.expectedPackageID, "dxvk-v1.10.3-20230507-repack")
    }

    func testReleaseAssetVersionDisambiguatesAssetsSharingOneTag() {
        // 单资产 release：沿用 tag（DXMT 包 id 仍为 dxmt-v0.80）
        XCTAssertEqual(
            GraphicsStackManager.releaseAssetVersion(
                tagName: "v0.80", assetName: "dxmt-v0.80-builtin.tar.gz", releaseHasMultipleArchives: false
            ),
            "v0.80"
        )
        XCTAssertEqual(
            GraphicsStackManager.releaseAssetVersion(
                tagName: "v1.10.3-20230402",
                assetName: "dxvk-macOS-async-v1.10.3-20230402-CrossOver.tar.gz",
                releaseHasMultipleArchives: true
            ),
            "v1.10.3-20230402-CrossOver"
        )
        XCTAssertEqual(
            GraphicsStackManager.releaseAssetVersion(
                tagName: "v1.10.3-20230402",
                assetName: "dxvk-macOS-async-v1.10.3-20230402.tar.gz",
                releaseHasMultipleArchives: true
            ),
            "v1.10.3-20230402"
        )
        XCTAssertEqual(
            GraphicsStackManager.releaseAssetVersion(
                tagName: "nightly", assetName: "dxvk-macos-latest.tar.xz", releaseHasMultipleArchives: true
            ),
            "dxvk-macos-latest"
        )
    }

    func testRemoteReleaseIsInstalledMatchesExactAssetNotWholeTag() throws {
        let base = "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/"
        let repack = RemoteGraphicsRelease(
            backend: .dxvk,
            tagName: "v1.10.3-20230507-repack",
            version: "v1.10.3-20230507-repack",
            assetName: "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz",
            downloadURL: try XCTUnwrap(URL(string: base + "dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz")),
            format: .nativeDLLs
        )
        let builtin = RemoteGraphicsRelease(
            backend: .dxvk,
            tagName: "v1.10.3-20230507-repack",
            version: "v1.10.3-20230507-repack-builtin",
            assetName: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz",
            downloadURL: try XCTUnwrap(URL(string: base + "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")),
            format: .wineBuiltin
        )
        // 与用户真机 index.json 中的记录一致：只装了 -repack
        let installedRepack = GraphicsLayerPackage(
            id: "dxvk-v1.10.3-20230507-repack",
            backend: .dxvk,
            version: "v1.10.3-20230507-repack",
            format: .nativeDLLs,
            installPath: "/tmp/dxvk/v1.10.3-20230507-repack",
            sourceURL: repack.downloadURL.absoluteString,
            containedDLLs: ["d3d10core", "d3d11"]
        )
        XCTAssertTrue(repack.isInstalled(in: [installedRepack]))
        XCTAssertFalse(builtin.isInstalled(in: [installedRepack]))

        // 本地导入的包没有来源 URL：按 id + 格式匹配
        var locallyImported = installedRepack
        locallyImported.sourceURL = nil
        XCTAssertTrue(repack.isInstalled(in: [locallyImported]))
        XCTAssertFalse(builtin.isInstalled(in: [locallyImported]))
    }

    func testDXVKPackageMissingDXGIIsFlagged() {
        func package(_ dlls: [String], backend: GraphicsBackend = .dxvk, format: GraphicsArchiveFormat = .nativeDLLs) -> GraphicsLayerPackage {
            GraphicsLayerPackage(
                id: "pkg", backend: backend, version: "v1", format: format, installPath: "/tmp/pkg", containedDLLs: dlls
            )
        }
        XCTAssertTrue(package(["d3d10core", "d3d11"]).isDXVKMissingDXGI)
        XCTAssertFalse(package(["d3d10core", "d3d11", "d3d9", "dxgi"]).isDXVKMissingDXGI)
        XCTAssertFalse(package(["d3d9"]).isDXVKMissingDXGI)
        XCTAssertFalse(package(["d3d11", "winemetal"], backend: .dxmt).isDXVKMissingDXGI)

        let warning = try? XCTUnwrap(package(["d3d10core", "d3d11"]).missingDXGIWarning)
        XCTAssertEqual(warning?.category, .graphicsPackageIncomplete)
        XCTAssertEqual(warning?.severity, .warning)
        XCTAssertEqual(warning?.quickFix, .switchGraphicsBackend(.wined3d))
        XCTAssertNil(package(["d3d11", "dxgi"]).missingDXGIWarning)
    }

    // MARK: - Local Archive Import & Real tar.gz Unwrapping

    func testImportLocalDXMTBuiltinTarGzUnwrapsWrapperAndPersistsIndex() async throws {
        let archiveURL = try await createDXMTBuiltinTarGz(
            archiveName: "dxmt-v0.80-builtin.tar.gz",
            wrapperDirName: "dxmt-v0.80"
        )
        let expectedSHA256 = try PureSHA256.hashFile(at: archiveURL)

        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )

        let pkg = try await manager.importLocalArchive(
            at: archiveURL.path,
            backend: .dxmt,
            version: "v0.80"
        )

        XCTAssertEqual(pkg.id, "dxmt-v0.80")
        XCTAssertEqual(pkg.backend, .dxmt)
        XCTAssertEqual(pkg.version, "v0.80")
        XCTAssertEqual(pkg.format, .wineBuiltin)
        XCTAssertEqual(pkg.containedDLLs, ["d3d10core", "d3d11", "dxgi", "winemetal"])
        XCTAssertEqual(pkg.sha256, expectedSHA256)

        // Wrapper directory `dxmt-v0.80/` must be stripped so installPath directly contains layout subdirs
        let installURL = URL(fileURLWithPath: pkg.installPath, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installURL.appendingPathComponent("x86_64-unix/winemetal.so").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installURL.appendingPathComponent("x86_64-windows/d3d11.dll").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installURL.appendingPathComponent("i386-windows/d3d11.dll").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installURL.appendingPathComponent("dxmt-v0.80").path
            )
        )

        // Persisted in graphics/index.json and reloadable via a fresh GraphicsStackManager
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.graphicsIndexURL.path))
        let reloadedManager = GraphicsStackManager(
            paths: paths,
            commandRunner: MockCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let installed = try reloadedManager.listInstalledPackages()
        XCTAssertEqual(installed, [pkg])
    }

    func testImportLocalDXVKNativeTarGzDetectsActualContainedDLLsOnly() async throws {
        // L-002: Only DLLs actually present in the archive appear in containedDLLs (no hardcoded d3d9/dxgi).
        let archiveURL = try await createDXVKNativeTarGz(
            archiveName: "dxvk-1.10.3.tar.gz",
            wrapperDirName: "dxvk-1.10.3"
        )

        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )

        let pkg = try await manager.importLocalArchive(
            at: archiveURL.path,
            backend: .dxvk,
            version: "1.10.3"
        )

        XCTAssertEqual(pkg.id, "dxvk-1.10.3")
        XCTAssertEqual(pkg.backend, .dxvk)
        XCTAssertEqual(pkg.format, .nativeDLLs)
        XCTAssertEqual(pkg.containedDLLs, ["d3d10core", "d3d11"])
        XCTAssertFalse(pkg.containedDLLs.contains("d3d9"))
        XCTAssertFalse(pkg.containedDLLs.contains("dxgi"))

        let installURL = URL(fileURLWithPath: pkg.installPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installURL.appendingPathComponent("x64/d3d11.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installURL.appendingPathComponent("x32/d3d10core.dll").path))
    }

    func testInstallPackageDownloadsViaHTTPFetcherAndReportsProgress() async throws {
        let archiveURL = try await createDXMTBuiltinTarGz(
            archiveName: "dxmt-v0.80-builtin.tar.gz",
            wrapperDirName: "dxmt-v0.80"
        )
        let archiveData = try Data(contentsOf: archiveURL)
        let downloadURL = try XCTUnwrap(
            URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")
        )
        let release = RemoteGraphicsRelease(
            backend: .dxmt,
            tagName: "v0.80",
            version: "v0.80",
            assetName: "dxmt-v0.80-builtin.tar.gz",
            downloadURL: downloadURL,
            sizeBytes: Int64(archiveData.count),
            format: .wineBuiltin
        )

        let httpFetcher = MockHTTPFetcher(responses: [downloadURL: archiveData])
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: httpFetcher
        )
        let progressRecorder = ProgressRecorder()

        let installed = try await manager.installPackage(from: release) { progress in
            progressRecorder.record(progress)
        }

        XCTAssertEqual(installed.id, "dxmt-v0.80")
        XCTAssertEqual(installed.sourceURL, downloadURL.absoluteString)
        XCTAssertEqual(installed.format, .wineBuiltin)
        XCTAssertEqual(httpFetcher.recordedDownloadRequests.count, 1)
        XCTAssertEqual(progressRecorder.snapshot().last?.fractionCompleted, 1.0)
    }

    // MARK: - Archive Security (Tar-Slip & Symlink Escape)

    func testImportLocalArchiveRejectsTarSlipBeforeExtraction() async throws {
        let dummyArchiveURL = tempDir.appendingPathComponent("malicious.tar.gz", isDirectory: false)
        try Data("fake-tarball-bytes".utf8).write(to: dummyArchiveURL)

        // Case 1: Relative parent traversal `../../etc/evil.dll`
        let relativeTraversalRunner = MockCommandRunner(
            resultsByExecutable: [
                "/usr/bin/tar": CommandResult(
                    exitCode: 0,
                    stdout: "dxmt-v0.80/x86_64-windows/d3d11.dll\n../../etc/evil.dll\n",
                    stderr: ""
                ),
            ]
        )
        let manager1 = GraphicsStackManager(
            paths: paths,
            commandRunner: relativeTraversalRunner,
            httpFetcher: MockHTTPFetcher()
        )
        do {
            _ = try await manager1.importLocalArchive(
                at: dummyArchiveURL.path,
                backend: .dxmt,
                version: "v0.80"
            )
            XCTFail("Expected VermouthError.invalidGraphicsArchive for '..' traversal")
        } catch let error as VermouthError {
            guard case .invalidGraphicsArchive = error else {
                XCTFail("Expected invalidGraphicsArchive, got \(error)")
                return
            }
        }
        // Only `tar -tf` must have run; `tar -xf` must NEVER be executed!
        XCTAssertEqual(relativeTraversalRunner.recordedRequests.count, 1)
        XCTAssertEqual(relativeTraversalRunner.recordedRequests.first?.arguments.first, "-tf")

        // Case 2: Absolute path entry `/abs/evil.dll`
        let absolutePathRunner = MockCommandRunner(
            resultsByExecutable: [
                "/usr/bin/tar": CommandResult(
                    exitCode: 0,
                    stdout: "/abs/evil.dll\n",
                    stderr: ""
                ),
            ]
        )
        let manager2 = GraphicsStackManager(
            paths: paths,
            commandRunner: absolutePathRunner,
            httpFetcher: MockHTTPFetcher()
        )
        do {
            _ = try await manager2.importLocalArchive(
                at: dummyArchiveURL.path,
                backend: .dxmt,
                version: "v0.80"
            )
            XCTFail("Expected VermouthError.invalidGraphicsArchive for absolute path entry")
        } catch let error as VermouthError {
            guard case .invalidGraphicsArchive = error else {
                XCTFail("Expected invalidGraphicsArchive, got \(error)")
                return
            }
        }
        XCTAssertEqual(absolutePathRunner.recordedRequests.count, 1)
        XCTAssertEqual(absolutePathRunner.recordedRequests.first?.arguments.first, "-tf")
    }

    func testImportLocalArchiveRejectsEscapingSymlinkInsideRealTarGz() async throws {
        let stagingRoot = tempDir.appendingPathComponent("symlink-stage", isDirectory: true)
        let dllDir = stagingRoot.appendingPathComponent("dxmt-evil/x86_64-windows", isDirectory: true)
        try FileManager.default.createDirectory(at: dllDir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: dllDir.appendingPathComponent("d3d11.dll"))
        try FileManager.default.createSymbolicLink(
            atPath: dllDir.appendingPathComponent("escape.dll").path,
            withDestinationPath: "../../../../etc/passwd"
        )

        let archiveURL = tempDir.appendingPathComponent("symlink-escape.tar.gz", isDirectory: false)
        let liveRunner = LiveCommandRunner()
        let packResult = try await liveRunner.run(
            CommandRequest(
                executablePath: "/usr/bin/tar",
                arguments: ["-czf", archiveURL.path, "-C", stagingRoot.path, "dxmt-evil"],
                environment: ["COPYFILE_DISABLE": "1"],
                inheritEnvironment: true
            )
        )
        XCTAssertEqual(packResult.exitCode, 0)

        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: liveRunner,
            httpFetcher: MockHTTPFetcher()
        )
        do {
            _ = try await manager.importLocalArchive(
                at: archiveURL.path,
                backend: .dxmt,
                version: "v0.99"
            )
            XCTFail("Expected VermouthError.invalidGraphicsArchive for escaping symlink")
        } catch let error as VermouthError {
            guard case .invalidGraphicsArchive = error else {
                XCTFail("Expected invalidGraphicsArchive, got \(error)")
                return
            }
        }
        XCTAssertTrue(try manager.listInstalledPackages().isEmpty)
    }

    // MARK: - applyBackend Lifecycle & Rollback

    func testApplyBackendWineBuiltinFailsFastOnIncapableEngineWithoutModifyingPrefix() async throws {
        // L-001: Applying wineBuiltin onto an engine lacking WINEDLLPATH_PREPEND must fail fast
        // without touching system32, graphics-state.json, or running wineserver.
        let archiveURL = try await createDXMTBuiltinTarGz(
            archiveName: "dxmt-v0.80-builtin.tar.gz",
            wrapperDirName: "dxmt-v0.80"
        )
        let importer = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let pkg = try await importer.importLocalArchive(at: archiveURL.path, backend: .dxmt, version: "v0.80")

        let bottle = try makeSeededBottle(originalSystem32D3D11: "orig-wine-d3d11", originalSysWow64D3D11: nil)
        let incapableEngine = makeEngine(supportsWineDLLPathPrepend: false)
        let mockRunner = MockCommandRunner()
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: mockRunner,
            httpFetcher: MockHTTPFetcher()
        )

        do {
            _ = try await manager.applyBackend(.dxmt, packageID: pkg.id, to: bottle, engine: incapableEngine)
            XCTFail("Expected VermouthError.engineMissingDLLPathPrepend")
        } catch let error as VermouthError {
            XCTAssertEqual(
                error,
                .engineMissingDLLPathPrepend(engineName: incapableEngine.name, packageID: pkg.id)
            )
        }

        // Prefix DLL, graphics-state.json, and wineserver must remain completely untouched
        let system32D3D11 = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        XCTAssertEqual(try String(contentsOf: system32D3D11, encoding: .utf8), "orig-wine-d3d11")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.bottleGraphicsStateURL(id: bottle.id).path))
        XCTAssertTrue(mockRunner.recordedRequests.isEmpty)
    }

    func testApplyBackendWineBuiltinZeroCopyModeAndConflictWarnings() async throws {
        // L-001 Mode A: Capable engine uses WINEDLLPATH_PREPEND zero-copy (no writes to system32),
        // persists state + bottle config, and surfaces user override conflict warnings.
        let archiveURL = try await createDXMTBuiltinTarGz(
            archiveName: "dxmt-v0.80-builtin.tar.gz",
            wrapperDirName: "dxmt-v0.80"
        )
        let importer = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let pkg = try await importer.importLocalArchive(at: archiveURL.path, backend: .dxmt, version: "v0.80")

        let bottleStore = BottleStore(paths: paths)
        var bottle = try bottleStore.createBottle(name: "DXMT Bottle", engineID: "test-wine-11", initialConfig: nil)
        bottle.config.dllOverrides = [
            DllOverride(dllName: "d3d11", mode: .nativeThenBuiltin, enabled: true),
            DllOverride(dllName: "dinput8", mode: .nativeThenBuiltin, enabled: true),
        ]
        try bottleStore.saveBottle(bottle)

        let system32D3D11 = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
            .appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        try FileManager.default.createDirectory(
            at: system32D3D11.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("orig-wine-d3d11".utf8).write(to: system32D3D11)

        let capableEngine = makeEngine(supportsWineDLLPathPrepend: true)
        let mockRunner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 0, stdout: "", stderr: "")
        )
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: mockRunner,
            httpFetcher: MockHTTPFetcher(),
            bottleStore: bottleStore
        )

        let result = try await manager.applyBackend(.dxmt, packageID: pkg.id, to: bottle, engine: capableEngine)

        XCTAssertEqual(result.record.backend, .dxmt)
        XCTAssertEqual(result.record.packageID, pkg.id)
        XCTAssertEqual(result.record.strategy, .wineDLLPathPrepend)
        XCTAssertTrue(result.record.deployedFiles.isEmpty)
        XCTAssertTrue(result.record.backedUpFiles.isEmpty)
        XCTAssertEqual(result.bottle.config.graphicsBackend, .dxmt)
        XCTAssertEqual(result.bottle.config.graphicsLayerVersionID, pkg.id)

        // Zero writes to system32 and wineserver -k invoked before switch
        XCTAssertEqual(try String(contentsOf: system32D3D11, encoding: .utf8), "orig-wine-d3d11")
        XCTAssertEqual(mockRunner.recordedRequests.count, 1)
        XCTAssertEqual(mockRunner.recordedRequests.first?.executablePath, capableEngine.wineserverPath)
        XCTAssertEqual(mockRunner.recordedRequests.first?.arguments, ["-k"])

        // Conflict warning emitted for d3d11=n,b
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings.first?.category, .dllOverrideConflict)
        XCTAssertEqual(result.warnings.first?.quickFix, .removeConflictingDllOverrides(["d3d11"]))

        // Persisted graphics-state.json & bottle.json match returned value
        XCTAssertEqual(try manager.deploymentState(for: result.bottle), result.record)
        let reloadedBottle = try bottleStore.loadBottle(id: bottle.id)
        XCTAssertEqual(reloadedBottle.config.graphicsBackend, .dxmt)
        XCTAssertEqual(reloadedBottle.config.graphicsLayerVersionID, pkg.id)
    }

    func testApplyBackendNativeDLLsBackupDeployAndByteForByteRollbackToWineD3D() async throws {
        // L-002 Mode B: Deploy native DXVK DLLs with original Wine DLL backups, then switch back to WineD3D
        // and confirm byte-for-byte restoration + removal of newly added DLLs.
        let archiveURL = try await createDXVKNativeTarGz(
            archiveName: "dxvk-1.10.3.tar.gz",
            wrapperDirName: "dxvk-1.10.3"
        )
        let importer = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let pkg = try await importer.importLocalArchive(at: archiveURL.path, backend: .dxvk, version: "1.10.3")

        let bottle = try makeSeededBottle(
            originalSystem32D3D11: "orig-wine-d3d11",
            originalSysWow64D3D11: "orig-wow64-d3d11"
        )
        let engine = makeEngine(supportsWineDLLPathPrepend: false)
        let mockRunner = MockCommandRunner(
            defaultResult: CommandResult(exitCode: 1, stdout: "", stderr: "wineserver: no server running\n")
        )
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: mockRunner,
            httpFetcher: MockHTTPFetcher()
        )

        // 1. Apply DXVK nativeDLLs
        let dxvkResult = try await manager.applyBackend(.dxvk, packageID: pkg.id, to: bottle, engine: engine)
        // 测试包只有 d3d10core/d3d11（同 Gcenx -repack），部署时必须给出缺 dxgi 的警告
        XCTAssertEqual(dxvkResult.warnings.map(\.id), ["dxvk-package-missing-dxgi-\(pkg.id)"])

        XCTAssertEqual(dxvkResult.record.backend, .dxvk)
        XCTAssertEqual(dxvkResult.record.packageID, pkg.id)
        XCTAssertEqual(dxvkResult.record.strategy, .prefixCopyWithBackup)
        XCTAssertEqual(
            dxvkResult.record.deployedFiles,
            [
                "drive_c/windows/system32/d3d10core.dll",
                "drive_c/windows/system32/d3d11.dll",
                "drive_c/windows/syswow64/d3d10core.dll",
                "drive_c/windows/syswow64/d3d11.dll",
            ]
        )
        XCTAssertEqual(
            Set(dxvkResult.record.backedUpFiles.keys),
            Set([
                "drive_c/windows/system32/d3d11.dll",
                "drive_c/windows/syswow64/d3d11.dll",
            ])
        )
        XCTAssertEqual(dxvkResult.bottle.config.graphicsBackend, .dxvk)
        XCTAssertEqual(dxvkResult.bottle.config.graphicsLayerVersionID, pkg.id)

        let prefixURL = URL(fileURLWithPath: bottle.prefixPath, isDirectory: true)
        let sys32D3D11 = prefixURL.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        let sys32D3D10 = prefixURL.appendingPathComponent("drive_c/windows/system32/d3d10core.dll")
        let wow64D3D11 = prefixURL.appendingPathComponent("drive_c/windows/syswow64/d3d11.dll")
        let wow64D3D10 = prefixURL.appendingPathComponent("drive_c/windows/syswow64/d3d10core.dll")

        XCTAssertEqual(try String(contentsOf: sys32D3D11, encoding: .utf8), "dxvk-x64-d3d11")
        XCTAssertEqual(try String(contentsOf: sys32D3D10, encoding: .utf8), "dxvk-x64-d3d10core")
        XCTAssertEqual(try String(contentsOf: wow64D3D11, encoding: .utf8), "dxvk-x32-d3d11")
        XCTAssertEqual(try String(contentsOf: wow64D3D10, encoding: .utf8), "dxvk-x32-d3d10core")

        // Verify backups were created on disk with original Wine DLL bytes
        let backupsDir = paths.bottleBackupsDirectory(id: bottle.id)
        let sys32BackupRel = try XCTUnwrap(dxvkResult.record.backedUpFiles["drive_c/windows/system32/d3d11.dll"])
        let wow64BackupRel = try XCTUnwrap(dxvkResult.record.backedUpFiles["drive_c/windows/syswow64/d3d11.dll"])
        XCTAssertEqual(
            try String(contentsOf: backupsDir.appendingPathComponent(sys32BackupRel), encoding: .utf8),
            "orig-wine-d3d11"
        )
        XCTAssertEqual(
            try String(contentsOf: backupsDir.appendingPathComponent(wow64BackupRel), encoding: .utf8),
            "orig-wow64-d3d11"
        )
        XCTAssertEqual(try manager.deploymentState(for: dxvkResult.bottle), dxvkResult.record)

        // 2. Roll back to WineD3D -> originals restored byte-for-byte, newly added d3d10core.dll deleted
        let rollbackResult = try await manager.applyBackend(
            .wined3d,
            packageID: nil,
            to: dxvkResult.bottle,
            engine: engine
        )

        XCTAssertEqual(rollbackResult.record.backend, .wined3d)
        XCTAssertNil(rollbackResult.record.packageID)
        XCTAssertEqual(rollbackResult.record.strategy, .wined3dBuiltin)
        XCTAssertTrue(rollbackResult.record.deployedFiles.isEmpty)
        XCTAssertTrue(rollbackResult.record.backedUpFiles.isEmpty)
        XCTAssertEqual(rollbackResult.bottle.config.graphicsBackend, .wined3d)
        XCTAssertNil(rollbackResult.bottle.config.graphicsLayerVersionID)

        XCTAssertEqual(try String(contentsOf: sys32D3D11, encoding: .utf8), "orig-wine-d3d11")
        XCTAssertEqual(try String(contentsOf: wow64D3D11, encoding: .utf8), "orig-wow64-d3d11")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sys32D3D10.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wow64D3D10.path))
        XCTAssertEqual(try manager.deploymentState(for: rollbackResult.bottle), rollbackResult.record)
    }

    func testApplyBackendNativeDLLsWithDXGIHasNoMissingDXGIWarning() async throws {
        let archiveURL = try await createDXVKNativeTarGz(
            archiveName: "dxvk-1.10.3-full.tar.gz",
            wrapperDirName: "dxvk-1.10.3-full",
            includeDXGI: true
        )
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let pkg = try await manager.importLocalArchive(at: archiveURL.path, backend: .dxvk, version: "1.10.3-full")
        XCTAssertTrue(pkg.containedDLLs.contains("dxgi"))

        let bottle = try makeSeededBottle(originalSystem32D3D11: nil, originalSysWow64D3D11: nil)
        let applyManager = GraphicsStackManager(
            paths: paths,
            commandRunner: MockCommandRunner(
                defaultResult: CommandResult(exitCode: 1, stdout: "", stderr: "wineserver: no server running\n")
            ),
            httpFetcher: MockHTTPFetcher()
        )
        let result = try await applyManager.applyBackend(
            .dxvk, packageID: pkg.id, to: bottle, engine: makeEngine(supportsWineDLLPathPrepend: true)
        )
        XCTAssertTrue(result.warnings.isEmpty)
    }

    // MARK: - Package Removal Protection

    func testRemovePackageRefusesWhenInUseAndSucceedsAfterSwitchToWineD3D() async throws {
        let archiveURL = try await createDXMTBuiltinTarGz(
            archiveName: "dxmt-v0.80-builtin.tar.gz",
            wrapperDirName: "dxmt-v0.80"
        )
        let manager = GraphicsStackManager(
            paths: paths,
            commandRunner: LiveCommandRunner(),
            httpFetcher: MockHTTPFetcher()
        )
        let pkg = try await manager.importLocalArchive(at: archiveURL.path, backend: .dxmt, version: "v0.80")

        var activeBottle = try makeSeededBottle(originalSystem32D3D11: nil, originalSysWow64D3D11: nil)
        activeBottle.name = "Cyberpunk Bottle"
        activeBottle.config.graphicsBackend = .dxmt
        activeBottle.config.graphicsLayerVersionID = pkg.id

        // Refuses deletion while referenced by an active bottle
        XCTAssertThrowsError(try manager.removePackage(id: pkg.id, activeBottles: [activeBottle])) { error in
            guard let vermouthError = error as? VermouthError else {
                XCTFail("Expected VermouthError, got \(error)")
                return
            }
            XCTAssertEqual(
                vermouthError,
                .graphicsPackageInUse(id: pkg.id, bottleNames: ["Cyberpunk Bottle"])
            )
        }
        XCTAssertEqual(try manager.listInstalledPackages().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pkg.installPath))

        // Once bottle switches back to .wined3d, removal succeeds and cleans directory + index
        activeBottle.config.graphicsBackend = .wined3d
        activeBottle.config.graphicsLayerVersionID = nil

        try manager.removePackage(id: pkg.id, activeBottles: [activeBottle])
        XCTAssertTrue(try manager.listInstalledPackages().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pkg.installPath))

        // Second removal throws graphicsPackageNotFound
        XCTAssertThrowsError(try manager.removePackage(id: pkg.id, activeBottles: [])) { error in
            XCTAssertEqual(error as? VermouthError, .graphicsPackageNotFound(id: pkg.id))
        }
    }

    // MARK: - Fixture & Real Archive Builders

    private func createDXMTBuiltinTarGz(archiveName: String, wrapperDirName: String) async throws -> URL {
        let stagingRoot = tempDir.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        let wrapperDir = stagingRoot.appendingPathComponent(wrapperDirName, isDirectory: true)
        let unixDir = wrapperDir.appendingPathComponent("x86_64-unix", isDirectory: true)
        let x64WinDir = wrapperDir.appendingPathComponent("x86_64-windows", isDirectory: true)
        let x32WinDir = wrapperDir.appendingPathComponent("i386-windows", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: x64WinDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: x32WinDir, withIntermediateDirectories: true)

        try Data("winemetal-unix-so".utf8).write(to: unixDir.appendingPathComponent("winemetal.so"))
        for dllName in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
            try Data("dxmt-x64-\(dllName)".utf8).write(to: x64WinDir.appendingPathComponent(dllName))
        }
        try Data("dxmt-i386-d3d11".utf8).write(to: x32WinDir.appendingPathComponent("d3d11.dll"))

        let archiveURL = tempDir.appendingPathComponent(archiveName, isDirectory: false)
        let result = try await LiveCommandRunner().run(
            CommandRequest(
                executablePath: "/usr/bin/tar",
                arguments: ["-czf", archiveURL.path, "-C", stagingRoot.path, wrapperDirName],
                environment: ["COPYFILE_DISABLE": "1"],
                inheritEnvironment: true
            )
        )
        XCTAssertEqual(result.exitCode, 0, "Failed to build DXMT test archive: \(result.stderr)")
        return archiveURL
    }

    private func createDXVKNativeTarGz(
        archiveName: String,
        wrapperDirName: String,
        includeDXGI: Bool = false
    ) async throws -> URL {
        let stagingRoot = tempDir.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        let wrapperDir = stagingRoot.appendingPathComponent(wrapperDirName, isDirectory: true)
        let x64Dir = wrapperDir.appendingPathComponent("x64", isDirectory: true)
        let x32Dir = wrapperDir.appendingPathComponent("x32", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: x64Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: x32Dir, withIntermediateDirectories: true)

        try Data("dxvk-x64-d3d11".utf8).write(to: x64Dir.appendingPathComponent("d3d11.dll"))
        try Data("dxvk-x64-d3d10core".utf8).write(to: x64Dir.appendingPathComponent("d3d10core.dll"))
        try Data("dxvk-x32-d3d11".utf8).write(to: x32Dir.appendingPathComponent("d3d11.dll"))
        try Data("dxvk-x32-d3d10core".utf8).write(to: x32Dir.appendingPathComponent("d3d10core.dll"))
        if includeDXGI {
            try Data("dxvk-x64-dxgi".utf8).write(to: x64Dir.appendingPathComponent("dxgi.dll"))
            try Data("dxvk-x32-dxgi".utf8).write(to: x32Dir.appendingPathComponent("dxgi.dll"))
        }

        let archiveURL = tempDir.appendingPathComponent(archiveName, isDirectory: false)
        let result = try await LiveCommandRunner().run(
            CommandRequest(
                executablePath: "/usr/bin/tar",
                arguments: ["-czf", archiveURL.path, "-C", stagingRoot.path, wrapperDirName],
                environment: ["COPYFILE_DISABLE": "1"],
                inheritEnvironment: true
            )
        )
        XCTAssertEqual(result.exitCode, 0, "Failed to build DXVK test archive: \(result.stderr)")
        return archiveURL
    }

    private func makeSeededBottle(
        originalSystem32D3D11: String?,
        originalSysWow64D3D11: String?
    ) throws -> Bottle {
        let id = UUID()
        let bottleDir = paths.bottleDirectory(id: id)
        let prefixURL = paths.bottlePrefixURL(id: id)
        let fm = FileManager.default
        try fm.createDirectory(at: bottleDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.bottleBackupsDirectory(id: id), withIntermediateDirectories: true)

        if let content = originalSystem32D3D11 {
            let sys32 = prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
            try fm.createDirectory(at: sys32, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: sys32.appendingPathComponent("d3d11.dll"))
        }
        if let content = originalSysWow64D3D11 {
            let syswow64 = prefixURL.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
            try fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: syswow64.appendingPathComponent("d3d11.dll"))
        }

        return Bottle(
            id: id,
            name: "Graphics Test Bottle",
            createdAt: VermouthJSON.currentTimestamp(),
            updatedAt: VermouthJSON.currentTimestamp(),
            prefixPath: prefixURL.path,
            isExternalPrefix: false,
            config: BottleConfig()
        )
    }

    private func makeEngine(supportsWineDLLPathPrepend: Bool) -> WineEngine {
        let rootPath = tempDir.appendingPathComponent("fake-engine", isDirectory: true).path
        return WineEngine(
            id: supportsWineDLLPathPrepend ? "wine-modern" : "wine-legacy",
            name: supportsWineDLLPathPrepend ? "Wine Stable 11.0 (WoW64)" : "Legacy Wine 8.0",
            rootPath: rootPath,
            wineBinaryPath: "\(rootPath)/bin/wine",
            wineserverPath: "\(rootPath)/bin/wineserver",
            version: supportsWineDLLPathPrepend ? "wine-11.0" : "wine-8.0",
            source: .homebrewCask,
            capabilities: EngineCapabilities(
                supports32Bit: true,
                supports64Bit: true,
                isNewWoW64: supportsWineDLLPathPrepend,
                supportsMSync: true,
                supportsWineDLLPathPrepend: supportsWineDLLPathPrepend
            )
        )
    }
}
