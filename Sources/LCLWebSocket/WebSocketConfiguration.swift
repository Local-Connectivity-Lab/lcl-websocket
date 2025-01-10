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
import NIOSSL

extension LCLWebSocket {
    /// Collection of configuration options that allow users to configure the behavior of the WebSocket connection.
    ///
    /// Use this structure to customize the behavior of WebSocket connections,
    /// including TLS settings, frame sizes, timeouts, and auto-ping behavior.
    public struct Configuration: Sendable {

        /// TLS configuration for secure WebSocket connections.
        ///
        /// Set this to enable WSS (WebSocket Secure) connections.
        /// - Note: Required for `wss://` URLs. By default, this is `nil`.
        let tlsConfiguration: TLSConfiguration?

        /// Maximum size of a single WebSocket frame in bytes. Default is 1 << 14 (16KB).
        ///
        /// - Important: Frames larger than this will be rejected
        var maxFrameSize: Int

        /// Minimum size required for non-final fragments. Default is 0 (no minimum).
        var minNonFinalFragmentSize: Int

        /// Maximum number of frames that can be accumulated. Default is Int.max.
        ///
        /// Limits memory usage when receiving fragmented messages.
        var maxAccumulatedFrameCount: Int

        /// Maximum total size of accumulated frames in bytes. Default is Int.max.
        var maxAccumulatedFrameSize: Int

        /// Low water mark for write buffer in bytes.
        ///
        /// When buffer size drops below this, writes resume.
        /// - Note: Must be >= 1 and <= writeBufferWaterMarkHigh
        var writeBufferWaterMarkLow: Int {
            willSet {
                precondition(
                    newValue >= 1 && newValue <= writeBufferWaterMarkHigh,
                    "writeBufferWaterMarkLow should be between 1 and writeBufferWaterMarkHigh"
                )
            }
        }

        /// High water mark for write buffer in bytes.
        ///
        /// When buffer exceeds this, writes pause.
        /// - Note: Must be >= writeBufferWaterMarkLow
        var writeBufferWaterMarkHigh: Int {
            willSet {
                precondition(
                    newValue >= writeBufferWaterMarkLow,
                    "writeBufferWaterMarkHigh should be greater than or equal to writeBufferWaterMarkLow"
                )
            }
        }

        /// Maximum time to wait for connection establishment.
        var connectionTimeout: TimeAmount

        /// The network device name on the system to route the traffic to.
        ///
        /// - Note: You might need root privileges to use this feature.
        var deviceName: String?

        /// Auto-ping configuration to keep the WebSocket connection alive. Default is enabled.
        /// - seealso: `AutoPingConfiguration`
        var autoPingConfiguration: AutoPingConfiguration

        /// Socket send buffer size in bytes.
        var socketSendBufferSize: Int32?

        /// Socket receive buffer size in bytes.
        var socketReceiveBufferSize: Int32?

        /// Strategy for handling leftover bytes after upgrade.
        ///
        /// The default behavior is to drop all bytes after the upgrade is complete. However, sometimes, you might want to configure
        /// your WebSocket to forward all the remaining bytes, as the WebSocket server might start sending WebSocket frames in the same packet.
        var leftoverBytesStrategy: RemoveAfterUpgradeStrategy

        public init(
            maxFrameSize: Int = 1 << 14,
            minNonFinalFragmentSize: Int = 0,
            maxAccumulatedFrameCount: Int = .max,
            maxAccumulatedFrameSize: Int = .max,
            writeBufferWaterMarkLow: Int = 32 * 1024,
            writeBufferQaterMarkHigh: Int = 64 * 1024,
            tlsConfiguration: TLSConfiguration? = nil,
            connectionTimeout: TimeAmount = .seconds(10),
            autoPingConfiguration: AutoPingConfiguration = .enabled(
                pingInterval: .seconds(20),
                pingTimeout: .seconds(20)
            ),
            leftoverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
            deviceName: String? = nil,
            socketSendBufferSize: Int32? = nil,
            socketReceiveBufferSize: Int32? = nil
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.maxFrameSize = maxFrameSize
            self.minNonFinalFragmentSize = minNonFinalFragmentSize
            self.maxAccumulatedFrameCount = maxAccumulatedFrameCount
            self.maxAccumulatedFrameSize = maxAccumulatedFrameSize
            self.writeBufferWaterMarkLow = writeBufferWaterMarkLow
            self.writeBufferWaterMarkHigh = writeBufferQaterMarkHigh
            self.connectionTimeout = connectionTimeout
            self.autoPingConfiguration = autoPingConfiguration
            self.deviceName = deviceName
            self.socketSendBufferSize = socketSendBufferSize
            self.socketReceiveBufferSize = socketReceiveBufferSize
            self.leftoverBytesStrategy = leftoverBytesStrategy
        }
    }
}

extension LCLWebSocket.Configuration {
    /// Configure the WebSocket to automatically send Ping frame to keep the connection alive.
    public struct AutoPingConfiguration: Sendable {
        var keepAlive: Bool
        var pingInterval: TimeAmount
        var pingTimeout: TimeAmount

        internal init(keepAlive: Bool, pingInterval: TimeAmount, pingTimeout: TimeAmount) {
            self.keepAlive = keepAlive
            self.pingInterval = pingInterval
            self.pingTimeout = pingTimeout
        }

        /// Configuration that tells the WebSocket not to send Ping frame automatically
        public static let disabled: Self = AutoPingConfiguration(
            keepAlive: false,
            pingInterval: .seconds(0),
            pingTimeout: .seconds(0)
        )

        /// Configuration that enables sending Ping frame automatically with the provided `pingInterval`. WebSocket connection
        /// will time out if the corresponding Pong frame is not received within `pingTimeout`.
        ///
        /// - Parameters:
        ///     - pingInterval: the frequency at which the WebSocket will send a Ping frame.
        ///     - pingTimeout: the amount of time to wait for the corresponding Pong frame to arrive.
        public static func enabled(pingInterval: TimeAmount, pingTimeout: TimeAmount) -> Self {
            .init(keepAlive: true, pingInterval: pingInterval, pingTimeout: pingTimeout)
        }
    }
}
