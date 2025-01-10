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

public struct LCLWebSocket {

    public static func client(on: any EventLoopGroup = LCLWebSocket.defaultEventloopGroup) -> WebSocketClient {
        WebSocketClient(on: on)
    }

    public static func server(
        on: any EventLoopGroup = LCLWebSocket.defaultEventloopGroup,
        serverUpgradeConfiguration: WebSocketServerUpgradeConfiguration = .defaultConfiguration
    ) -> WebSocketServer {
        WebSocketServer(on: on, serverUpgradeConfiguration: serverUpgradeConfiguration)
    }
}
