// DrawingPrimitives.swift — Core Graphics drawing utilities
//
// Ported from trcc_monitor.py drawing functions.
// All drawing uses CGContext directly for maximum control.

import AppKit
import CoreGraphics
import Foundation

enum Draw {

    // MARK: - Background

    /// Classic dashboard background. Keep it pure black to match the
    /// Apple Watch theme and improve contrast on the LCD.
    static func gradientBackground(_ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(
            x: 0, y: 0, width: Layout.width, height: Layout.height))
    }

    // MARK: - Panel

    /// Draw a pure-black rounded panel separated only by a subtle outline.
    /// Assumes flipped context (Y=0 at top).
    static func panel(_ ctx: CGContext, x: Int, y: Int, w: Int, h: Int, accent: CGColor) {
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setStrokeColor(CGColor(
            red: 52 / 255, green: 52 / 255, blue: 56 / 255, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.addPath(path)
        ctx.strokePath()

        // Keep the module accent at the top, without the old glow beneath it.
        let barRect = CGRect(x: x + 12, y: y, width: w - 24, height: 3)
        let barPath = CGPath(
            roundedRect: barRect, cornerWidth: 2, cornerHeight: 2,
            transform: nil)
        ctx.setFillColor(accent)
        ctx.addPath(barPath)
        ctx.fillPath()
    }

    // MARK: - Arc Gauge

    /// Draw an arc gauge (like speedometer).
    /// Assumes flipped context (Y=0 at top, like PIL).
    /// PIL arc: start=135°, sweep=270° clockwise.
    /// In flipped CG: clockwise in screen space = clockwise:false in CG API.
    static func arcGauge(
        _ ctx: CGContext, cx: Int, cy: Int, radius: Int,
        percent: Double, color: CGColor, colorDark: CGColor, thickness: CGFloat = 12
    ) {
        let r = CGFloat(radius)
        let center = CGPoint(x: CGFloat(cx), y: CGFloat(cy))

        // In flipped context, Y is inverted so angles go clockwise visually
        // PIL: start=135, end=135+270=405. CG flipped: use positive angles, clockwise=false
        let startAngle = CGFloat(135) * .pi / 180
        let fullEndAngle = CGFloat(135 + 270) * .pi / 180

        // Background arc
        ctx.setStrokeColor(colorDark)
        ctx.setLineWidth(thickness)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: r, startAngle: startAngle,
                   endAngle: fullEndAngle, clockwise: false)
        ctx.strokePath()

        // Foreground arc (percentage)
        if percent > 0 {
            let pct = min(percent, 100)
            let sweepAngle = startAngle + (fullEndAngle - startAngle) * CGFloat(pct / 100)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(thickness)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: r, startAngle: startAngle,
                       endAngle: sweepAngle, clockwise: false)
            ctx.strokePath()

            // End dot — in flipped context, sin goes downward (+Y)
            let dotR = thickness / 2
            let ex = CGFloat(cx) + r * cos(sweepAngle)
            let ey = CGFloat(cy) + r * sin(sweepAngle)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: ex - dotR, y: ey - dotR,
                                       width: dotR * 2, height: dotR * 2))
        }
    }

    // MARK: - Bar

    /// Draw a rounded progress bar
    static func bar(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        percent: Double, color: CGColor, bg: CGColor = Color.barBG
    ) {
        let radius = CGFloat(h) / 2

        // Background
        let bgRect = CGRect(x: x, y: y, width: w, height: h)
        ctx.setFillColor(bg)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // Fill
        if percent > 0 {
            let pct = min(percent, 100)
            let fw = max(h, Int(Double(w) * pct / 100))
            let fillRect = CGRect(x: x, y: y, width: fw, height: h)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }

    // MARK: - Text

    /// Draw text at position. Assumes context is already flipped (Y=0 at top).
    static func text(
        _ ctx: CGContext, _ string: String, x: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let nsStr = string as NSString

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        nsStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw centered text
    static func centeredText(
        _ ctx: CGContext, _ string: String, cx: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let size = (string as NSString).size(withAttributes: attrs)
        let x = CGFloat(cx) - size.width / 2
        text(ctx, string, x: Int(x), y: y, font: font, color: color)
    }

    // MARK: - Line

    static func line(
        _ ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat = 1
    ) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    // MARK: - Sparkline (trend graph)

    /// Draw a mirrored bar chart with labels above and below.
    /// Layout:  [topLabel topValue]
    ///          [====chart area====]
    ///          [botLabel botValue]
    /// Total height = labelH + chartH + labelH
    static func mirrorBarChart(
        _ ctx: CGContext,
        topValues: [Double], bottomValues: [Double],
        x: Int, y: Int, w: Int, h: Int,
        topColor: CGColor, bottomColor: CGColor,
        topLabel: String, bottomLabel: String,
        topCurrent: String, bottomCurrent: String
    ) {
        let labelH = 16
        let chartY = y + labelH + 2
        let chartH = h - (labelH + 2) * 2
        guard chartH > 4 else { return }

        let midY = CGFloat(chartY + chartH / 2)
        let halfH = CGFloat(chartH / 2)
        let count = max(topValues.count, bottomValues.count)
        guard count > 0 else { return }

        let barW = max(1, CGFloat(w) / CGFloat(count))
        let topMax = topValues.max() ?? 1
        let botMax = bottomValues.max() ?? 1
        let maxVal = max(topMax, botMax, 1)

        // Top label line
        text(ctx, "\(topLabel) \(topCurrent)", x: x, y: y,
             font: Fonts.system(15), color: topColor)

        // Center axis
        ctx.setStrokeColor(Color.border)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: CGFloat(x), y: midY))
        ctx.addLine(to: CGPoint(x: CGFloat(x + w), y: midY))
        ctx.strokePath()

        // Top bars (grow upward)
        for (i, val) in topValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(topColor.copy(alpha: 0.8) ?? topColor)
            ctx.fill(CGRect(x: bx, y: midY - barH, width: max(barW - 1, 1), height: barH))
        }

        // Bottom bars (grow downward)
        for (i, val) in bottomValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(bottomColor.copy(alpha: 0.8) ?? bottomColor)
            ctx.fill(CGRect(x: bx, y: midY, width: max(barW - 1, 1), height: barH))
        }

        // Bottom label line
        text(ctx, "\(bottomLabel) \(bottomCurrent)", x: x, y: y + h - labelH,
             font: Fonts.system(15), color: bottomColor)
    }

    /// Format bytes per second to human-readable string
    static func formatBytesPerSec(_ bps: Double) -> String {
        if bps >= 1_000_000_000 { return String(format: "%.1f GB/s", bps / 1e9) }
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1e6) }
        if bps >= 1_000 { return String(format: "%.1f KB/s", bps / 1e3) }
        return String(format: "%.0f B/s", bps)
    }
}
