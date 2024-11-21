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

public enum LCLWebSocketError: Error {
    case notUpgraded
    case closeReasonTooLong
    case websocketNotConnected
    case channelNotActive
    case controlFrameShouldNotBeFragmented
    case websocketAlreadyClosed
    case websocketTimeout
    case invalidURL
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
        case .websocketAlreadyClosed:
            return "WebSocket connection is already closed"
        case .websocketTimeout:
            return "WebSocket timeout"
        case .invalidURL:
            return "Invalid URL"
        }
    }
}
