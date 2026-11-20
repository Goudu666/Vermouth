import Foundation

/// 100% Clean-Room 纯 Swift FIPS 180-4 SHA-256 实现，零 CryptoKit 依赖，双端可移植。
public enum PureSHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    /// 增量式 SHA-256 哈希上下文。
    public struct Context: Sendable {
        private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
        private var buffer: [UInt8]
        private var totalByteCount: UInt64

        public init() {
            self.state = (
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
            )
            self.buffer = []
            self.buffer.reserveCapacity(64)
            self.totalByteCount = 0
        }

        public mutating func update(_ data: Data) {
            data.withUnsafeBytes { rawBuffer in
                update(rawBuffer)
            }
        }

        public mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
            let bytePointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            let count = bytes.count
            totalByteCount &+= UInt64(count)
            var offset = 0

            if !buffer.isEmpty {
                let needed = 64 - buffer.count
                let toCopy = min(needed, count)
                buffer.append(contentsOf: UnsafeBufferPointer(start: bytePointer, count: toCopy))
                offset += toCopy
                if buffer.count == 64 {
                    buffer.withUnsafeBufferPointer { blockPtr in
                        if let ptr = blockPtr.baseAddress {
                            Self.compress(state: &state, block: ptr)
                        }
                    }
                    buffer.removeAll(keepingCapacity: true)
                }
            }

            while count - offset >= 64 {
                Self.compress(state: &state, block: bytePointer.advanced(by: offset))
                offset += 64
            }

            if offset < count {
                buffer.append(
                    contentsOf: UnsafeBufferPointer(
                        start: bytePointer.advanced(by: offset),
                        count: count - offset
                    )
                )
            }
        }

        public mutating func finalize() -> [UInt8] {
            let bitLength = totalByteCount &* 8
            buffer.append(0x80)

            if buffer.count > 56 {
                while buffer.count < 64 {
                    buffer.append(0)
                }
                buffer.withUnsafeBufferPointer { blockPtr in
                    if let ptr = blockPtr.baseAddress {
                        Self.compress(state: &state, block: ptr)
                    }
                }
                buffer.removeAll(keepingCapacity: true)
            }

            while buffer.count < 56 {
                buffer.append(0)
            }

            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8((bitLength >> shift) & 0xff))
            }

            buffer.withUnsafeBufferPointer { blockPtr in
                if let ptr = blockPtr.baseAddress {
                    Self.compress(state: &state, block: ptr)
                }
            }
            buffer.removeAll(keepingCapacity: false)

            let words = [state.0, state.1, state.2, state.3, state.4, state.5, state.6, state.7]
            var digest: [UInt8] = []
            digest.reserveCapacity(32)
            for word in words {
                digest.append(UInt8((word >> 24) & 0xff))
                digest.append(UInt8((word >> 16) & 0xff))
                digest.append(UInt8((word >> 8) & 0xff))
                digest.append(UInt8(word & 0xff))
            }
            return digest
        }

        public mutating func finalizeHex() -> String {
            let digest = finalize()
            var hexBytes: [UInt8] = []
            hexBytes.reserveCapacity(64)
            for byte in digest {
                hexBytes.append(PureSHA256.hexAlphabet[Int(byte >> 4)])
                hexBytes.append(PureSHA256.hexAlphabet[Int(byte & 0x0f)])
            }
            return String(decoding: hexBytes, as: UTF8.self)
        }

        @inline(__always)
        private static func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
            (value >> bits) | (value << (32 - bits))
        }

        private static func compress(
            state: inout (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
            block: UnsafePointer<UInt8>
        ) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = i * 4
                w[i] = (UInt32(block[j]) << 24)
                    | (UInt32(block[j + 1]) << 16)
                    | (UInt32(block[j + 2]) << 8)
                    | UInt32(block[j + 3])
            }

            for i in 16..<64 {
                let w15 = w[i - 15]
                let w2 = w[i - 2]
                let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
                let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var (a, b, c, d, e, f, g, h) = state

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ ((~e) & g)
                let temp1 = h &+ s1 &+ ch &+ PureSHA256.roundConstants[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            state.0 = state.0 &+ a
            state.1 = state.1 &+ b
            state.2 = state.2 &+ c
            state.3 = state.3 &+ d
            state.4 = state.4 &+ e
            state.5 = state.5 &+ f
            state.6 = state.6 &+ g
            state.7 = state.7 &+ h
        }
    }

    /// 计算内存 `Data` 的 SHA-256（64 位小写十六进制）。
    public static func hash(data: Data) -> String {
        var context = Context()
        context.update(data)
        return context.finalizeHex()
    }

    /// 计算 UTF-8 字符串的 SHA-256（64 位小写十六进制）。
    public static func hash(string: String) -> String {
        hash(data: Data(string.utf8))
    }

    /// 以 64KB 流式分块读取文件并计算 SHA-256（64 位小写十六进制）。
    public static func hashFile(at url: URL) throws -> String {
        let fileURL = url.standardizedFileURL
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw VermouthError.ioError(
                operation: "openFile",
                path: fileURL.path,
                underlyingDescription: error.localizedDescription
            )
        }
        defer {
            try? handle.close()
        }

        var context = Context()
        let chunkSize = 65_536
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: chunkSize)
            } catch {
                throw VermouthError.ioError(
                    operation: "readFile",
                    path: fileURL.path,
                    underlyingDescription: error.localizedDescription
                )
            }
            guard let data = chunk, !data.isEmpty else {
                break
            }
            context.update(data)
        }
        return context.finalizeHex()
    }
}
