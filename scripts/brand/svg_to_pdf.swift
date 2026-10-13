// Vector PDF from an SVG via AppKit (CoreSVG), for the iOS asset catalog (assets are PDF, never SVG).
// Usage: xcrun swift scripts/brand/svg_to_pdf.swift <in.svg> <out.pdf>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    fatalError("usage: svg_to_pdf.swift <in.svg> <out.pdf>")
}
var box = CGRect(origin: .zero, size: image.size)
guard let pdf = CGContext(URL(fileURLWithPath: args[2]) as CFURL, mediaBox: &box, nil) else {
    fatalError("cannot write \(args[2])")
}
pdf.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
image.draw(in: box)
pdf.endPDFPage()
pdf.closePDF()
