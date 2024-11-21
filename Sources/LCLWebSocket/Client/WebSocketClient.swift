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
import NIOHTTP1
import NIOPosix
import NIOTransportServices
import NIOWebSocket

#if canImport(Network)
import Network
#endif

public final class WebSocketClient: Sendable {

    private enum WebSocketUpgradeResult {
        case websocket(Channel)
        case notUpgraded
    }

    public init() {

    }

    @available(macOS 13, *)
    public func connect(
        to endpoint: String,
        config: LCLWebSocket.Configuration
    ) -> EventLoopFuture<
        WebSocket
    > {
        let eventloopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        guard let urlComponents = URLComponents(string: endpoint) else {
            return eventloopGroup.next().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        guard let s = urlComponents.scheme, let scheme = WebSocketScheme(rawValue: s) else {
            return eventloopGroup.next().makeFailedFuture(LCLWebSocketError.invalidURL)
        }

        guard let host = urlComponents.host else {
            return eventloopGroup.next().makeFailedFuture(LCLWebSocketError.invalidURL)
        }
        print("host: \(urlComponents)")

        let port = urlComponents.port ?? scheme.defaultPort
        let path = urlComponents.path.isEmpty ? "/" : urlComponents.path
        let query = urlComponents.query ?? ""
        let uri = path + (query.isEmpty ? "" : "?" + query)

        let upgradeResult = ClientBootstrap(group: eventloopGroup)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .connectTimeout(config.connectionTimeout)
            .connect(host: host, port: port).flatMap { channel in
                // make upgrade request
                let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketUpgradeResult>(
                    maxFrameSize: config.maxFrameSize
                ) { channel, _ in
                    // TODO: probably need to decode the response from server to populate for more fields like extension
                    channel.eventLoop.makeCompletedFuture {
                        WebSocketUpgradeResult.websocket(channel)
                    }
                }

                var httpHeaders = HTTPHeaders()
                httpHeaders.add(name: "Host", value: "\(host):\(port)")
                // TODO: need to add additional fields from the client
                // TODO: need to handle extension

                let httpRequestHead = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: uri,
                    headers: httpHeaders
                )

                let upgradeConfig = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: httpRequestHead,
                    upgraders: [upgrader]
                ) { channel in
                    channel.eventLoop.makeCompletedFuture { .notUpgraded }
                }

                do {
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                        configuration: .init(upgradeConfiguration: upgradeConfig)
                    )
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        return upgradeResult.flatMapResult { upgradeResult in
            switch upgradeResult {
            case .notUpgraded:
                return .failure(LCLWebSocketError.notUpgraded as Error)
            case .websocket(let channel):
                let websocketConnectionInfo = WebSocket.ConnectionInfo(url: urlComponents)
                let websocket = WebSocket(
                    channel: channel,
                    type: .client,
                    configuration: config,
                    connectionInfo: websocketConnectionInfo
                )
                do {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOWebSocketFrameAggregator(
                            minNonFinalFragmentSize: config.minNonFinalFragmentSize,
                            maxAccumulatedFrameCount: config.maxAccumulatedFrameCount,
                            maxAccumulatedFrameSize: config.maxAccumulatedFrameSize
                        ),
                        WebSocketHandler(websocket: websocket),
                    ])
                    print(channel.pipeline.debugDescription)
                } catch {
                    return .failure(error)
                }
                return .success(websocket)
            }
        }
    }
}
