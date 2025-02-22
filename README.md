# LCL WebSocket

LCL WebSocket is a cross-platform WebSocket [[RFC 6455]](https://datatracker.ietf.org/doc/html/rfc6455) library written in Swift and for Swift, built on top of SwiftNIO.



## Features

- Conform to all [AutoBahn](https://github.com/crossbario/autobahn-testsuite) cases
- High-performance WebSocket client and server, on top of SwiftNIO
- TLS/SSL support
- Thread-safe
- Cross-platform
- Customizable configurations
- Comprehensive error handling
- Support WebSocket per-message deflate extension (RFC 7692)

## Requirements
- Swift 5.9+
- macOS 10.15+, iOS 13+, Linux

## Getting Started

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Local-Connectivity-Lab/lcl-websocket.git", from: "1.0.0")
]
```

### Basic Usage

**Client**
```swift
let config = LCLWebSocket.Configuration(
    maxFrameSize: 1 << 16,
    autoPingConfiguration: .enabled(pingInterval: .seconds(4), pingTimeout: .seconds(10)),
    leftoverBytesStrategy: .forwardBytes
)

// Initialize the client
var client = LCLWebSocket.client()
client.onOpen { websocket in
    websocket.send(.init(string: "hello"), opcode: .text, promise: nil)
}

client.onBinary { websocket, binary in
    print("received binary: \(binary)")
}

client.onText { websocket, text in
    print("received text: \(text)")
}

try client.connect(to: "ws://127.0.0.1:8080", configuration: config).wait()
```

**Server**
```swift
let config = LCLWebSocket.Configuration(
    maxFrameSize: 1 << 16,
    autoPingConfiguration: .disabled,
    leftoverBytesStrategy: .forwardBytes
)

server.onPing { websocket, buffer in
    print("onPing: \(buffer)")
    websocket.pong(data: buffer)
}
server.onPong { ws, buffer in
    print("onPong: \(buffer)")
}
server.onBinary { websocket, buffer in
    websocket.send(buffer, opcode: .binary, promise: nil)
}
server.onText { websocket, text in
    print("received text: \(text)")
    websocket.send(.init(string: text), opcode: .text, promise: nil)
}
server.onClosing { code, reason in
    print("on closing: \(String(describing: code)), \(String(describing: reason))")
}

// wait forever
try server.listen(host: "127.0.0.1", port: 8080, configuration: config).wait()
```


## TODO
- [x] Support Swift Concurrency
- [x] Support WebSocket Compression Extension


## Contributing
Any contribution and pull requests are welcome! However, before you plan to implement some features or try to fix an uncertain issue, it is recommended to open a discussion first. You can also join our [Discord channel](https://discord.com/invite/gn4DKF83bP), or visit our [website](https://seattlecommunitynetwork.org/).

## License
lcl-websocket is released under Apache License. See [LICENSE](/LICENSE) for more details.
