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

extension TimeAmount {

    /// The number of seconds that this `TimeAmount` represents
    var seconds: Int64 {
        self.nanoseconds / 1_000_000_000
    }
}
