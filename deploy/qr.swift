// Draws a QR code for a string as a PNG: swift qr.swift <text> <out.png>
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: qr.swift <text> <out.png>\n".utf8))
    exit(2)
}
let filter = CIFilter.qrCodeGenerator()
filter.message = Data(arguments[1].utf8)
filter.correctionLevel = "M"
guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else { exit(1) }
let context = CIContext()
guard let image = context.createCGImage(code, from: code.extent),
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
