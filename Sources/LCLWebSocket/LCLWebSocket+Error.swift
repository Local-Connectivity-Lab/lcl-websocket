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

import Foundation
import NIOWebSocket

/// The errors that `LCLWebSocket` might encounter while communicating with the remote peer.
public enum LCLWebSocketError: Error {

    /// The WebSocket connection upgrade failed
    case notUpgraded

    /// The close reason in the close frame is too long. It should not be longer than 123 bytes.
    case closeReasonTooLong

    /// The underlying connection for `LCLWebSocket` is closed.
    case websocketNotConnected

    /// The underlying channel for `LCLWebSocket` is not active.
    case channelNotActive

    /// Control frame should not be fragmented in WebSocket
    case controlFrameShouldNotBeFragmented

    /// The WebSocket connection times out
    case websocketTimeout

    /// The WebSocket URL to connect to is invalid.
    case invalidURL

    /// The device to which the connection will be bound to is invalid
    case invalidDevice

    /// TLS initialization failed for `wss` endpoint
    case tlsInitializationFailed

    /// The OpCode received is not known
    case unknownOpCode(WebSocketOpcode)

    /// HTTP method is not allowed during the upgrade request.
    case methodNotAllowed
    
    /// Received a new fragment frame without finishing the previous fragment sequence.
    case receivedNewFrameWithoutFinishingPreviousOne
    
    /// The size of the non-final fragment is too small.
    case nonFinalFragmentSizeIsTooSmall
    
    /// There are too many fragment frames
    case tooManyFrameFragments
    
    /// The buffered frame sizes is too large.
    case accumulatedFrameSizeIsTooLarge
    
    /// Received a continuation frame without a previous fragment frame.
    case receivedContinuationFrameWithoutPreviousFragmentFrame
    
    /// Invalid UTF-8 string
    case invalidUTF8String
}

extension LCLWebSocketError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notUpgraded:
            return "Not upgraded"
        case .closeReasonTooLong:
            return "Close reason too long"
        case .websocketNotConnected:
            return "Websocket not connected"
        case .channelNotActive:
            return "Channel is not active"
        case .controlFrameShouldNotBeFragmented:
            return "Control frame should not be fragmented"
        case .websocketTimeout:
            return "WebSocket timeout"
        case .invalidURL:
            return "Invalid URL"
        case .invalidDevice:
            return "Invalid Device"
        case .tlsInitializationFailed:
            return "TLS initialization failed"
        case .unknownOpCode(let code):
            return "Unknown opcode \(code)"
        case .methodNotAllowed:
            return "HTTP Method not allowed"
        case .receivedNewFrameWithoutFinishingPreviousOne:
            return "Received new frame without finishing previous one"
        case .nonFinalFragmentSizeIsTooSmall:
            return "Non-final fragment size is too small"
        case .tooManyFrameFragments:
            return "Too many frame fragments"
        case .accumulatedFrameSizeIsTooLarge:
            return "Accumulated frame size is too large"
        case .receivedContinuationFrameWithoutPreviousFragmentFrame:
            return "Received continuation frame without previous fragment frame"
        case .invalidUTF8String:
            return "Invalid UTF-8 string"
        }
    }
}
