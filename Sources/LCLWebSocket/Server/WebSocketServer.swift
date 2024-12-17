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
import NIOConcurrencyHelpers
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

    private let eventloopGroup: EventLoopGroup
    private let serverConfiguration: WebSocketServerConfiguration
    private let _onPing: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>
    private let _onPong: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>
    private let _onText: NIOLoopBoundBox<(@Sendable (String) -> Void)?>
    private let _onBinary: NIOLoopBoundBox<(@Sendable (ByteBuffer) -> Void)?>

    public init(on eventloopGroup: any EventLoopGroup, serverConfiguration: WebSocketServerConfiguration? = nil) {
        self.eventloopGroup = eventloopGroup
        self.serverConfiguration = serverConfiguration ?? WebSocketServerConfiguration.defaultConfiguration
        self._onPing = .makeEmptyBox(eventLoop: eventloopGroup.any())
        self._onPong = .makeEmptyBox(eventLoop: eventloopGroup.any())
        self._onText = .makeEmptyBox(eventLoop: eventloopGroup.any())
        self._onBinary = .makeEmptyBox(eventLoop: eventloopGroup.any())
    }

    // TODO: maybe not using NIOLoopBoundBox?
    public func onPing(_ onPing: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onPing._eventLoop.execute {
            self._onPing.value = onPing
        }
    }

    public func onPong(_ onPong: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onPong._eventLoop.execute {
            self._onPong.value = onPong
        }
    }

    public func onText(_ onText: @escaping @Sendable (String) -> Void) {
        self._onText._eventLoop.execute {
            self._onText.value = onText
        }
    }

    public func onBinary(_ onBinary: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onBinary._eventLoop.execute {
            self._onBinary.value = onBinary
        }
    }
    
    @available(macOS 13, *)
    public func listen(to host: String, port: Int, configuration: LCLWebSocket.Configuration) throws -> EventLoopFuture<Void> {
        let addr = try SocketAddress(ipAddress: host, port: port)
        return self.listen(to: addr, configuration: configuration)
    }

    @available(macOS 13, *)
    public func listen(to address: SocketAddress, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        ServerBootstrap(group: eventloopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                print("parent channel: \(channel)")
                if let socketSendBufferSize = configuration.socketSendBufferSize,
                    let syncOptions = channel.syncOptions {
                    do {
                        try syncOptions.setOption(.socketOption(.so_sndbuf), value: socketSendBufferSize)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                if let socketReceiveBuffer = configuration.socketReceiveBufferSize,
                    let syncOptions = channel.syncOptions {
                    do {
                        try syncOptions.setOption(.socketOption(.so_rcvbuf), value: socketReceiveBuffer)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                // bind to selected device, if any
                if let deviceName = configuration.deviceName,
                    let device = findDevice(with: deviceName, protocol: address.protocol) {
                    do {
                        try bindTo(device: device, on: channel)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // enable tls if configuration is provided
                print("child channel: \(channel)")
                print(channel.pipeline.debugDescription)
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

                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: configuration.maxFrameSize,
                    shouldUpgrade: self.serverConfiguration.shouldUpgrade,
                    upgradePipelineHandler: { channel, httpRequestHead in
                        let websocket = WebSocket(
                            channel: channel,
                            type: .server,
                            configuration: configuration,
                            connectionInfo: nil
                        )
                        self._onPing._eventLoop.execute {
                            websocket.onPing(self._onPing.value)
                        }
                        self._onPong._eventLoop.execute {
                            websocket.onPong(self._onPong.value)
                        }
                        self._onText._eventLoop.execute {
                            websocket.onText(self._onText.value)
                        }
                        self._onBinary._eventLoop.execute {
                            websocket.onBinary(self._onBinary.value)
                        }
                        do {
                            try channel.syncOptions?.setOption(
                                .writeBufferWaterMark,
                                value: .init(
                                    low: configuration.writeBufferWaterMarkLow,
                                    high: configuration.writeBufferWaterMarkHigh
                                )
                            )
                            try channel.pipeline.syncOperations.addHandlers([
                                NIOWebSocketFrameAggregator(
                                    minNonFinalFragmentSize: configuration.minNonFinalFragmentSize,
                                    maxAccumulatedFrameCount: configuration.maxAccumulatedFrameCount,
                                    maxAccumulatedFrameSize: configuration.maxAccumulatedFrameSize
                                ),
                                WebSocketHandler(websocket: websocket),
                            ])
                            print(channel.pipeline.debugDescription, channel)
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                )

                do {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: self.serverConfiguration.onUpgradeComplete)
                    )
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(to: address)
            .flatMap { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
    }
}
