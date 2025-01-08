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

/// Bind the connection to the given `device` using the given `Channel`.
///
/// - Parameters:
///     - device: the device to bind to
///     - on: the channel that will be bound to the device
internal func bindTo(device: NIONetworkDevice, on channel: Channel) throws {
    #if canImport(Darwin)
    switch device.address {
    case .v4:
        try channel.syncOptions?.setOption(.ipOption(.ip_bound_if), value: CInt(device.interfaceIndex))
    case .v6:
        try channel.syncOptions?.setOption(.ipv6Option(.ipv6_bound_if), value: CInt(device.interfaceIndex))
    default:
        throw LCLWebSocketError.invalidDevice
    }
    #elseif canImport(Glibc) || canImport(Musl)
    return (channel as! SocketOptionProvider).setBindToDevice(device.name)
    #endif
}

/// Find the device on the machine with the given deviceName and protocol
///
/// - Parameters:
///     - with: the device name to find from the system
///     - protocol: the protocol that the device supports
internal func findDevice(with deviceName: String, protocol: NIOBSDSocket.ProtocolFamily) -> NIONetworkDevice? {
    do {
        for device in try System.enumerateDevices() {
            if device.name == deviceName, let address = device.address {
                switch (address.protocol, `protocol`) {
                case (.inet, .inet), (.inet6, .inet6):
                    return device
                default:
                    continue
                }
            }
        }
    } catch {
        logger.debug("Error occurred while finding device \(deviceName) and \(`protocol`): \(error)")
    }
    return nil
}
