import AppKit
import InkKit
import SwiftUI

// Renders the 1024px app icon: the header's drill glyph, white on black.
//   swift run IconMaker <out.png>

struct AppIcon: View {
    var body: some View {
        ZStack {
            // macOS icon grid: an 824pt rounded square centred on a 1024 canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color.black)
                .frame(width: 824, height: 824)
            // Same stroke-to-size ratio as the header logo (1.8 / 22).
            Glyph(.drill, size: Self.size, boiling: false, lineWidth: Self.size * 1.8 / 22, tint: .white)
        }
        .frame(width: 1024, height: 1024)
    }

    static let size: CGFloat = 540
}

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let renderer = ImageRenderer(content: AppIcon())
renderer.scale = 1
guard let cg = renderer.cgImage,
      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("could not render icon\n".utf8))
    exit(1)
}
try png.write(to: URL(filePath: out))
print("wrote \(out)")
