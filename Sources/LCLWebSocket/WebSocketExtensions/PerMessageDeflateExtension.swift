//
// This source file is part of the LCL open source project
//
// Copyright (c) 2021-2024 Local Connectivity Lab and the project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of project authors
//
// SPDX-License-Identifier: Apache-2.0
//

import CLCLWebSocketZlib
import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket

#if (os(Linux) || os(Android)) && !canImport(Musl)
public typealias WindowBitsValue = Int32
#else
public typealias WindowBitsValue = CInt
#endif

/// `PerMessageDeflateExtensionOption` is a `WebSocketExtensionOption` that defines parameters
/// used in the per-message deflate compression extension in RFC 7692.
///
/// It supports configuring the following variables:
///  - isServer: indicate whether this extension option is used by a WebSocket server or client.
///  - serverNoTakeover: the `server_no_context_takeover` parameter used in the extension. By default, this parameter is set to false. If you want to enable this flag, set the value to true.
///  - clientNoTakeover: the `client_no_context_takeover` parameter used in the extension. By default, this parameter is set to false. If you want to enable this flag, set the value to true.
///  - serverMaxWindowBits: the `server_max_window_bits` parameter used in the extension to define the LZ77 sliding window size for the server. By default this value is set to `nil`, which implies that the client can compressed using an LZ77 sliding window of up to 32,768 bytes. This parameter can have a value between 8 and 15, inclusive.
///  - clientMaxWindowBits: the `client_max_window_bits` parameter used in the extension to define the LZ77 sliding window size for the client. By default this value is set to `nil`, which implies that the server server can receive messages compressed using an LZ77 sliding window of up to 32,768 bytes. This parameter can have a value between 8 and 15, inclusive.
///  - maxDecompressionSize: the maximum amount of bytes that can be decompressed from a compressed message. Default value is 16,777,216 bytes.
///  - memoryLevel: the zlib memory footprint. Larger number means more memory footprint and faster speed. Smaller value means less memory footprint and slower speed. This parameter has value between 1 and 9.
public struct PerMessageDeflateExtensionOption: WebSocketExtensionOption {

    public typealias OptionType = Self
    public typealias ExtensionType = PerMessageDeflateCompression

    /// The default max window bits.
    static let defaultMaxWindowBits: Int = 15

    private enum PerMessageDeflateHTTPHeaderFieldType {

        case int(Int)
        case none

        var intVal: Int? {
            switch self {
            case .int(let x): return x
            case .none: return nil
            }
        }
    }

    static let keyword: String = "permessage-deflate"

    let serverNoTakeover: Bool
    let clientNoTakeover: Bool
    let serverMaxWindowBits: Int?
    let clientMaxWindowBits: Int?
    public let reservedBits: WebSocketFrame.ReservedBits
    public var httpHeader: (name: String, val: String) {
        (name: "Sec-WebSocket-Extensions", val: self.description)
    }

    private let maxDecompressionSize: Int
    private let memoryLevel: Int

