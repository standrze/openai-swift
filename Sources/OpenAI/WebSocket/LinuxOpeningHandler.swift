#if os(Linux)
    import NIOCore
    import NIOHTTP1

    /// HTTP upgrade plumbing only; NIO validates the WebSocket handshake and installs its framing handlers.
    final class LinuxOpeningHandler: ChannelInboundHandler, RemovableChannelHandler {
        typealias InboundIn = HTTPClientResponsePart
        typealias OutboundOut = HTTPClientRequestPart
        let head: HTTPRequestHead
        private weak var owner: LinuxWebSocketConnection?

        init(head: HTTPRequestHead, owner: LinuxWebSocketConnection) {
            self.head = head
            self.owner = owner
        }
        func channelActive(context: ChannelHandlerContext) {
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            context.fireChannelActive()
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .head(let response) = unwrapInboundIn(data) {
                let headers = Dictionary(
                    response.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
                owner?.fail(
                    OpenAIWebSocketError.handshakeFailed(
                        statusCode: Int(response.status.code), headers: headers,
                        message: "Server rejected the WebSocket upgrade"))
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            owner?.fail(error)
            context.close(promise: nil)
        }
    }
#endif
