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
import NIOWebSocket

#if canImport(Network)
import Network
import NIOTransportServices
#endif

public struct WebSocketServer: Sendable {
    
    enum UpgradeResult {
        case notUpgraded(Error?)
        case websocket
    }

    private let eventloopGroup: EventLoopGroup
    private let serverConfiguration: WebSocketServerConfiguration
    private var _onPing: (@Sendable (ByteBuffer) -> Void)?
    private var _onPong: (@Sendable (ByteBuffer) -> Void)?
    private var _onText: (@Sendable (String) -> Void)?
    private var _onBinary: (@Sendable (ByteBuffer) -> Void)?

    public init(on eventloopGroup: any EventLoopGroup, serverConfiguration: WebSocketServerConfiguration? = nil) {
        self.eventloopGroup = eventloopGroup
        self.serverConfiguration = serverConfiguration ?? WebSocketServerConfiguration.defaultConfiguration
    }

    // TODO: maybe not using NIOLoopBoundBox?
    public mutating func onPing(_ onPing: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onPing = onPing
    }

    public mutating func onPong(_ onPong: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onPong = onPong
    }

    public mutating func onText(_ onText: @escaping @Sendable (String) -> Void) {
        self._onText = onText
    }

    public mutating func onBinary(_ onBinary: @escaping @Sendable (ByteBuffer) -> Void) {
        self._onBinary = onBinary
    }

    #if !canImport(Darwin) || swift(>=5.10)
//    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
//    public func listen(
//        to host: String,
//        port: Int,
//        configuration: LCLWebSocket.Configuration
//    ) throws -> EventLoopFuture<Void> {
//        let addr = try SocketAddress(ipAddress: host, port: port)
//        return self.listen(to: addr, configuration: configuration)
//    }
    
