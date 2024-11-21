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
    public struct Configuration: Sendable {
        let tlsConfiguration: TLSConfiguration?
        var maxFrameSize: Int
        var minNonFinalFragmentSize: Int
        var maxAccumulatedFrameCount: Int
        var maxAccumulatedFrameSize: Int
        var writeBufferWaterMarkLow: Int {
            willSet {
                precondition(
                    newValue >= 1 && newValue <= writeBufferWaterMarkHigh,
                    "writeBufferWaterMarkLow should be between 1 and writeBufferWaterMarkHigh"
                )
            }
        }
        var writeBufferWaterMarkHigh: Int {
            willSet {
                precondition(
                    newValue >= writeBufferWaterMarkLow,
                    "writeBufferWaterMarkHigh should be greater than or equal to writeBufferWaterMarkLow"
                )
            }
        }
        var connectionTimeout: TimeAmount
        var deviceName: String?
        var autoPingConfiguration: AutoPingConfiguration

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
            deviceName: String? = nil
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
        }
    }
}

extension LCLWebSocket.Configuration {
    public struct AutoPingConfiguration: Sendable {
        var keepAlive: Bool
        var pingInterval: TimeAmount
        var pingTimeout: TimeAmount

        internal init(keepAlive: Bool, pingInterval: TimeAmount, pingTimeout: TimeAmount) {
            self.keepAlive = keepAlive
            self.pingInterval = pingInterval
            self.pingTimeout = pingTimeout
        }

        public static let disabled: Self = AutoPingConfiguration(
            keepAlive: false,
            pingInterval: .seconds(0),
            pingTimeout: .seconds(0)
        )
        public static func enabled(pingInterval: TimeAmount, pingTimeout: TimeAmount) -> Self {
            .init(keepAlive: true, pingInterval: pingInterval, pingTimeout: pingTimeout)
        }
    }
}