    let isServer: Bool

    
    /// Initialize the `PerMessageDeflateExtensionOption`.
    /// - Parameters:
    ///   - isServer: indicate whether the extension option is used by WebSocket server or client.
    ///   - serverNoTakeover: the `server_no_context_takeover` parameter used in the extension. By default, this parameter is set to false. If you want to enable this flag, set the value to true.
    ///   - clientNoTakeover: the `client_no_context_takeover` parameter used in the extension. By default, this parameter is set to false. If you want to enable this flag, set the value to true.
    ///   - serverMaxWindowBits: the `server_max_window_bits` parameter used in the extension to define the LZ77 sliding window size for the server. By default this value is set to `nil`, which implies that the client can compressed using an LZ77 sliding window of up to 32,768 bytes. This parameter can have a value between 8 and 15, inclusive.
    ///   - clientMaxWindowBits: the `client_max_window_bits` parameter used in the extension to define the LZ77 sliding window size for the client. By default this value is set to `nil`, which implies that the server server can receive messages compressed using an LZ77 sliding window of up to 32,768 bytes. This parameter can have a value between 8 and 15, inclusive.
    ///   - maxDecompressionSize: the maximum amount of bytes that can be decompressed from a compressed message. Default value is 16,777,216 bytes.
    ///   - memoryLevel: the zlib memory footprint. Larger number means more memory footprint and faster speed. Smaller value means less memory footprint and slower speed. This parameter has value between 1 and 9.
    public init(
        isServer: Bool,
        serverNoTakeover: Bool = false,
        clientNoTakeover: Bool = false,
        serverMaxWindowBits: Int? = nil,
        clientMaxWindowBits: Int? = nil,
        maxDecompressionSize: Int = 1 << 24,
        memoryLevel: Int = 8
    ) {
        if let clientMaxWindowBits = clientMaxWindowBits {
            precondition(clientMaxWindowBits <= 15 && clientMaxWindowBits >= 8)
        }
        if let serverMaxWindowBits = serverMaxWindowBits {
            precondition(serverMaxWindowBits <= 15 && serverMaxWindowBits >= 8)
        }
        precondition(memoryLevel <= 9 && memoryLevel >= 1)
        self.isServer = isServer
        self.serverNoTakeover = serverNoTakeover
        self.clientNoTakeover = clientNoTakeover
        self.serverMaxWindowBits = serverMaxWindowBits
        self.clientMaxWindowBits = clientMaxWindowBits
        self.reservedBits = .rsv1
        self.maxDecompressionSize = maxDecompressionSize
        self.memoryLevel = memoryLevel
    }

    public func negotiate(_ httpHeaders: NIOHTTP1.HTTPHeaders) throws -> PerMessageDeflateExtensionOption? {
        guard self.isServer else {
            preconditionFailure("Should not be called on client side")
        }

        let offers = try self.decodeHTTPHeader(httpHeaders)
        for offer in offers {

            let serverNoTakeoverOffer: Bool
            let clientNoTakeoverOffer: Bool
            var serverMaxWindowBitsOffer: Int? = nil
            var clientMaxWindowBitsOffer: Int? = nil
            switch (self.serverNoTakeover, offer["server_no_context_takeover"]) {
            case (false, Optional.none):
                serverNoTakeoverOffer = false
            default:
                serverNoTakeoverOffer = true
            }

            switch (self.clientNoTakeover, offer["client_no_context_takeover"]) {
            case (true, _):
                clientNoTakeoverOffer = true
            default:
                clientNoTakeoverOffer = false
            }

            switch (self.serverMaxWindowBits, offer["server_max_window_bits"]) {
            case (.none, Optional.none):
                // use default config
                serverMaxWindowBitsOffer = Self.defaultMaxWindowBits
            case (.none, .some):
                // decline this offer
                continue
            case (.some(let config), Optional.none):
                serverMaxWindowBitsOffer = config
            case (.some(let config), .some(let req)):
                switch req {
                case .none:
                    serverMaxWindowBitsOffer = min(config, Self.defaultMaxWindowBits)
                case .int(let val):
                    serverMaxWindowBitsOffer = min(config, val)
                }
            }

            switch (self.clientMaxWindowBits, offer["client_max_window_bits"]) {
            case (.none, Optional.none):
                ()
            case (.none, .some(let req)):
                clientMaxWindowBitsOffer = req.intVal ?? Self.defaultMaxWindowBits
            case (.some, Optional.none):
                // decline the offer
                continue
            case (.some(let config), .some(let req)):
                switch req {
                case .int(let val):
                    clientMaxWindowBitsOffer = min(config, val)
                case .none:
                    clientMaxWindowBitsOffer = min(config, Self.defaultMaxWindowBits)
                }
            }

            return PerMessageDeflateExtensionOption(
                isServer: true,
                serverNoTakeover: serverNoTakeoverOffer,
                clientNoTakeover: clientNoTakeoverOffer,
                serverMaxWindowBits: serverMaxWindowBitsOffer,
                clientMaxWindowBits: clientMaxWindowBitsOffer,
                maxDecompressionSize: self.maxDecompressionSize,
                memoryLevel: self.memoryLevel
            )
        }

        return nil
    }

