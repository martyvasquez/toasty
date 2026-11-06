import CoreGraphics

/// Box-drawing, block-element and Powerline characters drawn as shapes that
/// fill their cell exactly, like Ghostty does, so lines and blocks join
/// seamlessly whatever the font and line height.
enum TerminalSprites {
    static func handles(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let v = text.unicodeScalars.first?.value else { return false }
        return (0x2500...0x259F).contains(v) || (0xE0B0...0xE0B3).contains(v)
    }

    /// Line weights (up, right, down, left): 0 none, 1 light, 2 heavy, 3 double.
    private static let lines: [UInt32: (Int, Int, Int, Int)] = {
        let table: [(UInt32, String)] = [
            (0x2500, "0101"), (0x2501, "0202"), (0x2502, "1010"), (0x2503, "2020"),
            (0x250C, "0110"), (0x250D, "0210"), (0x250E, "0120"), (0x250F, "0220"),
            (0x2510, "0011"), (0x2511, "0012"), (0x2512, "0021"), (0x2513, "0022"),
            (0x2514, "1100"), (0x2515, "1200"), (0x2516, "2100"), (0x2517, "2200"),
            (0x2518, "1001"), (0x2519, "1002"), (0x251A, "2001"), (0x251B, "2002"),
            (0x251C, "1110"), (0x251D, "1210"), (0x251E, "2110"), (0x251F, "1120"),
            (0x2520, "2120"), (0x2521, "2210"), (0x2522, "1220"), (0x2523, "2220"),
            (0x2524, "1011"), (0x2525, "1012"), (0x2526, "2011"), (0x2527, "1021"),
            (0x2528, "2021"), (0x2529, "2012"), (0x252A, "1022"), (0x252B, "2022"),
            (0x252C, "0111"), (0x252D, "0112"), (0x252E, "0211"), (0x252F, "0212"),
            (0x2530, "0121"), (0x2531, "0122"), (0x2532, "0221"), (0x2533, "0222"),
            (0x2534, "1101"), (0x2535, "1102"), (0x2536, "1201"), (0x2537, "1202"),
            (0x2538, "2101"), (0x2539, "2102"), (0x253A, "2201"), (0x253B, "2202"),
            (0x253C, "1111"), (0x253D, "1112"), (0x253E, "1211"), (0x253F, "1212"),
            (0x2540, "2111"), (0x2541, "1121"), (0x2542, "2121"), (0x2543, "2112"),
            (0x2544, "2211"), (0x2545, "1122"), (0x2546, "1221"), (0x2547, "2212"),
            (0x2548, "1222"), (0x2549, "2122"), (0x254A, "2221"), (0x254B, "2222"),
            (0x2550, "0303"), (0x2551, "3030"), (0x2552, "0310"), (0x2553, "0130"),
            (0x2554, "0330"), (0x2555, "0013"), (0x2556, "0031"), (0x2557, "0033"),
            (0x2558, "1300"), (0x2559, "3100"), (0x255A, "3300"), (0x255B, "1003"),
            (0x255C, "3001"), (0x255D, "3003"), (0x255E, "1310"), (0x255F, "3130"),
            (0x2560, "3330"), (0x2561, "1013"), (0x2562, "3031"), (0x2563, "3033"),
            (0x2564, "0313"), (0x2565, "0131"), (0x2566, "0333"), (0x2567, "1303"),
            (0x2568, "3101"), (0x2569, "3303"), (0x256A, "1313"), (0x256B, "3131"),
            (0x256C, "3333"),
            (0x2574, "0001"), (0x2575, "1000"), (0x2576, "0100"), (0x2577, "0010"),
            (0x2578, "0002"), (0x2579, "2000"), (0x257A, "0200"), (0x257B, "0020"),
            (0x257C, "0201"), (0x257D, "1020"), (0x257E, "0102"), (0x257F, "2010"),
        ]
        var map: [UInt32: (Int, Int, Int, Int)] = [:]
        for (cp, s) in table {
            let d = s.map { Int(String($0))! }
            map[cp] = (d[0], d[1], d[2], d[3])
        }
        return map
    }()

    /// Dashed lines: (horizontal?, heavy?, dash count).
    private static let dashes: [UInt32: (Bool, Bool, Int)] = [
        0x2504: (true, false, 3), 0x2505: (true, true, 3), 0x2506: (false, false, 3), 0x2507: (false, true, 3),
        0x2508: (true, false, 4), 0x2509: (true, true, 4), 0x250A: (false, false, 4), 0x250B: (false, true, 4),
        0x254C: (true, false, 2), 0x254D: (true, true, 2), 0x254E: (false, false, 2), 0x254F: (false, true, 2),
    ]

