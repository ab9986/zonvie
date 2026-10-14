import Foundation

/// Which passes one surface frame encodes, from its frame decision and the
/// facts the decision does not carry. Pure: no AppKit, Metal or lock, so the
/// pass choice of both draw drivers is testable without a GPU.
struct SurfaceFramePlan: Equatable {
    /// A render pass into the back texture is encoded at all.
    let encodesSurfacePass: Bool
    /// That pass loads the previous back texture instead of clearing it.
    let loadsPreviousContents: Bool
    /// The root grid's rows are drawn in that pass.
    let encodesRootRows: Bool
    /// The hosted layers are drawn in that pass.
    let encodesHostedLayers: Bool
    /// Which root rows the pass draws, when `encodesRootRows`.
    let rowPassPlan: SurfaceRowPassPlan

    /// The main surface. Its root is the ext_multigrid container, drawn
    /// whenever rows exist; every layer after the root (`layerCount` counts
    /// the root) is drawn over it in the same pass.
    static func main(decision: SurfaceFrameDecision, rowMode: Bool, layerCount: Int) -> SurfaceFramePlan {
        let pass = !decision.skipsSurfacePass
        return SurfaceFramePlan(
            encodesSurfacePass: pass,
            loadsPreviousContents: decision.loadsPreviousContents,
            encodesRootRows: pass && rowMode,
            encodesHostedLayers: pass && layerCount > 1,
            rowPassPlan: decision.rowPassPlan
        )
    }

    /// An external surface. A reuse arm keeps what it names: the root's rows
    /// are drawn only when neither arm is open, the hosted layers only when
    /// the hosted arm is closed.
    static func external(decision: SurfaceFrameDecision, rowMode: Bool) -> SurfaceFramePlan {
        let pass = !decision.skipsSurfacePass
        return SurfaceFramePlan(
            encodesSurfacePass: pass,
            loadsPreviousContents: decision.loadsPreviousContents,
            encodesRootRows: pass && rowMode && !decision.reusesHostedContents && !decision.reusesRootContents,
            encodesHostedLayers: pass && !decision.reusesHostedContents,
            rowPassPlan: decision.rowPassPlan
        )
    }

    /// Whether the main surface collects damage bands: only a surface with a
    /// layer over its root has anything for the root's band to erase.
    static func mainDrawsDamageBands(layerCount: Int, rowHeightPx: Int) -> Bool {
        layerCount > 1 && rowHeightPx > 0
    }

    /// Why a main-surface layer has to redraw every row instead of only the
    /// rows it owes: `.clear` erased the back texture; no draw state means
    /// nothing tracked what it owes; `drawAllRows` means it moved, resized or
    /// is new; an eased frame re-places every row through a shader offset (a
    /// layer still holding retained rows is easing); glow composites bloom
    /// from the whole texture; and a changed row count means the rows it
    /// gained were never drawn.
    static func layerNeedsAllRows(
        hasDrawState: Bool,
        drawAllRows: Bool,
        loadActionIsClear: Bool,
        smoothScrolling: Bool,
        glowEnabled: Bool,
        retainedRowCount: Int,
        rowCount: Int,
        lastDrawnRowCount: Int
    ) -> Bool {
        guard hasDrawState else { return true }
        return loadActionIsClear
            || drawAllRows
            || smoothScrolling
            || glowEnabled
            || retainedRowCount > 0
            || rowCount != lastDrawnRowCount
    }
}
