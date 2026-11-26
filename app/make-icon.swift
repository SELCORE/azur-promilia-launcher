// 런처의 공개 배포용 아이콘(app/icon.png, 1024x1024)을 그려요. 게임 그림은 쓰지 않아요.
//   swift app/make-icon.swift app/icon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS 아이콘 격자: 1024 캔버스 안에 824 크기 둥근 사각형
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 그림자
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(color(0x1a1f4d)); ctx.fillPath()
ctx.restoreGState()

// 밤하늘 그라디언트
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                     colors: [color(0x0f1638), color(0x2b2f7a), color(0x4f5bc4), color(0x7aa6f0)] as CFArray,
                     locations: [0, 0.38, 0.75, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: size / 2, y: body.maxY), end: CGPoint(x: size / 2, y: body.minY), options: [])

// 아래쪽 은은한 빛
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(0xc9d8ff, 0.55), color(0xc9d8ff, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size / 2, y: body.minY + 40), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: body.minY + 40), endRadius: 460, options: [])

// 작은 별들
let dots: [(CGFloat, CGFloat, CGFloat)] = [(230, 760, 7), (300, 650, 4), (760, 300, 5), (820, 640, 4),
                                           (250, 330, 5), (680, 820, 4), (420, 830, 3), (860, 420, 3), (200, 520, 3)]
for (x, y, r) in dots {
    ctx.setFillColor(color(0xffffff, 0.85)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
}

// 초승달 (오른쪽 위)
let moonC = CGPoint(x: 735, y: 735), moonR: CGFloat = 78
ctx.saveGState()
let moon = CGMutablePath(); moon.addEllipse(in: CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: 2 * moonR, height: 2 * moonR))
ctx.addPath(moon); ctx.clip()
ctx.setFillColor(color(0xfff4d6)); ctx.fill(CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: 2 * moonR, height: 2 * moonR))
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: CGRect(x: moonC.x - moonR + 52, y: moonC.y - moonR + 44, width: 2 * moonR, height: 2 * moonR))
ctx.restoreGState()

// 큰 네 갈래 별 (가운데)
func sparkle(center c: CGPoint, long: CGFloat, short: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let pts = [CGPoint(x: c.x, y: c.y + long), CGPoint(x: c.x + short, y: c.y + short),
               CGPoint(x: c.x + long, y: c.y), CGPoint(x: c.x + short, y: c.y - short),
               CGPoint(x: c.x, y: c.y - long), CGPoint(x: c.x - short, y: c.y - short),
               CGPoint(x: c.x - long, y: c.y), CGPoint(x: c.x - short, y: c.y + short)]
    p.move(to: pts[0])
    for i in 1...8 {
        let a = pts[(i - 1) % 8], b = pts[i % 8]
        // 안쪽으로 살짝 휘게
        let mid = CGPoint(x: (a.x + b.x) / 2 * 0.86 + c.x * 0.14, y: (a.y + b.y) / 2 * 0.86 + c.y * 0.14)
        p.addQuadCurve(to: b, control: mid)
    }
    p.closeSubpath(); return p
}
let center = CGPoint(x: size / 2 - 20, y: size / 2 - 10)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: color(0xd6e4ff, 0.9))
ctx.addPath(sparkle(center: center, long: 290, short: 62)); ctx.setFillColor(color(0xffffff)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(sparkle(center: center, long: 290, short: 62)); ctx.clip()
let star = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [color(0xffffff), color(0xeaf0ff), color(0xffe6a8)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawRadialGradient(star, startCenter: center, startRadius: 0, endCenter: center, endRadius: 300, options: [])
ctx.restoreGState()
// 작은 반짝임
ctx.addPath(sparkle(center: CGPoint(x: 330, y: 300), long: 70, short: 16)); ctx.setFillColor(color(0xffffff, 0.95)); ctx.fillPath()

// 윗부분 반사광
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color(0xffffff, 0.16), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: size / 2, y: body.maxY), end: CGPoint(x: size / 2, y: body.midY), options: [])
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
