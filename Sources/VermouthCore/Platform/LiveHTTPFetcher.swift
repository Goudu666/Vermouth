import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// 基于 `URLSession` 的生产网络拉取与增量进度下载实现（兼容 macOS 与 Linux `FoundationNetworking`）。
public final class LiveHTTPFetcher: HTTPFetching, Sendable {
    private static let defaultUserAgent = "Vermouth/0.1.0"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if Task.isCancelled {
            throw CancellationError()
        }

        let taskBox = SessionTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let once = DataContinuationBox(continuation)
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        if let urlError = error as? URLError, urlError.code == .cancelled {
                            once.resume(throwing: CancellationError())
                        } else {
                            once.resume(
                                throwing: VermouthError.networkRequestFailed(
                                    url: url.absoluteString,
                                    statusCode: (response as? HTTPURLResponse)?.statusCode,
                                    reason: error.localizedDescription
                                )
                            )
                        }
                        return
                    }

                    if let httpResponse = response as? HTTPURLResponse,
                       !(200..<300).contains(httpResponse.statusCode)
                    {
                        once.resume(
                            throwing: VermouthError.networkRequestFailed(
                                url: url.absoluteString,
                                statusCode: httpResponse.statusCode,
                                reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                            )
                        )
                        return
                    }

                    once.resume(returning: data ?? Data())
                }
                taskBox.attachAndResume(task)
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    public func download(
        from url: URL,
        to destination: URL,
        progress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws {
        if Task.isCancelled {
            throw CancellationError()
        }

        var request = URLRequest(url: url)
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let delegate = StreamingDownloadDelegate(
            sourceURL: url,
            destinationURL: destination.standardizedFileURL,
            progressHandler: progress
        )
        let downloadSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let taskBox = SessionTaskBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                let task = downloadSession.downloadTask(with: request)
                taskBox.attachAndResume(task)
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}

// MARK: - Swift 6 URLSession Concurrency Helpers

private final class SessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func attachAndResume(_ task: URLSessionTask) {
        let shouldCancel: Bool = lock.withLock {
            self.task = task
            return cancelled
        }
        task.resume()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let activeTask: URLSessionTask? = lock.withLock {
            cancelled = true
            return task
        }
        activeTask?.cancel()
    }
}

private final class DataContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Data) {
        let cont: CheckedContinuation<Data, Error>? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        let cont: CheckedContinuation<Data, Error>? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        cont?.resume(throwing: error)
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let destinationURL: URL
    private let progressHandler: (@Sendable (DownloadProgress) -> Void)?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var didMoveFile = false
    private var moveError: Error?

    init(
        sourceURL: URL,
        destinationURL: URL,
        progressHandler: (@Sendable (DownloadProgress) -> Void)?
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressHandler?(
            DownloadProgress(
                bytesWritten: totalBytesWritten,
                totalBytesExpected: expected
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode)
        {
            let statusError = VermouthError.networkRequestFailed(
                url: sourceURL.absoluteString,
                statusCode: httpResponse.statusCode,
                reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
            lock.withLock {
                moveError = statusError
            }
            return
        }

        let fileManager = FileManager.default
        let parentDirectory = destinationURL.deletingLastPathComponent()
        let siblingTemp = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).download.\(UUID().uuidString)",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            do {
                try fileManager.moveItem(at: location, to: siblingTemp)
            } catch {
                // 跨文件系统/挂载点移动失败时回退至拷贝再原子重命名
                try fileManager.copyItem(at: location, to: siblingTemp)
            }

            let renameErrno: Int32 = siblingTemp.withUnsafeFileSystemRepresentation { src in
                destinationURL.withUnsafeFileSystemRepresentation { dst in
                    guard let src, let dst else { return EINVAL }
                    if rename(src, dst) == 0 {
                        return 0
                    }
                    return errno
                }
            }

            if renameErrno != 0 {
                let message: String
                if let cStr = strerror(renameErrno) {
                    message = String(cString: cStr)
                } else {
                    message = "Unknown POSIX error"
                }
                throw VermouthError.ioError(
                    operation: "rename",
                    path: destinationURL.path,
                    underlyingDescription: "\(message) (errno \(renameErrno))"
                )
            }

            lock.withLock {
                didMoveFile = true
            }
        } catch {
            try? fileManager.removeItem(at: siblingTemp)
            let wrapped: Error
            if error is VermouthError {
                wrapped = error
            } else {
                wrapped = VermouthError.ioError(
                    operation: "saveDownload",
                    path: destinationURL.path,
                    underlyingDescription: error.localizedDescription
                )
            }
            lock.withLock {
                moveError = wrapped
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        session.finishTasksAndInvalidate()

        let (cont, moved, recordedMoveError): (CheckedContinuation<Void, Error>?, Bool, Error?) = lock.withLock {
            let current = continuation
            continuation = nil
            return (current, didMoveFile, moveError)
        }
        guard let cont else { return }

        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                cont.resume(throwing: CancellationError())
            } else {
                cont.resume(
                    throwing: VermouthError.networkRequestFailed(
                        url: sourceURL.absoluteString,
                        statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                        reason: error.localizedDescription
                    )
                )
            }
            return
        }

        if let recordedMoveError {
            cont.resume(throwing: recordedMoveError)
            return
        }

        if let httpResponse = task.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode)
        {
            cont.resume(
                throwing: VermouthError.networkRequestFailed(
                    url: sourceURL.absoluteString,
                    statusCode: httpResponse.statusCode,
                    reason: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                )
            )
            return
        }

        if !moved {
            cont.resume(
                throwing: VermouthError.networkRequestFailed(
                    url: sourceURL.absoluteString,
                    statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                    reason: "下载完成但未生成本地临时文件"
                )
            )
            return
        }

        cont.resume(returning: ())
    }
}
