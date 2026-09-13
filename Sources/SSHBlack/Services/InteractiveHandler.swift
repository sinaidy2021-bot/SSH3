import NIOCore
import NIOSSH
import Foundation

/// SSH 通道 → 应用层：把字节流回抛给主线程
final class InteractiveHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let onData: (Data) -> Void
    private let onClose: () -> Void

    init(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.onData = onData
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        switch channelData.type {
        case .channel, .extendedChannel:
            var buffer = channelData.data
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                onData(Data(bytes))
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClose()
        context.close(promise: nil)
    }
}