    public func accept(_ httpHeaders: NIOHTTP1.HTTPHeaders) throws -> PerMessageDeflateExtensionOption? {
        guard !self.isServer else {
            preconditionFailure("Should not be called on the server side")
        }

        let responses = try self.decodeHTTPHeader(httpHeaders)
        if responses.isEmpty {
            return nil
        }

        guard responses.count == 1 else {
            throw WebSocketExtensionError.invalidServerResponse
        }

        guard let response = responses.first else {
            // server does not support compression
            return nil
        }

        let serverNoTakeoverOffer: Bool
        let clientNoTakeoverOffer: Bool
        var serverMaxWindowBitsOffer: Int? = nil
        var clientMaxWindowBitsOffer: Int? = nil
        switch (response["server_no_context_takeover"], self.serverNoTakeover) {
        case (Optional.none, true):
            throw WebSocketExtensionError.invalidServerResponse
        case (.some, _):
            serverNoTakeoverOffer = true
        case (Optional.none, false):
            serverNoTakeoverOffer = false
        }

        switch (response["client_no_context_takeover"], self.clientNoTakeover) {
        case (Optional.none, true):
            clientNoTakeoverOffer = true
        case (.some, _):
            clientNoTakeoverOffer = true
        case (Optional.none, false):
            clientNoTakeoverOffer = false
        }

        switch (response["server_max_window_bits"], self.serverMaxWindowBits) {
        case (Optional.none, .some):
            throw WebSocketExtensionError.invalidServerResponse
        case (.some(let resp), .some(let req)):
            let respVal = resp.intVal ?? Self.defaultMaxWindowBits
            if respVal > req {
                throw WebSocketExtensionError.invalidServerResponse
            }
            serverMaxWindowBitsOffer = respVal
        case (.some(let resp), .none):
            let respVal = resp.intVal ?? Self.defaultMaxWindowBits
            serverMaxWindowBitsOffer = respVal
        case (Optional.none, .none):
            ()
        }

        switch (response["client_max_window_bits"], self.clientMaxWindowBits) {
        case (Optional.none, .none):
            ()
        case (.some, .none):
            throw WebSocketExtensionError.invalidServerResponse
        case (Optional.none, .some(let request)):
            clientMaxWindowBitsOffer = request
        case (.some(let resp), .some(let req)):
            let respVal = resp.intVal ?? Self.defaultMaxWindowBits

            if respVal > req {
                throw WebSocketExtensionError.invalidServerResponse
            } else {
                clientMaxWindowBitsOffer = respVal
            }
        }

        return PerMessageDeflateExtensionOption(
            isServer: false,
            serverNoTakeover: serverNoTakeoverOffer,
            clientNoTakeover: clientNoTakeoverOffer,
            serverMaxWindowBits: serverMaxWindowBitsOffer,
            clientMaxWindowBits: clientMaxWindowBitsOffer,
            maxDecompressionSize: self.maxDecompressionSize,
            memoryLevel: self.memoryLevel
        )
    }

    public func makeExtension() -> PerMessageDeflateCompression {
        PerMessageDeflateCompression(
            isServer: self.isServer,
            serverNoTakeover: self.serverNoTakeover,
            clientNoTakeover: self.clientNoTakeover,
            serverMaxWindowBits: self.serverMaxWindowBits,
            clientMaxWindowBits: self.clientMaxWindowBits,
            maxDecompressionSize: self.maxDecompressionSize,
            memoryLevel: memoryLevel
        )
    }

