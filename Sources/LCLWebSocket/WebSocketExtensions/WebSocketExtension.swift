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

public protocol WebSocketExtension: Sendable {
    var reservedBits: WebSocketFrame.ReservedBits { get }
    mutating func decode(frame: WebSocketFrame, allocator: ByteBufferAllocator) throws -> WebSocketFrame
    mutating func encode(frame: WebSocketFrame, allocator: ByteBufferAllocator) throws -> WebSocketFrame
}

public protocol WebSocketExtensionOption: Sendable {
    associatedtype OptionType
    associatedtype ExtensionType: WebSocketExtension

    func negotiate(_ httpHeaders: HTTPHeaders) throws -> OptionType?
    func accept(_ httpHeaders: HTTPHeaders) throws -> OptionType?
    func makeExtension() -> ExtensionType
    var reservedBits: WebSocketFrame.ReservedBits { get }
    var httpHeader: (name: String, val: String) { get }
}

public enum WebSocketExtensionError: Error {
    case duplicateParameter(name: String)
    case invalidParameterValue(name: String, value: String)
    case unknownExtensionParameter(name: String)
    case invalidServerResponse
    case incompatibleExtensions
}
