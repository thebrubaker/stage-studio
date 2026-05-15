// Renders the three "classic" gradient styles at 1920x1080 PNGs so we can
// pick a default without spinning up a full SCK recording for each.
//
// Run:
//   swiftc -O cmd/gradient-preview/main.swift -o cmd/gradient-preview/preview
//   ./cmd/gradient-preview/preview out/gradients
//
// Output: <dir>/linear.png, <dir>/radial.png, <dir>/mesh.png

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: preview <output-dir>\n".utf8))
    exit(64)
}
let outDir = args[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let W = 1920
let H = 1080

let ciContext = CIContext()

func writePNG(_ ci: CIImage, to path: String) throws {
    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    guard let cg = ciContext.createCGImage(ci, from: rect) else {
        throw NSError(domain: "preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed for \(path)"])
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "preview", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed for \(path)"])
    }
    try data.write(to: URL(fileURLWithPath: path))
    FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
}

// 1. Linear (2-stop): the classic CSS gradient. Peach top-left → mocha bottom-right.
func renderLinear() -> CIImage {
    let f = CIFilter(name: "CILinearGradient")!
    f.setValue(CIVector(x: 0, y: CGFloat(H)), forKey: "inputPoint0")
    f.setValue(CIColor(red: 0.96, green: 0.69, blue: 0.45), forKey: "inputColor0")
    f.setValue(CIVector(x: CGFloat(W), y: 0), forKey: "inputPoint1")
    f.setValue(CIColor(red: 0.18, green: 0.09, blue: 0.10), forKey: "inputColor1")
    return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

// 2. Radial: warm spotlight in the middle, falls off to deep warm at corners.
// Slightly off-center for that "natural photo light" feel rather than dead-center.
func renderRadial() -> CIImage {
    let f = CIFilter(name: "CIRadialGradient")!
    // Center slightly above-right for a "sun in the sky" feel.
    f.setValue(CIVector(x: CGFloat(W) * 0.6, y: CGFloat(H) * 0.65), forKey: "inputCenter")
    f.setValue(NSNumber(value: 0), forKey: "inputRadius0")
    f.setValue(NSNumber(value: Float(max(W, H)) * 0.8), forKey: "inputRadius1")
    f.setValue(CIColor(red: 0.99, green: 0.75, blue: 0.50), forKey: "inputColor0")  // warm peach center
    f.setValue(CIColor(red: 0.12, green: 0.05, blue: 0.07), forKey: "inputColor1")  // near-black edges
    return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

// 3. Mesh: SwiftUI MeshGradient (current default).
@MainActor
func renderMesh() -> CIImage {
    let view = MeshGradient(
        width: 3,
        height: 3,
        points: [
            [0.00, 0.00], [0.50, 0.00], [1.00, 0.00],
            [0.00, 0.50], [0.55, 0.45], [1.00, 0.50],
            [0.00, 1.00], [0.50, 1.00], [1.00, 1.00],
        ],
        colors: [
            Color(red: 0.99, green: 0.80, blue: 0.62),
            Color(red: 0.96, green: 0.65, blue: 0.40),
            Color(red: 0.85, green: 0.45, blue: 0.32),
            Color(red: 0.78, green: 0.42, blue: 0.32),
            Color(red: 0.55, green: 0.28, blue: 0.25),
            Color(red: 0.45, green: 0.22, blue: 0.22),
            Color(red: 0.32, green: 0.16, blue: 0.18),
            Color(red: 0.22, green: 0.11, blue: 0.13),
            Color(red: 0.12, green: 0.07, blue: 0.09),
        ]
    )
    .frame(width: CGFloat(W), height: CGFloat(H))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    guard let cg = renderer.cgImage else {
        return CIImage(color: CIColor(red: 0.55, green: 0.28, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }
    return CIImage(cgImage: cg)
}

Task {
    do {
        try writePNG(renderLinear(), to: "\(outDir)/linear.png")
        try writePNG(renderRadial(), to: "\(outDir)/radial.png")
        let mesh = await MainActor.run { renderMesh() }
        try writePNG(mesh, to: "\(outDir)/mesh.png")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
