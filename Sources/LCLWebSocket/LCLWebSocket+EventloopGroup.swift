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
