// SurfaceFramePlan: which passes a surface frame encodes, per input.
//
// The rules under test are the decision's own fields (zonvie_frontend.h:
// skips_surface_pass, loads_previous_contents, reuses_root_contents,
// reuses_hosted_contents, row_pass_plan) read the way each surface reads
// them, and the main surface's per-layer redraw-all reasons. Every input
// combination is enumerated against the rule written out here.

import Foundation

@_cdecl("zonvie_core_surface_frame_decision")
func stubSurfaceFrameDecision(
    _ terms: UnsafePointer<zonvie_surface_frame_terms>?,
    _ out: UnsafeMutablePointer<zonvie_surface_frame_decision>?
) {
    fatalError("not used by this test")
}

@main
private enum SurfaceFramePlanTests {
    private static var failures = 0

    private static func fail(_ message: String) {
        failures += 1
        print("FAIL \(message)")
    }

    private static let plans: [SurfaceRowPassPlan] = [
        .dirtyRowsOnly, .dirtyRowsAfterScrollBlit, .allRowsWithRetained, .allRows,
    ]

    private static func decision(
        skip: Bool, load: Bool, reuseRoot: Bool, reuseHosted: Bool, plan: SurfaceRowPassPlan
    ) -> SurfaceFrameDecision {
        SurfaceFrameDecision(
            reusesRootContents: reuseRoot,
            reusesHostedContents: reuseHosted,
            partialHostedContents: false,
            skipsSurfacePass: skip,
            canDirtyOnlyWithBlur: false,
            loadsPreviousContents: load,
            rowPassPlan: plan,
            backgroundAlpha: 1,
            terms: SurfaceFrameTerms()
        )
    }

    private static func verifySurfacePlans() {
        for bits in 0..<(1 << 5) {
            let skip = bits & 1 != 0
            let load = bits & 2 != 0
            let reuseRoot = bits & 4 != 0
            let reuseHosted = bits & 8 != 0
            let rowMode = bits & 16 != 0
            for plan in plans {
                let d = decision(skip: skip, load: load, reuseRoot: reuseRoot, reuseHosted: reuseHosted, plan: plan)
                let what = "skip=\(skip) load=\(load) reuseRoot=\(reuseRoot) reuseHosted=\(reuseHosted) rowMode=\(rowMode) plan=\(plan)"

                for layerCount in 0...3 {
                    let m = SurfaceFramePlan.main(decision: d, rowMode: rowMode, layerCount: layerCount)
                    // A skipped pass encodes nothing; the main surface's root
                    // is drawn whenever rows exist, and a layer list holding
                    // only the root has nothing over it.
                    let want = SurfaceFramePlan(
                        encodesSurfacePass: !skip,
                        loadsPreviousContents: load,
                        encodesRootRows: !skip && rowMode,
                        encodesHostedLayers: !skip && layerCount >= 2,
                        rowPassPlan: plan
                    )
                    if m != want { fail("main \(what) layers=\(layerCount): \(m), expected \(want)") }
                }

                let e = SurfaceFramePlan.external(decision: d, rowMode: rowMode)
                // Either reuse arm keeps the root's rows; only the hosted
                // arm keeps the hosted layers.
                let want = SurfaceFramePlan(
                    encodesSurfacePass: !skip,
                    loadsPreviousContents: load,
                    encodesRootRows: !skip && rowMode && !reuseRoot && !reuseHosted,
                    encodesHostedLayers: !skip && !reuseHosted,
                    rowPassPlan: plan
                )
                if e != want { fail("external \(what): \(e), expected \(want)") }
            }
        }
    }

    private static func verifyDamageBands() {
        for layerCount in 0...3 {
            for rowHeightPx in -1...2 {
                let got = SurfaceFramePlan.mainDrawsDamageBands(layerCount: layerCount, rowHeightPx: rowHeightPx)
                let want = layerCount >= 2 && rowHeightPx >= 1
                if got != want { fail("damage bands layers=\(layerCount) rowH=\(rowHeightPx): \(got)") }
            }
        }
    }

    private static func verifyLayerNeedsAllRows() {
        for bits in 0..<(1 << 7) {
            let hasState = bits & 1 != 0
            let drawAll = bits & 2 != 0
            let clear = bits & 4 != 0
            let smooth = bits & 8 != 0
            let glow = bits & 16 != 0
            let retained = bits & 32 != 0 ? 2 : 0
            let rowCountChanged = bits & 64 != 0
            let got = SurfaceFramePlan.layerNeedsAllRows(
                hasDrawState: hasState, drawAllRows: drawAll, loadActionIsClear: clear,
                smoothScrolling: smooth, glowEnabled: glow, retainedRowCount: retained,
                rowCount: 10, lastDrawnRowCount: rowCountChanged ? 9 : 10)
            // Dirty rows alone suffice only for a tracked layer on a loaded,
            // unscrolled, glow-free frame whose row count it already drew.
            let dirtyOnly = hasState && !drawAll && !clear && !smooth && !glow && retained == 0 && !rowCountChanged
            if got == dirtyOnly { fail("layerNeedsAllRows bits=\(bits): \(got)") }
        }
    }

    static func main() {
        verifySurfacePlans()
        verifyDamageBands()
        verifyLayerNeedsAllRows()
        if failures != 0 {
            print("surface frame plan: \(failures) failure(s)")
            exit(1)
        }
        print("surface frame plan: all checks passed")
    }
}