    /// Draws `text` into `r` (flipped coordinates: y grows downward).
    static func draw(_ text: String, in ctx: CGContext, rect r: CGRect, color: CGColor, scale: CGFloat) {
        guard let v = text.unicodeScalars.first?.value else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        let px = 1 / scale
        let light = max(px, (r.width / 8 * scale).rounded() / scale)
        let heavy = light * 2
        let cx = snap(r.midX, scale), cy = snap(r.midY, scale)

        if let (u, rt, d, l) = lines[v] {
            func thickness(_ w: Int) -> CGFloat { w == 2 ? heavy : light }
            // Light/heavy strokes: rectangles from the center to each edge,
            // overlapping at the center so they join.
            func arm(_ w: Int, _ dir: Int) {
                guard w == 1 || w == 2 else { return }
                let t = thickness(w)
                let joinH = max(thickness(u), thickness(d)) / 2, joinV = max(thickness(l), thickness(rt)) / 2
                switch dir {
                case 0: ctx.fill(CGRect(x: cx - t / 2, y: r.minY, width: t, height: cy - r.minY + joinV))
                case 2: ctx.fill(CGRect(x: cx - t / 2, y: cy - joinV, width: t, height: r.maxY - cy + joinV))
                case 1: ctx.fill(CGRect(x: cx - joinH, y: cy - t / 2, width: r.maxX - cx + joinH, height: t))
                default: ctx.fill(CGRect(x: r.minX, y: cy - t / 2, width: cx - r.minX + joinH, height: t))
                }
            }
            arm(u, 0); arm(rt, 1); arm(d, 2); arm(l, 3)
            // Double strokes: two light lines, gap of one light width.
            let g = light
            if u == 3 || d == 3 {
                for dx in [-g - light / 2, g + light / 2] {
                    let x = cx + dx - light / 2
                    let top = u == 3 ? r.minY : cy - g - light
                    let bottom = d == 3 ? r.maxY : cy + g + light
                    ctx.fill(CGRect(x: x, y: top, width: light, height: bottom - top))
                }
            }
            if l == 3 || rt == 3 {
                for dy in [-g - light / 2, g + light / 2] {
                    let y = cy + dy - light / 2
                    let left = l == 3 ? r.minX : cx - g - light
                    let right = rt == 3 ? r.maxX : cx + g + light
                    ctx.fill(CGRect(x: left, y: y, width: right - left, height: light))
                }
            }
            return
        }

        if let (horizontal, isHeavy, count) = dashes[v] {
            let t = isHeavy ? heavy : light
            let length = horizontal ? r.width : r.height
            let seg = length / CGFloat(count)
            let gap = seg * 0.35
            for i in 0..<count {
                let start = CGFloat(i) * seg + gap / 2
                if horizontal { ctx.fill(CGRect(x: r.minX + start, y: cy - t / 2, width: seg - gap, height: t)) }
                else { ctx.fill(CGRect(x: cx - t / 2, y: r.minY + start, width: t, height: seg - gap)) }
            }
            return
        }

        switch v {
        case 0x256D...0x2570:
            // Rounded corners ╭ ╮ ╯ ╰.
            let radius = min(r.width, r.height) / 2
            let path = CGMutablePath()
            switch v {
            case 0x256D: // ╭ right + down
                path.move(to: CGPoint(x: r.maxX, y: cy))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: r.maxY), radius: radius)
                path.addLine(to: CGPoint(x: cx, y: r.maxY))
            case 0x256E: // ╮ left + down
                path.move(to: CGPoint(x: r.minX, y: cy))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: r.maxY), radius: radius)
                path.addLine(to: CGPoint(x: cx, y: r.maxY))
            case 0x256F: // ╯ left + up
                path.move(to: CGPoint(x: r.minX, y: cy))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: r.minY), radius: radius)
                path.addLine(to: CGPoint(x: cx, y: r.minY))
            default: // ╰ right + up
                path.move(to: CGPoint(x: r.maxX, y: cy))
                path.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: cx, y: r.minY), radius: radius)
                path.addLine(to: CGPoint(x: cx, y: r.minY))
            }
            ctx.setLineWidth(light)
            ctx.setLineCap(.butt)
            ctx.addPath(path)
            ctx.strokePath()
        case 0x2571...0x2573:
            ctx.setLineWidth(light)
            if v != 0x2572 { ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)]) }
            if v != 0x2571 { ctx.strokeLineSegments(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]) }
        case 0x2580: ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: snap(r.height / 2, scale)))
        case 0x2581...0x2588:
            let h = snap(r.height * CGFloat(v - 0x2580) / 8, scale)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h))
        case 0x2589...0x258F:
            let w = snap(r.width * CGFloat(8 - (v - 0x2588)) / 8, scale)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
        case 0x2590:
            let hw = snap(r.width / 2, scale)
            ctx.fill(CGRect(x: r.minX + hw, y: r.minY, width: r.width - hw, height: r.height))
        case 0x2591...0x2593:
            ctx.setFillColor(color.copy(alpha: (color.alpha) * CGFloat(v - 0x2590) / 4) ?? color)
            ctx.fill(r)
        case 0x2594: ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: max(px, snap(r.height / 8, scale))))
        case 0x2595: ctx.fill(CGRect(x: r.maxX - r.width / 8, y: r.minY, width: r.width / 8, height: r.height))
        case 0x2596...0x259F:
            // Quadrants: upper-left, upper-right, lower-left, lower-right.
            let q: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            guard let (ul, ur, ll, lr) = q[v] else { return }
            let hw = snap(r.width / 2, scale), hh = snap(r.height / 2, scale)
            if ul { ctx.fill(CGRect(x: r.minX, y: r.minY, width: hw, height: hh)) }
            if ur { ctx.fill(CGRect(x: r.minX + hw, y: r.minY, width: r.width - hw, height: hh)) }
            if ll { ctx.fill(CGRect(x: r.minX, y: r.minY + hh, width: hw, height: r.height - hh)) }
            if lr { ctx.fill(CGRect(x: r.minX + hw, y: r.minY + hh, width: r.width - hw, height: r.height - hh)) }
        case 0xE0B0, 0xE0B2:
            // Powerline solid arrows.
            let path = CGMutablePath()
            if v == 0xE0B0 {
                path.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY)])
            } else {
                path.addLines(between: [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY)])
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        case 0xE0B1, 0xE0B3:
            ctx.setLineWidth(light)
            if v == 0xE0B1 {
                ctx.addLines(between: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY)])
            } else {
                ctx.addLines(between: [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY)])
            }
            ctx.strokePath()
        default:
            break
        }
    }

    private static func snap(_ v: CGFloat, _ scale: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
}
