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

#if canImport(Network)
import Network
#endif

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import NIOTransportServices
#endif

extension LCLWebSocket {
    public static var defaultEventloopGroup: EventLoopGroup {
        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, visionOS 1.0, *) {
            NIOTSEventLoopGroup.singleton
        } else {
            MultiThreadedEventLoopGroup.singleton
        }
        #else
        MultiThreadedEventLoopGroup.singleton
        #endif
    }

    public static func makeEventLoopGroup(size: Int) -> EventLoopGroup {
        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, visionOS 1.0, *) {
            NIOTSEventLoopGroup(loopCount: size)
        } else {
            MultiThreadedEventLoopGroup(numberOfThreads: size)
        }
        #else
        MultiThreadedEventLoopGroup(numberOfThreads: size)
        #endif
    }
}
