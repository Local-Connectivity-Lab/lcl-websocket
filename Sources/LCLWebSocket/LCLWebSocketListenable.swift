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

    mutating func onPing(_ onPing: (@Sendable (ByteBuffer) -> Void)?)

    mutating func onPong(_ onPong: (@Sendable (ByteBuffer) -> Void)?)

    mutating func onText(_ onText: (@Sendable (String) -> Void)?)

    mutating func onBinary(_ onBinary: (@Sendable (ByteBuffer) -> Void)?)

    mutating func onError(_ onError: (@Sendable (Error) -> Void)?)
}
