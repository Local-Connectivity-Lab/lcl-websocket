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
import NIOCore
import NIOWebSocket

/// A protocol that defines observer callbacks for the implementation to understand
/// the current state of a WebSocket connection.
protocol LCLWebSocketListenable {

    /// Invoked when the WebSocket connection is open and is ready to send and receive WebSocket frames.
    mutating func onOpen(_ onOpen: (@Sendable (WebSocket) -> Void)?)

    /// Invoked when a ping message is received from the peer.
    mutating func onPing(_ onPing: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    /// Invoked when a pong message is received from the peer for a previous ping message.
    mutating func onPong(_ onPong: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    /// Invoked when a text (UTF-8 encoded) message is received from the peer.
    mutating func onText(_ onText: (@Sendable (WebSocket, String) -> Void)?)

    /// Invoked when a binary message is received from the peer.
    mutating func onBinary(_ onBinary: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    /// Invoked when both peers have indicated that no more messages will be transmitted and
    mutating func onClosing(_ onBinary: (@Sendable (WebSocketErrorCode?, String?) -> Void)?)

    /// Invoked when the remote peer has indicated that no more incoming messages will be transmitted.
    mutating func onClosed(_ onBinary: (@Sendable () -> Void)?)

    /// Invoked when some error occurs in the current WebSocket connection.
    mutating func onError(_ onError: (@Sendable (Error) -> Void)?)
}