    // decode the http header and return an array of tuple of key in string and `PerMessageDeflateHTTPHeaderFieldType`.
    private func decodeHTTPHeader(_ httpHeaders: HTTPHeaders) throws -> [[String: PerMessageDeflateHTTPHeaderFieldType]]
    {
        let perMessageCompressionHeaderes = httpHeaders[canonicalForm: "Sec-WebSocket-Extensions"]
        var result: [[String: PerMessageDeflateHTTPHeaderFieldType]] = []

        for ext in perMessageCompressionHeaderes {
            let splits = ext.split(separator: ";", omittingEmptySubsequences: true)
            guard let first = splits.first, first.trimmingCharacters(in: .whitespaces) == Self.keyword else {
                continue
            }

            var parsedHeaders = [String: PerMessageDeflateHTTPHeaderFieldType]()

            for param in splits.dropFirst() {
                let p = param.trimmingCharacters(in: .whitespaces)
                if p == "server_no_context_takeover" || p == "client_no_context_takeover" {
                    if parsedHeaders.keys.contains(p) {
                        throw WebSocketExtensionError.duplicateParameter(name: p)
                    }
                    parsedHeaders[p] = PerMessageDeflateHTTPHeaderFieldType.none
                } else if p.hasPrefix("server_max_window_bits") {
                    if parsedHeaders.keys.contains("server_max_window_bits") {
                        throw WebSocketExtensionError.duplicateParameter(name: p)
                    }
                    if p.count == "server_max_window_bits".count {
                        parsedHeaders[p] = PerMessageDeflateHTTPHeaderFieldType.none
                    } else {
                        let windowBitsString = p.split(separator: "=")[1].trimmingCharacters(in: .whitespaces)
                        let wb: any StringProtocol
                        if windowBitsString.first == "\"" && windowBitsString.last == "\""
                            || windowBitsString.first == "'" && windowBitsString.last == "'"
                        {
                            wb = windowBitsString.dropFirst().dropLast()
                        } else {
                            wb = windowBitsString
                        }

                        guard let windowBits = Int(wb) else {
                            throw WebSocketExtensionError.invalidParameterValue(name: p, value: windowBitsString)
                        }

                        parsedHeaders["server_max_window_bits"] = PerMessageDeflateHTTPHeaderFieldType.int(windowBits)
                    }

                } else if p.hasPrefix("client_max_window_bits") {
                    if parsedHeaders.keys.contains("client_max_window_bits") {
                        throw WebSocketExtensionError.duplicateParameter(name: p)
                    }

                    if p.count == "client_max_window_bits".count {
                        parsedHeaders[p] = PerMessageDeflateHTTPHeaderFieldType.none
                    } else {
                        let windowBitsString = p.split(separator: "=")[1].trimmingCharacters(in: .whitespaces)
                        let wb: any StringProtocol
                        if windowBitsString.first == "\"" && windowBitsString.last == "\""
                            || windowBitsString.first == "'" && windowBitsString.last == "'"
                        {
                            wb = windowBitsString.dropFirst().dropLast()
                        } else {
                            wb = windowBitsString
                        }

                        guard let windowBits = Int(wb) else {
                            throw WebSocketExtensionError.invalidParameterValue(name: p, value: windowBitsString)
                        }
                        parsedHeaders["client_max_window_bits"] = PerMessageDeflateHTTPHeaderFieldType.int(windowBits)
                    }
                } else {
                    throw WebSocketExtensionError.unknownExtensionParameter(name: p)
                }
            }
            result.append(parsedHeaders)
        }
        return result
    }
}

extension PerMessageDeflateExtensionOption: CustomStringConvertible {
    public var description: String {
        var desc = Self.keyword
        if self.serverNoTakeover == true {
            desc += "; server_no_context_takeover"
        }
        if let serverMaxWindowBits = self.serverMaxWindowBits {
            desc += "; server_max_window_bits=\(serverMaxWindowBits)"
        }

        if self.clientNoTakeover == true {
            desc += "; client_no_context_takeover"
        }
        if let clientMaxWindowBits = self.clientMaxWindowBits {
            desc += "; client_max_window_bits=\(clientMaxWindowBits)"
        }
        return desc
    }

}

public struct PerMessageDeflateCompression {
    private static let emptyDeflateBlock: [UInt8] = [0x00, 0x00, 0xff, 0xff]
    
    public var reservedBits: WebSocketFrame.ReservedBits

    private let serverNoTakeover: Bool
    private let clientNoTakeover: Bool
    private let serverMaxWindowBits: Int?
    private let clientMaxWindowBits: Int?
    private let maxDecompressionSize: Int
    private let memoryLevel: Int
    private let isServer: Bool

    private var compressor: Compressor
    private var decompressor: Decompressor

