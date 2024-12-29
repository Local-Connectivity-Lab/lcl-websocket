//
//  File.swift
//  LCLWebSocket
//
//  Created by Zhennan Zhou on 12/18/24.
//

import Foundation
import NIOCore

extension TimeAmount {
    var seconds: Int64 {
        self.nanoseconds / 1_000_000_000
    }
}
