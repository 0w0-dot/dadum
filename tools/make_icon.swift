// 앱 아이콘 원본(1024px PNG)을 그린다. 흰 판 위의 "가"와 맞춤법 밑줄.
// 사용: swift tools/make_icon.swift <출력.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// 배경: macOS 아이콘 격자에 맞춘 둥근 사각형
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.22))
ctx.addPath(tile)
ctx.setFillColor(rgb(0xF7F5F0))
ctx.fillPath()
ctx.restoreGState()

// 글자 "가"
let font = NSFont(name: "Pretendard-Bold", size: 470) ?? NSFont.systemFont(ofSize: 470, weight: .bold)
let glyph = NSAttributedString(string: "가", attributes: [
    .font: font,
    .foregroundColor: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
])
let glyphSize = glyph.size()
glyph.draw(at: CGPoint(x: tileRect.midX - glyphSize.width / 2, y: tileRect.midY - glyphSize.height / 2 + 60))

// 맞춤법 검사기가 긋는 물결 밑줄
let wave = CGMutablePath()
let startX: CGFloat = 300, endX: CGFloat = 724, baseY: CGFloat = 300
let amplitude: CGFloat = 20, period: CGFloat = 84
wave.move(to: CGPoint(x: startX, y: baseY))
var x = startX
var up = true
while x < endX {
    let next = min(x + period / 2, endX)
    wave.addQuadCurve(to: CGPoint(x: next, y: baseY), control: CGPoint(x: (x + next) / 2, y: baseY + (up ? amplitude : -amplitude) * 2))
    up.toggle()
    x = next
}
ctx.addPath(wave)
ctx.setStrokeColor(rgb(0xE5484D))
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: output)
