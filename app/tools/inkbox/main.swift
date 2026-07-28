// inkbox — a measuring instrument for the pill's optical centering.
//
// "Looks centered" is not a verification. This loads a screenshot, finds the
// actual INK (light pixels on the near-black pill) inside a column range, and
// reports its top/bottom/center in image pixels next to the reference midline —
// so a claim about centering is a number, not an impression.
//
// Compile: swiftc -O main.swift -o inkbox
// Usage:   inkbox <png> <x0> <x1> [midlineY] [threshold]
//          coordinates are IMAGE PIXELS (a 2x Retina shot is 2x the point size)

import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: inkbox <png> <x0> <x1> [midlineY] [threshold]\n".utf8))
    exit(64)
}
let path = args[1]
let x0 = Int(args[2])!
let x1 = Int(args[3])!
let threshold = args.count >= 6 ? Double(args[5])! : 100.0

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(1)
}

let w = img.width
let h = img.height
let midline = args.count >= 5 ? Double(args[4])! : Double(h) / 2.0

var pixels = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("cannot make bitmap context\n".utf8))
    exit(1)
}
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

var top = -1
var bottom = -1
var inkRows = 0
for y in 0..<h {
    var rowHasInk = false
    for x in max(0, x0)..<min(w, x1) {
        let i = (y * w + x) * 4
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        if lum > threshold { rowHasInk = true; break }
    }
    if rowHasInk {
        if top < 0 { top = y }
        bottom = y
        inkRows += 1
    }
}

guard top >= 0 else {
    print("no ink found in x \(x0)..<\(x1) above threshold \(threshold)")
    exit(2)
}

let center = Double(top + bottom) / 2.0
let delta = center - midline
print(String(format: "image %dx%d  x %d..<%d", w, h, x0, x1))
print(String(format: "ink top=%d bottom=%d height=%d center=%.1f", top, bottom, bottom - top + 1, center))
print(String(format: "midline=%.1f  delta=%+.1f px (%+.2f pt @2x)  %@",
             midline, delta, delta / 2,
             abs(delta) <= 1 ? "CENTERED" : (delta < 0 ? "ink rides HIGH" : "ink rides LOW")))
