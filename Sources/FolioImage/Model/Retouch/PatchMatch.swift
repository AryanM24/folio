import CoreGraphics

/// PatchMatch texture synthesis (Barnes et al. 2009) for removing larger objects.
///
/// Push-pull fills are smooth; this one copies real texture. Coarse to fine over an
/// image pyramid: at each level, every 7×7 patch touching the hole finds its nearest
/// patch in the known area (random search plus propagation from neighbours, the
/// PatchMatch trick), then each hole pixel becomes the similarity-weighted vote of the
/// patches covering it (Wexler et al. 2007). A few rounds of that recover stripes,
/// brick and foliage that a blur can't. Pure Swift on the CPU, deterministic (seeded),
/// so callers run it on a proxy-sized region and store the result as a patch asset.
nonisolated enum PatchMatch {
    /// `image` with the white parts of `hole` (same size) synthesized from the rest.
    static func fill(_ image: CGImage, hole: CGImage) -> CGImage? {
        guard image.width == hole.width, image.height == hole.height, image.width >= 8, image.height >= 8,
            let pixels = Bitmap(image), let maskBitmap = Bitmap(hole)
        else { return nil }
        let isHole = stride(from: 0, to: maskBitmap.values.count, by: 4).map { maskBitmap.values[$0] > 0.5 }
        guard isHole.contains(true) else { return image }
        guard isHole.contains(false) else { return nil }

        // The pyramid: halve until the hole is a few patches across.
        var levels = [Level(bitmap: pixels, hole: isHole)]
        while levels.count < 6, let last = levels.last, last.holeSpan > 4 * radius + 2,
            min(last.bitmap.width, last.bitmap.height) / 2 >= 4 * radius + 2
        {
            levels.append(last.halved())
        }
        var rng = SplitMix(seed: 0x5EED)
        var solved: Level?
        for var level in levels.reversed() {
            if let coarser = solved { level.initialize(from: coarser) } else { level.onionPeel() }
            level.synthesize(iterations: solved == nil ? 8 : 4, rng: &rng)
            solved = level
        }
        return solved?.bitmap.cgImage(colorSpace: image.colorSpace)
    }

    /// Patch radius: 7×7 patches.
    static let radius = 3

    /// RGBA floats 0…1, premultiplied, top-left origin.
    struct Bitmap {
        var width: Int
        var height: Int
        var values: [Float]

        init(width: Int, height: Int, values: [Float]) {
            self.width = width
            self.height = height
            self.values = values
        }

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                let ctx = CGContext(
                    data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: image.colorSpace ?? space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    ?? CGContext(
                        data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            self.init(width: w, height: h, values: bytes.map { Float($0) / 255 })
        }

        func cgImage(colorSpace: CGColorSpace?) -> CGImage? {
            var bytes = values.map { UInt8(min(255, max(0, ($0 * 255).rounded()))) }
            guard let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                let ctx = CGContext(
                    data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// One pyramid level: pixels plus which of them are hole.
    struct Level {
        var bitmap: Bitmap
        var hole: [Bool]
        var width: Int { bitmap.width }
        var height: Int { bitmap.height }

        /// The hole's bounding-box size in pixels.
        var holeSpan: Int {
            var minX = width, maxX = -1, minY = height, maxY = -1
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return max(maxX - minX, maxY - minY) + 1
        }

        /// Half size. Known pixels average only known pixels (the hole holds the object
        /// being removed, which must not leak); a coarse pixel is hole if any of its four is.
        func halved() -> Level {
            let w = max(1, width / 2), h = max(1, height / 2)
            var values = [Float](repeating: 0, count: w * h * 4)
            var coarseHole = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sum: (Float, Float, Float, Float) = (0, 0, 0, 0)
                    var n: Float = 0
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let i = (2 * y + dy) * width + (2 * x + dx)
                        if hole[i] { coarseHole[y * w + x] = true; continue }
                        sum.0 += bitmap.values[4 * i]; sum.1 += bitmap.values[4 * i + 1]
                        sum.2 += bitmap.values[4 * i + 2]; sum.3 += bitmap.values[4 * i + 3]
                        n += 1
                    }
                    guard n > 0 else { continue }
                    let o = 4 * (y * w + x)
                    values[o] = sum.0 / n; values[o + 1] = sum.1 / n; values[o + 2] = sum.2 / n; values[o + 3] = sum.3 / n
                }
            }
            return Level(bitmap: Bitmap(width: w, height: h, values: values), hole: coarseHole)
        }

        /// Starting guess at the coarsest level: grow inward, each hole pixel the mean of
        /// its already-known neighbours.
        mutating func onionPeel() {
            var known = hole.map { !$0 }
            var remaining = hole.filter { $0 }.count
            while remaining > 0 {
                var next = known
                var changed = 0
                for y in 0..<height {
                    for x in 0..<width where !known[y * width + x] {
                        var sum: [Float] = [0, 0, 0, 0]
                        var n: Float = 0
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, ny >= 0, nx < width, ny < height, known[ny * width + nx] else { continue }
                            for c in 0..<4 { sum[c] += bitmap.values[4 * (ny * width + nx) + c] }
                            n += 1
                        }
                        guard n > 0 else { continue }
                        for c in 0..<4 { bitmap.values[4 * (y * width + x) + c] = sum[c] / n }
                        next[y * width + x] = true
                        changed += 1
                    }
                }
                known = next
                remaining -= changed
                if changed == 0 { break }
            }
        }

        /// Starting guess from the solved coarser level (nearest neighbour).
        mutating func initialize(from coarser: Level) {
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    let cx = min(coarser.width - 1, x / 2), cy = min(coarser.height - 1, y / 2)
                    for c in 0..<4 { bitmap.values[4 * (y * width + x) + c] = coarser.bitmap.values[4 * (cy * coarser.width + cx) + c] }
                }
            }
        }

        /// Expectation–maximization: match every patch touching the hole, then vote.
        mutating func synthesize(iterations: Int, rng: inout SplitMix) {
            let r = PatchMatch.radius
            guard width > 2 * r, height > 2 * r else { return }
            // Hole dilated by the patch radius: patches centred there overlap the hole.
            var near = [Bool](repeating: false, count: width * height)
            for y in 0..<height {
                for x in 0..<width where hole[y * width + x] {
                    for ny in max(0, y - r)...min(height - 1, y + r) {
                        for nx in max(0, x - r)...min(width - 1, x + r) { near[ny * width + nx] = true }
                    }
                }
            }
            // Sources: patch centres fully inside the image and fully known.
            var isSource = [Bool](repeating: false, count: width * height)
            var sources: [Int] = []
            for y in r..<(height - r) {
                for x in r..<(width - r) where !near[y * width + x] {
                    isSource[y * width + x] = true
                    sources.append(y * width + x)
                }
            }
            guard !sources.isEmpty else { return }
            // Targets: interior centres whose patch overlaps the hole. Every hole pixel is
            // covered, since its clamped position is within `r` of it.
            var targets: [Int] = []
            var targetIndex = [Int](repeating: -1, count: width * height)
            for y in r..<(height - r) {
                for x in r..<(width - r) where near[y * width + x] {
                    targetIndex[y * width + x] = targets.count
                    targets.append(y * width + x)
                }
            }
            guard !targets.isEmpty else { return }

            var match = targets.map { _ in sources[rng.next(below: sources.count)] }
            var cost = [Float](repeating: .infinity, count: targets.count)
            let w = width
            for _ in 0..<iterations {
                bitmap.values.withUnsafeBufferPointer { px in
                    func distance(_ t: Int, _ s: Int, limit: Float) -> Float {
                        var d: Float = 0
                        for dy in -r...r {
                            var a = 4 * (t + dy * w - r), b = 4 * (s + dy * w - r)
                            for _ in 0..<(4 * (2 * r + 1)) {
                                let e = px[a] - px[b]
                                d += e * e
                                a += 1; b += 1
                            }
                            if d >= limit { return d }
                        }
                        return d
                    }
                    for i in targets.indices { cost[i] = distance(targets[i], match[i], limit: .infinity) }
                    for pass in 0..<2 {
                        let step = pass == 0 ? 1 : -1
                        let order = pass == 0 ? Array(targets.indices) : Array(targets.indices.reversed())
                        for i in order {
                            let t = targets[i]
                            func consider(_ candidate: Int) {
                                guard candidate >= 0, candidate < isSource.count, isSource[candidate], candidate != match[i] else { return }
                                let d = distance(t, candidate, limit: cost[i])
                                if d < cost[i] { cost[i] = d; match[i] = candidate }
                            }
                            // Propagation: a neighbour's match, shifted back by one.
                            for neighbour in [t - step, t - step * w] {
                                let j = targetIndex[neighbour]
                                if j >= 0 { consider(match[j] + (t - neighbour)) }
                            }
                            // Random search in shrinking windows around the current match.
                            var span = max(width, height)
                            while span >= 1 {
                                let sx = match[i] % w + rng.next(below: 2 * span + 1) - span
                                let sy = match[i] / w + rng.next(below: 2 * span + 1) - span
                                if sx >= 0, sx < w, sy >= 0, sy < height { consider(sy * w + sx) }
                                span /= 2
                            }
                        }
                    }
                }
                vote(targets: targets, match: match, cost: cost)
            }
        }

        /// Each hole pixel: the vote of every patch covering it, weighted by how well
        /// that patch matched (robust to the median cost).
        private mutating func vote(targets: [Int], match: [Int], cost: [Float]) {
            let r = PatchMatch.radius, w = width
            let median = cost.sorted()[cost.count / 2]
            let scale = 1 / max(1e-4, median)
            var sums = [Float](repeating: 0, count: bitmap.values.count)
            var weights = [Float](repeating: 0, count: width * height)
            for (i, t) in targets.enumerated() {
                let weight = exp(-cost[i] * scale)
                for dy in -r...r {
                    for dx in -r...r {
                        let p = t + dy * w + dx
                        guard hole[p] else { continue }
                        let q = match[i] + dy * w + dx
                        for c in 0..<4 { sums[4 * p + c] += weight * bitmap.values[4 * q + c] }
                        weights[p] += weight
                    }
                }
            }
            for p in 0..<(width * height) where hole[p] && weights[p] > 0 {
                for c in 0..<4 { bitmap.values[4 * p + c] = sums[4 * p + c] / weights[p] }
            }
        }
    }

    /// A small seeded generator, so the same hole always fills the same way.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next(below n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(max(1, n)))
        }
    }
}
