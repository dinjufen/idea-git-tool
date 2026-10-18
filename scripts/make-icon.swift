// 生成 GitDeck 应用图标（1024×1024 PNG）。
//
// 用法：swift scripts/make-icon.swift <输出.png>
// 图形：一条主线与从它分出、再合并回来的分支，轮廓构成字母 “D”（GitDeck）；
// 深墨蓝底 + 薄荷绿分支。按 macOS 图标网格绘制：1024 画布中 824×824 的连续圆角方形，带柔和阴影。

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let inset: CGFloat = 100
let shape = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// 连续曲率的圆角方形（superellipse，接近 Apple 图标的 squircle）。
func squircle(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720
    for i in 0 ... steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t)
        let s = sin(t)
        let x = a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / exponent)
        let y = b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / exponent)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// 以左上角为原点，便于按设计稿坐标绘制。
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

let tile = squircle(shape)

// 柔和的投影。
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tile)
ctx.setFillColor(color(0x14213D))
ctx.fillPath()
ctx.restoreGState()

// 底色：自上而下的墨蓝渐变 + 顶部高光。
ctx.saveGState()
ctx.addPath(tile)
ctx.clip()
let background = CGGradient(colorsSpace: colorSpace, colors: [color(0x22386A), color(0x0E1830)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: size / 2, y: inset), end: CGPoint(x: size / 2, y: size - inset), options: [])
let highlight = CGGradient(colorsSpace: colorSpace, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(highlight, startCenter: CGPoint(x: size / 2, y: inset - 120), startRadius: 0,
                       endCenter: CGPoint(x: size / 2, y: inset - 120), endRadius: 620, options: [])
ctx.restoreGState()

// 内描边，增加边缘层次。
ctx.saveGState()
ctx.addPath(tile)
ctx.setStrokeColor(color(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 分支 D：主线 + 分出又合并回来的弧线。
let mainX: CGFloat = 386
let top: CGFloat = 292
let bottom: CGFloat = 732
let arcControl: CGFloat = 766
let stroke: CGFloat = 60

let branch = CGMutablePath()
branch.move(to: CGPoint(x: mainX, y: top))
branch.addLine(to: CGPoint(x: mainX, y: bottom))
branch.move(to: CGPoint(x: mainX, y: top))
branch.addCurve(to: CGPoint(x: mainX, y: bottom),
                control1: CGPoint(x: arcControl, y: top),
                control2: CGPoint(x: arcControl, y: bottom))

let mint = CGGradient(colorsSpace: colorSpace, colors: [color(0x6EF0B6), color(0x22C08A)] as CFArray, locations: [0, 1])!

/// 用薄荷绿渐变绘制路径的描边或填充。
func paintMint(_ path: CGPath, strokeWidth: CGFloat? = nil) {
    ctx.saveGState()
    ctx.addPath(path)
    if let strokeWidth {
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
    }
    ctx.clip()
    ctx.drawLinearGradient(mint, start: CGPoint(x: 0, y: top - 80), end: CGPoint(x: 0, y: bottom + 80), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// 分支线下方的微弱光晕，让图形从深色底中浮起。
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: color(0x3DDC97, 0.35))
ctx.addPath(branch)
ctx.setLineWidth(stroke)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0x3DDC97, 0.9))
ctx.strokePath()
ctx.restoreGState()
paintMint(branch, strokeWidth: stroke)

// 提交节点：两端为实心大节点，中间为空心节点（主线与分支各一个）。
let rightmost = mainX + 0.75 * (arcControl - mainX)
let middle = (top + bottom) / 2
for center in [CGPoint(x: mainX, y: top), CGPoint(x: mainX, y: bottom)] {
    paintMint(CGPath(ellipseIn: CGRect(x: center.x - 72, y: center.y - 72, width: 144, height: 144), transform: nil))
}
for center in [CGPoint(x: mainX, y: middle), CGPoint(x: rightmost, y: middle)] {
    let outer = CGRect(x: center.x - 58, y: center.y - 58, width: 116, height: 116)
    paintMint(CGPath(ellipseIn: outer, transform: nil))
    ctx.addPath(CGPath(ellipseIn: outer.insetBy(dx: 30, dy: 30), transform: nil))
    ctx.setFillColor(color(0x15254A))
    ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(CommandLine.arguments[1])")
