import Flutter
import UIKit

@_silgen_name("codux_iroh_close")
private func coduxIrohClose(_ handle: UInt64)

@_silgen_name("codux_iroh_connect")
private func coduxIrohConnect(_ configJson: UnsafePointer<CChar>) -> UInt64

@_silgen_name("codux_iroh_send")
private func coduxIrohSend(_ handle: UInt64, _ envelopeJson: UnsafePointer<CChar>) -> Bool

@_silgen_name("codux_iroh_poll_event")
private func coduxIrohPollEvent(_ handle: UInt64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("codux_iroh_free_string")
private func coduxIrohFreeString(_ value: UnsafeMutablePointer<CChar>?)

public final class CoduxRemoteIrohPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        "".withCString { empty in
            _ = coduxIrohConnect(empty)
            _ = coduxIrohSend(0, empty)
        }
        _ = coduxIrohPollEvent(0)
        coduxIrohFreeString(nil)
        coduxIrohClose(0)
    }
}