    init(
        isServer: Bool,
        serverNoTakeover: Bool,
        clientNoTakeover: Bool,
        serverMaxWindowBits: Int?,
        clientMaxWindowBits: Int?,
        maxDecompressionSize: Int,
        memoryLevel: Int
    ) {
        self.isServer = isServer
        self.clientNoTakeover = clientNoTakeover
        self.clientMaxWindowBits = clientMaxWindowBits
        self.serverMaxWindowBits = serverMaxWindowBits
        self.serverNoTakeover = serverNoTakeover
        self.reservedBits = .rsv1
        self.maxDecompressionSize = maxDecompressionSize
        self.memoryLevel = memoryLevel

        do {
            let compressorMaxWindowBits: WindowBitsValue =
                self.isServer
                ? WindowBitsValue(self.serverMaxWindowBits ?? PerMessageDeflateExtensionOption.defaultMaxWindowBits)
                : WindowBitsValue(self.clientMaxWindowBits ?? PerMessageDeflateExtensionOption.defaultMaxWindowBits)
            let decompressorMaxWindowBits: WindowBitsValue =
                self.isServer
                ? WindowBitsValue(self.clientMaxWindowBits ?? PerMessageDeflateExtensionOption.defaultMaxWindowBits)
                : WindowBitsValue(self.serverMaxWindowBits ?? PerMessageDeflateExtensionOption.defaultMaxWindowBits)
            self.compressor = try Compressor(windowBits: compressorMaxWindowBits, memoryLevel: memoryLevel)
            self.decompressor = try Decompressor(
                windowBits: decompressorMaxWindowBits,
                limit: .size(maxDecompressionSize)
            )
        } catch {
            preconditionFailure("PerMessageDeflateCompression init failed: \(error)")
        }
    }
}

extension PerMessageDeflateCompression: WebSocketExtension {

    public mutating func encode(frame: WebSocketFrame, allocator: ByteBufferAllocator) throws -> WebSocketFrame {
        // skip control frame
        if frame.opcode == .connectionClose || frame.opcode == .ping || frame.opcode == .pong {
            return frame
        }

        let localNoTakeOver = self.isServer ? self.serverNoTakeover : self.clientNoTakeover
        var data = frame.data
        var compressedData = try self.compressor.compress(&data, using: allocator)
        if frame.fin {
            // last frame, we need to remove the last four bytes
            compressedData =
                compressedData.getSlice(at: compressedData.readerIndex, length: compressedData.readableBytes - 4)
                ?? allocator.buffer(capacity: 0)

            if localNoTakeOver {
                try compressor.reset()
            }
        }

        return WebSocketFrame(
            fin: frame.fin,
            rsv1: frame.opcode != .continuation,
            rsv2: frame.rsv2,
            rsv3: frame.rsv3,
            opcode: frame.opcode,
            maskKey: frame.maskKey,
            data: compressedData,
            extensionData: frame.extensionData
        )
    }

    public func decode(
        frame: WebSocketFrame,
        allocator: ByteBufferAllocator
    ) throws -> WebSocketFrame {
        // precondition: frame data is already unmasked

        func decompose(input: inout ByteBuffer) throws -> ByteBuffer {
            var decodedData: ByteBuffer = allocator.buffer(capacity: Decompressor.decompressionDefaultBufferSize)
            let inflateResult = try self.decompressor.decompress(
                input: &input,
                output: &decodedData,
                compressedLength: input.readableBytes
            )
            if !inflateResult.complete {
                var remaining = try decompose(input: &input)
                decodedData.writeBuffer(&remaining)
            }

            return decodedData
        }

        // skip control frame
        if frame.opcode == .connectionClose || frame.opcode == .ping || frame.opcode == .pong {
            return frame
        }

        let remoteNoTakeOver = self.isServer ? self.clientNoTakeover : self.serverNoTakeover

        var unmaskedData = frame.data
        if frame.fin {
            unmaskedData.writeBytes(Self.emptyDeflateBlock)
        }
        let decodedData = try decompose(input: &unmaskedData)

        if remoteNoTakeOver && frame.fin {
            try decompressor.reset()
        }

        return WebSocketFrame(
            fin: frame.fin,
            rsv1: false,
            rsv2: frame.rsv2,
            rsv3: frame.rsv3,
            opcode: frame.opcode,
            maskKey: frame.maskKey,
            data: decodedData,
            extensionData: frame.extensionData
        )
    }
}

extension PerMessageDeflateCompression {

    // The following code is adapted from https://github.com/apple/swift-nio-extras/blob/main/Sources/NIOHTTPCompression/HTTPCompression.swift
    final class Compressor: @unchecked Sendable {

        private var stream: z_stream = z_stream()
        private var isActive = false

