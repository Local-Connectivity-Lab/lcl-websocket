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
import Logging

let LOGGER_LABEL = "org.seattlecommunitynetwork.lclwebsocket"

var logger: Logger {
    get {
        var logger = Logger(label: LOGGER_LABEL)
        #if DEBUG
        logger.logLevel = .debug
        #else  // !LOG
        logger.logLevel = .info
        #endif
        return logger
    }
}
