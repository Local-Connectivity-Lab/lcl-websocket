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
import NIOPosix
import NIOWebSocket

/// `WebSocketExtension` is a protocol that defines how a `WebSocketFrame` can be interpreted
/// by the receiver and how a sender should encode the frame data to be conform the rules set by the extension.
///
/// `LCLWebSocket` provides one implementation of the Per-Message Deflate extension in `PerMessageDeflateExtension`.
/// If user wishes to implement their own custom WebSocket extension, they should implenent this protocol.
///
/// This protocol is different from `WebSocketExtensionOption`. This protocol emphasizes on the actual encoding/decoding
/// of the data in the `WebSocketFrame`. The implementation of this protocol should not be exposed to the external user for configuration.
public protocol WebSocketExtension: Sendable {
    
    /// The reserved bits used by this extension.
    var reservedBits: WebSocketFrame.ReservedBits { get }
    
    /// Decode the given `WebSocketFrame` according to the specification set by this `WebSocketExtension`.
    /// - Parameters:
    ///   - frame: The given `WebSocketFrame` to be decoded.
    ///   - allocator: The `ByteBufferAllocator` that can allocate `ByteBuffer` for the decoded frame data.
    /// - Returns: A new `WebSocketFrame` whose data is decoded following the specification of this `WebSocketExtension`.
    /// - Throws: Error will be thrown if the decoding failed.
    mutating func decode(frame: WebSocketFrame, allocator: ByteBufferAllocator) throws -> WebSocketFrame
    
    /// Encode the given `WebSocketFrame` according to the specification set by this `WebSocketExtension`.
    /// - Parameters:
    ///   - frame: The given `WebSocketFrame` to be encoded.
    ///   - allocator: The `ByteBufferAllocator` that can allocate `ByteBuffer`.
    /// - Returns: A new `WebSocketFrame` whose data is encoded following the specification of this `WebSocketExtension`.
    /// - Throws: Error will be thrown if the encoding failed.
    mutating func encode(frame: WebSocketFrame, allocator: ByteBufferAllocator) throws -> WebSocketFrame
}

/// `WebSocketExtensionOption` is a protocol that defines potential configurable options defined by corresponding `WebSocketExtension`.
/// This protocol also defines how extension should be negotiated between client and server.
///
/// `LCLWebSocket` provides one implementation of the Per-Message Deflate extension option in `PerMessageDeflateExtensionOption`.
/// If user wishes to implement their own custom WebSocket extension option, they should implenent this protocol.
///
/// This protocol is different from `WebSocketExtension`, where this protocol emphasizes on the options in the extension and how this extension
/// should be negotiated between client and the server.  The implementation of this protocol should be exposed to the user to configure options in this extension.
public protocol WebSocketExtensionOption: Sendable {
    
    /// The option type that the implementation of this protocol uses, usually it is `Self`.
    associatedtype OptionType
    
    /// The extension type that this extensioin option type associates to.
    associatedtype ExtensionType: WebSocketExtension

    
    /// Negotiate the extension parameters given the proposed values in the httpHeaders. This method will be used by the WebSocket server.
    /// - Parameter httpHeaders: The HTTP headers coming from the client that might contain the proposed parameters for the given extension.
    /// - Returns: The  instance of `OptionType` that contains the negotiated parameters, or `nil` if server does not support the parameters from the client.
    /// - Throws: Errors will be thrown if negotiation failed.
    func negotiate(_ httpHeaders: HTTPHeaders) throws -> OptionType?
    
    /// Accept the extension parameters agreed by the WebSocket server. This method will be used by the WebSocket client.
    /// - Parameter httpHeaders: The HTTP headers coming from the server that might contains the agreed parameters for the given extension.
    /// - Returns: The  instance of `OptionType` that contains the negotiated parameters, or `nil` if no parameters from the server is supported.
    func accept(_ httpHeaders: HTTPHeaders) throws -> OptionType?
    
    
    /// Make the corresponding instance of the `ExtensionType` given the parameters set in this `WebSocketExtensionOption`.
    /// - Returns: An instance of the `WebSocketExtension` associated with this `WebSocketExtensionOption` using the parameters defined in this WebSocket Extension option.
    func makeExtension() -> ExtensionType

    /// The reserved bits used by this extension.
    var reservedBits: WebSocketFrame.ReservedBits { get }
    
    /// The HTTP header key-value pair for  this `WebSocketExtensionOption`.
    var httpHeader: (name: String, val: String) { get }
}

/// Errors that might be thrown during WebSocketExtension negotiation.
public enum WebSocketExtensionError: Error {
    
    /// There exists a duplicate parameter.
    case duplicateParameter(name: String)
    
    /// The value associated with the parameter is invalid.
    case invalidParameterValue(name: String, value: String)
    
    /// The provided parameter is not supported by the extension.
    case unknownExtensionParameter(name: String)
    
    /// The negotiation response from the server is invalid.
    case invalidServerResponse
    
    /// The extension is not compatible with other extensions. Might have conflicting reserved bits.
    case incompatibleExtensions
}

extension WebSocketExtensionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateParameter(name: let name):
            return "Duplicate parameter in the extension: \(name)"
        case .invalidParameterValue(name: let name, value: let value):
            return "Invalid extension parameter value: \(name)=\(value)"
        case .unknownExtensionParameter(name: let name):
            return "Unknown extension parameter: \(name)"
        case .invalidServerResponse:
            return "Invalid server response during extension negotiation."
        case .incompatibleExtensions:
            return "The extension is not compatible with other extensions."
        }
    }
}