        init(windowBits: WindowBitsValue, memoryLevel: Int = 8) throws {
            self.stream.zalloc = nil
            self.stream.zfree = nil
            self.stream.opaque = nil

            self.isActive = false

            guard memoryLevel <= 9 && memoryLevel >= 1 else {
                throw CompressorError.invalidParameter
            }

            let ret = CLCLWebSocketZlib_deflateInit2(
                &self.stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                -windowBits,
                Int32(memoryLevel),
                Z_DEFAULT_STRATEGY
            )
            guard ret == Z_OK else {
                throw CompressorError.compressionFailed(Int(ret))
            }
            self.isActive = true
        }

        deinit {
            self.shutdown()
        }

        func compress(_ input: inout ByteBuffer, using allocator: ByteBufferAllocator) throws -> ByteBuffer {
            precondition(self.isActive, "Please initialize first to initialize the compressor")

            guard input.readableBytes > 0 else {
                return allocator.buffer(capacity: 0)
            }

            let bufferSize = CLCLWebSocketZlib_deflateBound(&self.stream, UInt(input.readableBytes))
            var output = allocator.buffer(capacity: Int(bufferSize) + 5)
            try self.stream.oneShotDeflate(from: &input, to: &output, flag: Z_SYNC_FLUSH)

            return output
        }

        func shutdown() {
            if self.isActive {
                self.isActive = false
                deflateEnd(&self.stream)
            }
        }

        func reset() throws {
            if self.isActive {
                let ret = CLCLWebSocketZlib_deflateReset(&self.stream)
                guard ret == Z_OK else {
                    throw CompressorError.resetFailed(Int(ret))
                }
            }
        }
    }

    // The following code is adapted from https://github.com/apple/swift-nio-extras/blob/main/Sources/NIOHTTPCompression/HTTPDecompression.swift
    final class Decompressor: @unchecked Sendable {

        static let decompressionDefaultBufferSize: Int = 16384

        struct DecompressionLimit: Sendable {
            private enum Limit {
                case none
                case size(Int)
                case ratio(Int)
            }

            private var limit: Limit

            /// No limit will be set.
            /// - warning: Setting `limit` to `.none` leaves you vulnerable to denial of service attacks.
            static let none = DecompressionLimit(limit: .none)
            /// Limit will be set on the request body size.
            static func size(_ value: Int) -> DecompressionLimit { DecompressionLimit(limit: .size(value)) }
            /// Limit will be set on a ratio between compressed body size and decompressed result.
            static func ratio(_ value: Int) -> DecompressionLimit { DecompressionLimit(limit: .ratio(value)) }

            func exceeded(compressed: Int, decompressed: Int) -> Bool {
                switch self.limit {
                case .none:
                    return false
                case .size(let allowed):
                    return decompressed > allowed
                case .ratio(let ratio):
                    return decompressed > compressed * ratio
                }
            }
        }

        private var stream: z_stream
        private var isActive: Bool
        private let limit: DecompressionLimit
        private var inflatedCount: Int

        init(windowBits: WindowBitsValue, limit: DecompressionLimit = .none) throws {
            self.limit = limit
            self.inflatedCount = 0
            self.stream = z_stream()
            self.isActive = false

            self.stream.zalloc = nil
            self.stream.zfree = nil
            self.stream.opaque = nil
            self.inflatedCount = 0

            let ret = CLCLWebSocketZlib_inflateInit2(&self.stream, -windowBits)
            guard ret == Z_OK else {
                self.shutdown()
                throw DecompressionError.initializationFailed(Int(ret))
            }
            self.isActive = true
        }

        deinit {
            self.shutdown()
        }

        func decompress(
            input: inout ByteBuffer,
            output: inout ByteBuffer,
            compressedLength: Int
        ) throws -> InflateResult {
            precondition(self.isActive)
            let inflateResult = try self.stream.inflatePart(input: &input, output: &output)
            self.inflatedCount += inflateResult.written

            if self.limit.exceeded(compressed: compressedLength, decompressed: self.inflatedCount) {
                self.shutdown()
                throw DecompressionError.limitExceeded
            }
            return inflateResult
        }

