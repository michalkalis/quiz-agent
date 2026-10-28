//
//  QRCodeImage.swift
//  Hangs
//
//  #212: the host's invite as a QR code the guests' cameras open.
//

import CoreImage.CIFilterBuiltins
import UIKit

enum QRCodeImage {
    /// A crisp QR code for `text`, nil if Core Image cannot render it.
    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scaled up by whole pixels: interpolation would blur the modules.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
