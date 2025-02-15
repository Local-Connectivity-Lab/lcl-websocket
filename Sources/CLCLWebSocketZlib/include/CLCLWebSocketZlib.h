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

#ifndef C_LCLWEBSOCKET_ZLIB_H
#define C_LCLWEBSOCKET_ZLIB_H

#include <zlib.h>

static inline int CLCLWebSocketZlib_deflateInit2(z_streamp strm,
                                                 int level,
                                                 int method,
                                                 int windowBits,
                                                 int memLevel,
                                                 int strategy) {
       return deflateInit2(strm, level, method, windowBits, memLevel, strategy);
}

static inline int CLCLWebSocketZlib_inflateInit2(z_streamp strm, int windowBits) {
    return inflateInit2(strm, windowBits);
}

static inline Bytef *CLCLWebSocketZlib_voidPtr_to_BytefPtr(void *in) {
    return (Bytef *)in;
}

#endif // C_LCLWEBSOCKET_ZLIB_H
