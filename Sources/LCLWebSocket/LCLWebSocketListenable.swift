//
//  File.swift
//  LCLWebSocket
//
//  Created by Zhennan Zhou on 12/18/24.
//

import Foundation
import NIOCore

protocol LCLWebSocketListenable {

    mutating func onOpen(_ onOpen: (@Sendable (WebSocket) -> Void)?)

    mutating func onPing(_ onPing: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    mutating func onPong(_ onPong: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    mutating func onText(_ onText: (@Sendable (WebSocket, String) -> Void)?)

    mutating func onBinary(_ onBinary: (@Sendable (WebSocket, ByteBuffer) -> Void)?)

    mutating func onError(_ onError: (@Sendable (Error) -> Void)?)
}