        func reset() throws {
            if self.isActive {
                let ret = CLCLWebSocketZlib_inflateReset(&self.stream)
                inflatedCount = 0
                guard ret == Z_OK else {
                    throw DecompressionError.resetFailed(Int(ret))
                }
            }
        }

        private func shutdown() {
            if self.isActive {
                self.isActive = false
                CLCLWebSocketZlib.inflateEnd(&self.stream)
            }
        }
    }
}

extension PerMessageDeflateCompression {
    /// Errors that can occur during the decompression process.
    enum DecompressionError: Error {
        /// The decompressed data exceeds the allowed limit.
        case limitExceeded
        
        /// Initialization of the decompression stream failed.
        case initializationFailed(Int)
        
        /// Inflation (decompression) failed at a specific point.
        case inflationFailed(Int)
        
        /// The decompression process did not complete successfully.
        case inflationNotFinished
        
        /// Resetting the decompression stream failed.
        case resetFailed(Int)
    }

    /// Errors that can occur during the compression process.
    enum CompressorError: Error {
        /// Initialization of the compression stream failed.
        case initializationFailed(Int)

        /// Compression failed at a specific point.
        case compressionFailed(Int)

        /// Resetting the compression stream failed.
        case resetFailed(Int)

        /// An invalid parameter was provided to the compressor.
        case invalidParameter
    }

}

extension z_stream {
    mutating func oneShotDeflate(from: inout ByteBuffer, to: inout ByteBuffer, flag: Int32) throws {
        try from.readWithUnsafeMutableReadableBytes { fromPtr in
            self.avail_in = UInt32(fromPtr.count)
            self.next_in = CLCLWebSocketZlib_voidPtr_to_BytefPtr(fromPtr.baseAddress!)

            let ret = deflateToBuffer(&to, flag: flag)
            guard ret == Z_OK || ret == Z_STREAM_END else {
                throw PerMessageDeflateCompression.CompressorError.compressionFailed(Int(ret))
            }
            return self.next_in - CLCLWebSocketZlib_voidPtr_to_BytefPtr(fromPtr.baseAddress!)
        }
    }

    private mutating func deflateToBuffer(_ buffer: inout ByteBuffer, flag: Int32) -> Int32 {
        var ret = Z_OK
        buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: buffer.capacity) { toPtr in
            self.avail_out = UInt32(toPtr.count)
            self.next_out = CLCLWebSocketZlib_voidPtr_to_BytefPtr(toPtr.baseAddress!)
            ret = deflate(&self, flag)
            return self.next_out - CLCLWebSocketZlib_voidPtr_to_BytefPtr(toPtr.baseAddress!)
        }
        return ret
    }

    mutating func inflatePart(input: inout ByteBuffer, output: inout ByteBuffer) throws -> InflateResult {
        let minCapacity = input.readableBytes * 2
        var inflateResult = InflateResult(written: 0, complete: false)

        try input.readWithUnsafeMutableReadableBytes { inputPtr in
            self.avail_in = UInt32(inputPtr.count)
            self.next_in = CLCLWebSocketZlib_voidPtr_to_BytefPtr(inputPtr.baseAddress!)

            inflateResult = try self.inflatePart(to: &output, minCapacity: minCapacity)

            return self.next_in - CLCLWebSocketZlib_voidPtr_to_BytefPtr(inputPtr.baseAddress!)
        }

        return inflateResult
    }

    private mutating func inflatePart(to buffer: inout ByteBuffer, minCapacity: Int) throws -> InflateResult {
        var ret = Z_OK

        let written = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: minCapacity) { outputPtr in
            self.avail_out = UInt32(outputPtr.count)
            self.next_out = CLCLWebSocketZlib_voidPtr_to_BytefPtr(outputPtr.baseAddress!)
            ret = CLCLWebSocketZlib.inflate(&self, Z_NO_FLUSH)
            guard ret == Z_OK || ret == Z_STREAM_END else {
                throw PerMessageDeflateCompression.DecompressionError.inflationFailed(Int(ret))
            }

            return self.next_out - CLCLWebSocketZlib_voidPtr_to_BytefPtr(outputPtr.baseAddress!)
        }

        return InflateResult(written: written, complete: ret == Z_STREAM_END || self.avail_in == 0)
    }
}

// Inflation result
struct InflateResult {
    let written: Int
    let complete: Bool
}
