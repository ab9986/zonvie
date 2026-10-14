import Foundation

/// The bands a partial frame repaints (`src/core/damage_bands.zig`, which the
/// Windows driver calls as Zig; this is the same answer through the C ABI),
/// and the rows of each layer it draws there. The arrays are reused, so a
/// frame allocates nothing once they have grown.
final class SurfaceDamageBands {
    private(set) var bands: [zonvie_damage_band] = []
    private var spans: [zonvie_damage_band] = []
    /// Each layer's placement as the last frame drew it, in paint order.
    private var drawnPlacements: [(gridId: Int64, topPx: Int, bottomPx: Int, leftPx: Int, cols: Int)] = []

    func reset() {
        spans.removeAll(keepingCapacity: true)
        bands.removeAll(keepingCapacity: true)
    }

    var hasSpans: Bool { !spans.isEmpty }

    /// Damage what moving, resizing, restacking, adding or removing a layer
    /// exposed: its old extent and its new one. The core no longer dirties
    /// the root rows under a layer for that; the pixels are this surface's.
    /// Records `frames` as drawn, so call it once per frame.
    func addPlacementChanges(_ frames: [SurfaceLayerFrame], rowHeightPx: Int) {
        func placement(_ layer: SurfaceLayer) -> (gridId: Int64, topPx: Int, bottomPx: Int, leftPx: Int, cols: Int) {
            let top = Int(layer.originPx.y.rounded(.down))
            return (layer.gridId, top, top + layer.rows * rowHeightPx, Int(layer.originPx.x.rounded(.down)), layer.cols)
        }
        func same(_ a: (gridId: Int64, topPx: Int, bottomPx: Int, leftPx: Int, cols: Int),
                  _ b: (gridId: Int64, topPx: Int, bottomPx: Int, leftPx: Int, cols: Int)) -> Bool {
            a.gridId == b.gridId && a.topPx == b.topPx && a.bottomPx == b.bottomPx && a.leftPx == b.leftPx && a.cols == b.cols
        }
        // Paint order matters too: a restack changes which layer wins the
        // pixels they share, so a layer at a different index is damaged.
        for (i, old) in drawnPlacements.enumerated() {
            if i < frames.count, same(old, placement(frames[i].layer)) { continue }
            addSpan(topPx: old.topPx, bottomPx: old.bottomPx)
        }
        for (i, frame) in frames.enumerated() {
            let now = placement(frame.layer)
            if i < drawnPlacements.count, same(drawnPlacements[i], now) { continue }
            addSpan(topPx: now.topPx, bottomPx: now.bottomPx)
        }
        drawnPlacements.removeAll(keepingCapacity: true)
        for frame in frames { drawnPlacements.append(placement(frame.layer)) }
    }

    func addSpan(topPx: Int, bottomPx: Int) {
        spans.append(zonvie_damage_band(top_px: Int32(clamping: topPx), bottom_px: Int32(clamping: bottomPx)))
    }

    func addRows<S: Sequence>(_ rows: S, originYPx: Int, rowHeightPx: Int) where S.Element == Int {
        for row in rows where row >= 0 {
            let top = originYPx + row * rowHeightPx
            addSpan(topPx: top, bottomPx: top + rowHeightPx)
        }
    }

    /// Fold the spans added since reset() into bands.
    func resolve(rowHeightPx: Int, surfaceHeightPx: Int) {
        let capacity = max(1, spans.count)
        bands.removeAll(keepingCapacity: true)
        bands.append(contentsOf: repeatElement(zonvie_damage_band(), count: capacity))
        let count = spans.withUnsafeBufferPointer { src in
            bands.withUnsafeMutableBufferPointer { dst in
                zonvie_core_damage_bands(
                    src.baseAddress, src.count,
                    Int32(clamping: rowHeightPx), Int32(clamping: surfaceHeightPx),
                    dst.baseAddress, dst.count
                )
            }
        }
        bands.removeLast(capacity - count)
    }

    /// The rows of a layer at `originYPx` the bands reach, in order and each
    /// once (the bands are three rows apart), replacing `rows`.
    func layerRows(originYPx: Int, rowCount: Int, rowHeightPx: Int, into rows: inout [Int]) {
        rows.removeAll(keepingCapacity: true)
        for band in bands {
            guard let r = Self.rows(in: band, originYPx: originYPx, rowCount: rowCount, rowHeightPx: rowHeightPx) else { continue }
            rows.append(contentsOf: r)
        }
    }

    /// The rows of a layer at `originYPx` one band repaints.
    static func rows(in band: zonvie_damage_band, originYPx: Int, rowCount: Int, rowHeightPx: Int) -> ClosedRange<Int>? {
        var first: UInt32 = 0
        var last: UInt32 = 0
        guard zonvie_core_damage_band_layer_rows(
            band, Int32(clamping: originYPx), UInt32(clamping: rowCount),
            Int32(clamping: rowHeightPx), &first, &last
        ) else { return nil }
        return Int(first)...Int(last)
    }

    /// The band `row` of a layer at `originYPx` is drawn in.
    func band(forRow row: Int, originYPx: Int, rowHeightPx: Int) -> zonvie_damage_band? {
        var out = zonvie_damage_band()
        let found = bands.withUnsafeBufferPointer { b in
            zonvie_core_damage_band_for_layer_row(
                b.baseAddress, b.count, Int32(clamping: originYPx), UInt32(clamping: row),
                Int32(clamping: rowHeightPx), &out
            )
        }
        return found ? out : nil
    }
}