    public func listen(to address: SocketAddress, configuration: LCLWebSocket.Configuration) {
        ServerBootstrap(group: self.eventloopGroup)
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
                logger.debug("child channel: \(channel)")
                logger.debug(.init(stringLiteral: channel.pipeline.debugDescription))
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
                
                return self.configureWebSocketServerUpgrade(on: channel, configuration: configuration)
//                    .flatMap { channel in
//                    channel.pipeline.context(handlerType: ErrorRecorder.self).flatMap { context in
//                        if case .some(let error) = (context.handler as! ErrorRecorder).error {
//                            if (error as? NIOWebSocketUpgradeError) == .unsupportedWebSocketTarget {
//                                print("will reject with code 407")
//                            } else {
//                                print("unknown error: \(error)")
//                            }
//                        } else {
//                            print("no error found!")
//                        }
//                        return context.eventLoop.makeSucceededVoidFuture()
//                    }
//                    do {
//                        let errorRecorder = try channel.pipeline.syncOperations.handler(type: ErrorRecorder.self)
//                        if case .some(let error) = errorRecorder.error {
//                            if (error as? NIOWebSocketUpgradeError) == .unsupportedWebSocketTarget {
//                                print("will reject with code 407")
//                            } else {
//                                print("unknown error: \(error)")
//                            }
//                        }
//                    } catch {
//                        print("error caught when fetching error recorder: \(error)")
//                        return channel.eventLoop.makeFailedFuture(error)
//                    }
//                    return channel.eventLoop.makeSucceededVoidFuture()
//                }
            }
            .bind(to: address)
    }

    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
    public func listen1(to address: SocketAddress, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        return ServerBootstrap(group: self.eventloopGroup)
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
            .childChannelInitializer { (channel: Channel) -> EventLoopFuture<Void> in
                // enable tls if configuration is provided
                logger.debug("child channel: \(channel)")
                logger.debug(.init(stringLiteral: channel.pipeline.debugDescription))
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

                return self.configureTypedWebSocketServerUpgrade(on: channel, configuration: configuration)
            }
           .bind(to: address)
           .flatMap { channel in
               channel.eventLoop.makeSucceededVoidFuture()
           }
    }
    private func configureWebSocketServerUpgrade(on channel: Channel, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        let upgrader = NIOWebSocketServerUpgrader(maxFrameSize: configuration.maxFrameSize, shouldUpgrade: self.serverConfiguration.shouldUpgrade) { channel, httpRequestHead in
            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: nil
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
            
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
        
        let serverUpgradeConfig = NIOHTTPServerUpgradeConfiguration(upgraders: [upgrader], completionHandler: { channel in })
        do {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: serverUpgradeConfig)
            let protocolErrorHandler = try channel.pipeline.syncOperations.handler(type: HTTPServerProtocolErrorHandler.self)
            try channel.pipeline.syncOperations.addHandler(HTTPRequestMethodValidationHandler(allowedMethods: [.GET]), position: .after(protocolErrorHandler))
            try channel.pipeline.syncOperations.addHandler(HTTPServerRequestErrorHandler(), position: .last)
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
    
    @available(macOS 13, iOS 16, watchOS 9, tvOS 16, visionOS 1.0, *)
    private func configureTypedWebSocketServerUpgrade(on channel: Channel, configuration: LCLWebSocket.Configuration) -> EventLoopFuture<Void> {
        let upgrader = NIOTypedWebSocketServerUpgrader(maxFrameSize: configuration.maxFrameSize, shouldUpgrade: self.serverConfiguration.shouldUpgrade) { channel, httpRequestHead in
            let websocket = WebSocket(
                channel: channel,
                type: .server,
                configuration: configuration,
                connectionInfo: nil
            )
            websocket.onPing(self._onPing)
            websocket.onPong(self._onPong)
            websocket.onText(self._onText)
            websocket.onBinary(self._onBinary)
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
                return channel.eventLoop.makeSucceededFuture(UpgradeResult.websocket)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        let serverUpgradeConfig = NIOTypedHTTPServerUpgradeConfiguration(upgraders: [upgrader]) { channel in
            print("server upgrade failed")
            return channel.eventLoop.makeSucceededFuture(UpgradeResult.notUpgraded(nil))
        }

        print("serverUpgradeConfig: \(serverUpgradeConfig)")
        do {
            let upgradeResult = try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(configuration: .init(upgradeConfiguration: serverUpgradeConfig))
            return upgradeResult.flatMap { result in
                print("upgrade result: \(result)")
                switch result {
                case .websocket:
                    return channel.eventLoop.makeSucceededVoidFuture()
                case .notUpgraded(.some(let error)):
                    return channel.eventLoop.makeFailedFuture(error)
                case .notUpgraded(.none):
                    return channel.eventLoop.makeFailedFuture(LCLWebSocketError.notUpgraded)
                }
            }
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }
    #endif
}

extension WebSocketServer {
    
    // respond with status code and the body string back to the client
    // Connection: close and Content-Length: 0 will be included automatically
    private static func makeResponse(with status: HTTPResponseStatus, additionalHeaders: [String: String]? = nil) -> HTTPResponseHead {
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "close")
        headers.add(name: "Content-Length", value: "0")
        
        if additionalHeaders != nil {
            for (key, val) in additionalHeaders! {
                headers.add(name: key, value: val)
            }
        }
        
        return HTTPResponseHead(version: .http1_1, status: status, headers: headers)
    }
    
    private final class HTTPRequestMethodValidationHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias InboundOut = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        
        private enum HTTPRequestMethodValidationStateMachine {
            case ok
            case invalidMethod
        }
        
        private let allowedMethods: [HTTPMethod]
        private var state: HTTPRequestMethodValidationStateMachine
        
        init(allowedMethods: [HTTPMethod]) {
            self.allowedMethods = allowedMethods
            self.state = .ok
        }
        
        func handlerAdded(context: ChannelHandlerContext) {
            print("HTTPRequestMethodValidationHandler added")
        }
        
        func handlerRemoved(context: ChannelHandlerContext) {
            print("HTTPRequestMethodValidationHandler removed")
        }
        
        func channelActive(context: ChannelHandlerContext) {
            print("HTTPRequestMethodValidationHandler active")
        }
        
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let requestPart = self.unwrapInboundIn(data)
            switch (requestPart, self.state) {
            case (.head, .invalidMethod):
                preconditionFailure("HTTPRequestMethodValidationHandler is not in a valid state while receiving http request head. \(self.state)")
            case (.head(let head), .ok):
                if !allowedMethods.contains(head.method) {
                    self.state = .invalidMethod
                    print("Request method is not valid. Received: \(head.method). Expected: \(allowedMethods)")
                } else {
                    context.fireChannelRead(data)
                }
            case (.body, .ok):
                context.fireChannelRead(data)
            case (.body, .invalidMethod):
                ()
            case (.end, .ok):
                context.fireChannelRead(data)
            case (.end, .invalidMethod):
                let resposneHead = makeResponse(with: .methodNotAllowed)
                context.channel.write(self.wrapOutboundOut(.head(resposneHead)), promise: nil)
                context.channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.close(mode: .all, promise: nil)
            }
        }
        
    }
    
    
    private final class HTTPServerRequestErrorHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias InboundOut = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        
        private enum HTTPServerRequestErrorHandlerStateMachine {
            case ok
            case error(Error)
            case done
        }
        
        private var state: HTTPServerRequestErrorHandlerStateMachine = .ok
        
        func handlerAdded(context: ChannelHandlerContext) {
            print("error recorder added")
        }
        
        func handlerRemoved(context: ChannelHandlerContext) {
            print("error recorder removed")
        }
        
        func channelActive(context: ChannelHandlerContext) {
            print("error recorder active")
        }
        
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let request = self.unwrapInboundIn(data)
            switch (request, self.state) {
            case (.end, .error(let err)):
                // close the channel
                self.closeChannel(for: err, with: context)
            default:
                context.fireChannelRead(data)
            }
        }
        
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            switch self.state {
            case .ok:
                self.state = .error(error)
                print("error caught in error recorder \(error)")
                context.fireErrorCaught(error)
            case .done:
                self.closeChannel(for: error, with: context)
            case .error:
                preconditionFailure("Channel should already be closed. But it is still receiving error: \(error)")
            }
        }
        
        private func closeChannel(for error: Error, with context: ChannelHandlerContext) {
            let responseHead: HTTPResponseHead
            if (error as? NIOWebSocketUpgradeError) == .unsupportedWebSocketTarget {
                responseHead = makeResponse(with: .badRequest)
            } else {
                print("unknown error \(error)")
                responseHead = makeResponse(with: .internalServerError)
            }
            print("closing channel due to error \(error). response head \(responseHead)")
            context.channel.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            context.channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.close(mode: .all, promise: nil)
        }
    }
}
