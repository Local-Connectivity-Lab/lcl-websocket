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
import NIOSSL
import NIOTransportServices
import NIOWebSocket

#if canImport(Network)
import Network
#endif

public final class WebSocketServer: Sendable {

    private enum WebSocketUpgradeResult {
        case websocket(Channel)
        case notUpgraded(Channel, Error?)
    }

    private let eventloopGroup: EventLoopGroup

    public init(on eventloopGroup: any EventLoopGroup) {
        self.eventloopGroup = eventloopGroup
    }

    @available(macOS 13, *)
    public func bind(to address: SocketAddress, configuration: LCLWebSocket.Configuration) {
        let upgradeResult = ServerBootstrap(group: eventloopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in

                if let socketSendBufferSize = configuration.socketSendBufferSize,
                    let syncOptions = channel.syncOptions
                {
                    do {
                        try syncOptions.setOption(.socketOption(.so_sndbuf), value: socketSendBufferSize)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                if let socketReceiveBuffer = configuration.socketReceiveBufferSize,
                    let syncOptions = channel.syncOptions
                {
                    do {
                        try syncOptions.setOption(.socketOption(.so_rcvbuf), value: socketReceiveBuffer)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                // bind to selected device, if any
                if let deviceName = configuration.deviceName,
                    let device = findDevice(with: configuration.deviceName!, protocol: address.protocol)
                {
                    do {
                        try bindDevice(device, on: channel)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                // enable tls if configuration is provided
                if let tlsConfiguration = configuration.tlsConfiguration {
                    guard let sslContext = try? NIOSSLContext(configuration: tlsConfiguration) else {
                        return channel.eventLoop.makeFailedFuture(LCLWebSocketError.tlsInitializationFailed)
                    }
                    let sslServerHandler = NIOSSLServerHandler(context: sslContext)
                    do {
                        try channel.pipeline.syncOperations.addHandler(sslServerHandler)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelInitializer { channel in
                // TODO: refactor client/server channel initializer
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(to: address).flatMap { channel in
                let upgrader = NIOTypedWebSocketServerUpgrader(
                    maxFrameSize: configuration.maxFrameSize,
                    shouldUpgrade: { channel, httpRequestHead in
                        // TODO: should ask client to provide the shouldUpgradeCheck
                        channel.eventLoop.makeSucceededFuture(nil)
                    },
                    upgradePipelineHandler: { channel, httpRequestHead in
                        channel.eventLoop.makeCompletedFuture {
                            WebSocketUpgradeResult.websocket(channel)
                        }
                    }
                )

                let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(upgraders: [upgrader]) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        // TODO: need to reject the upgrade
                        WebSocketUpgradeResult.notUpgraded(channel, nil)
                    }
                }

                do {
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: upgradeConfiguration)
                    )
                } catch {
                    return channel.eventLoop.makeCompletedFuture {
                        WebSocketUpgradeResult.notUpgraded(channel, error)
                    }
                }
            }
    }
}
