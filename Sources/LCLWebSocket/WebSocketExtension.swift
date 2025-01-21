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
import NIOPosix
import NIOWebSocket
import CLCLWebSocketZlib

public protocol WebSocketExtension {
    func decode(_ frame: WebSocketFrame) -> WebSocketFrame
    func encode(_ frame: WebSocketFrame) -> WebSocketFrame
}

public struct WebSocketExtensions {
    public struct PerMessageCompression: WebSocketExtension {
        let serverNoTakeover: Bool
        let clientNoTakeover: Bool
        let serverMaxWindowBits: Int
        let clientMaxWindowBits: Int
        let reservedBits: WebSocketFrame.ReservedBits
        
        public init(serverNoTakeover: Bool, clientNoTakeover: Bool, serverMaxWindowBits: Int, clientMaxWindowBits: Int) {
            precondition(serverMaxWindowBits <= 15 && serverMaxWindowBits >= 8)
            precondition(clientMaxWindowBits <= 15 && clientMaxWindowBits >= 8)
            self.serverNoTakeover = serverNoTakeover
            self.clientNoTakeover = clientNoTakeover
            self.serverMaxWindowBits = serverMaxWindowBits
            self.clientMaxWindowBits = clientMaxWindowBits
            self.reservedBits = .rsv1
        }
        
        public func decode(_ frame: NIOWebSocket.WebSocketFrame) -> NIOWebSocket.WebSocketFrame {
            <#code#>
        }
        
        public func encode(_ frame: NIOWebSocket.WebSocketFrame) -> NIOWebSocket.WebSocketFrame {
            <#code#>
        }
    }
}
