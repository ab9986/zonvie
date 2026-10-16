// SurfaceIdleTerms must decide exactly what the two hand-written chains it
// replaced decided. Both originals are transcribed below, and every assignment
// of their terms is enumerated — 512 for the main surface, 1024 for an
// external one. Nothing here samples: if the shared predicate and an original
// disagree anywhere in the space, this fails and names the assignment.
//
// The originals are copies on purpose. They are the specification; if a future
// change to `skipsFrame` is intended, it has to be made twice, here as well,
// and that second edit is where someone notices the surface it would break.

import Foundation

@main
private enum SurfaceDrawGateTests {
    private static var failures = 0
    private static var skipSeen = 0
    private static var drawSeen = 0

    /// A skip/draw decision of the idle gate. Only these feed the vacuity
    /// guard in main(): other checks' true/false says nothing about the gate.
    private static func checkGate(_ actual: Bool, _ expected: Bool, _ what: @autoclosure () -> String) {
        if actual { skipSeen += 1 } else { drawSeen += 1 }
        check(actual, expected, what())
    }

    private static func check(_ actual: Bool, _ expected: Bool, _ what: @autoclosure () -> String) {
        if actual != expected {
            failures += 1
            if failures <= 10 {
                print("FAIL \(what()): shared=\(actual) original=\(expected)")
            }
        }
    }

    /// Bit `i` of `mask`.
    private static func bit(_ mask: Int, _ i: Int) -> Bool { (mask >> i) & 1 == 1 }

    /// GridSurfaceRenderer.draw:
    ///
    ///     let idleGateSkips = hasPresentedOnceSnapshot
    ///         && !hasNewCommit && dirtyRectPxOpt == nil && dirtyRows.isEmpty
    ///         && !anyLayerWork && !smoothScrolling && !blinkStateChanged
    ///         && !drawableSizeChanged && !anyCustomShaderNeedsAnimation
    private static func verifyMainSurface() {
        for mask in 0..<(1 << 9) {
            let presented = bit(mask, 0)
            let newCommit = bit(mask, 1)
            let rect = bit(mask, 2)
            let dirty = bit(mask, 3)
            let layerWork = bit(mask, 4)
            let smooth = bit(mask, 5)
            let blink = bit(mask, 6)
            let sizeChg = bit(mask, 7)
            let anim = bit(mask, 8)

            let original = presented
                && !newCommit && !rect && !dirty
                && !layerWork && !smooth && !blink
                && !sizeChg && !anim

            let shared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                hasNewCommit: newCommit,
                hasDirtyRows: dirty,
                hasDirtyRect: rect,
                hasLayerWork: layerWork,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg,
                shaderAnimates: anim
            ).skipsFrame

            checkGate(shared, original, "main mask=\(mask)")
        }
    }

    /// ExternalGridView.draw:
    ///
    ///     let idleGateSkips = rowMode && hasPresentedOnce && !blinkStateChanged
    ///         && !hasDirtyContent && !hasPendingScroll && !drawableSizeChanged
    ///         && !scrollOffsetChanged && !hasNewCommit && !smoothScrolling
    ///         && !shaderAnimates
    private static func verifyExternalSurface() {
        for mask in 0..<(1 << 9) {
            let rowMode = bit(mask, 0)
            let presented = bit(mask, 1)
            let blink = bit(mask, 2)
            let dirty = bit(mask, 3)
            let pendingScroll = bit(mask, 4)
            let sizeChg = bit(mask, 5)
            let scrollOff = bit(mask, 6)
            let newCommit = bit(mask, 7)
            let smooth = bit(mask, 8)

            let original = rowMode && presented && !blink
                && !dirty && !pendingScroll && !sizeChg
                && !scrollOff && !newCommit && !smooth

            let shared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                rowModeSatisfied: rowMode,
                hasNewCommit: newCommit,
                hasDirtyRows: dirty,
                hasStagedScroll: pendingScroll,
                scrollOffsetChanged: scrollOff,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg
            ).skipsFrame

            checkGate(shared, original, "external mask=\(mask)")
        }
    }

    /// The blink-toggle-with-no-cursor skip. GridSurfaceRenderer.draw had:
    ///
    ///     rowMode && blinkStateChanged && !hasNewCommit && dirtyRows.isEmpty
    ///         && !anyLayerWork && dirtyRectPxOpt == nil && !smoothScrolling
    ///         && !drawableSizeChanged && hasPresentedOnce
    ///         && currentCursorCount == 0 && !anyCustomShaderNeedsAnimation
    ///
    /// and ExternalGridView.draw:
    ///
    ///     blinkStateChanged && !layoutDamage && layerSnapshot.isEmpty
    ///         && !hasDirtyContent && !hasPendingScroll && !drawableSizeChanged
    ///         && !scrollOffsetChanged && !smoothScrolling && hasPresentedOnce
    ///         && !hasNewCommit && vertexCount == 0
    ///         && !shaderAnimates
    ///
    /// The shared predicate is main's exactly. For the external surface it
    /// also requires row mode, and no longer refuses merely because the
    /// surface hosts a layer: hosted work arrives as a commit or dirty rows,
    /// which it refuses on already. Both now draw a frame whose shader cursor
    /// moved; the external one used to drop that move.
    private static func verifyBlinkOnlySkip() {
        for mask in 0..<(1 << 11) {
            let presented = bit(mask, 0)
            let blink = bit(mask, 1)
            let newCommit = bit(mask, 2)
            let dirty = bit(mask, 3)
            let layerWork = bit(mask, 4)
            let rect = bit(mask, 5)
            let smooth = bit(mask, 6)
            let sizeChg = bit(mask, 7)
            let anim = bit(mask, 8)
            let noCursor = bit(mask, 9)
            let shaderCur = bit(mask, 10)
            let mainOriginal = blink && !newCommit && !dirty && !layerWork && !rect
                && !smooth && !sizeChg && presented && noCursor && !anim
            let mainShared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                hasNewCommit: newCommit,
                hasDirtyRows: dirty,
                hasDirtyRect: rect,
                hasLayerWork: layerWork,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg,
                shaderAnimates: anim,
                shaderCursorMoved: shaderCur
            ).skipsBlinkWithNoCursor(cursorVertexCount: noCursor ? 0 : 1)
            checkGate(mainShared, mainOriginal && !shaderCur, "main blink mask=\(mask)")
        }
        for mask in 0..<(1 << 12) {
            let rowMode = bit(mask, 0)
            let presented = bit(mask, 1)
            let blink = bit(mask, 2)
            let dirty = bit(mask, 3)
            let pendingScroll = bit(mask, 4)
            let sizeChg = bit(mask, 5)
            let scrollOff = bit(mask, 6)
            let newCommit = bit(mask, 7)
            let smooth = bit(mask, 8)
            let rect = bit(mask, 9)
            let noCursor = bit(mask, 10)
            let anim = bit(mask, 11)
            let externalOriginal = blink && !rect && !dirty && !pendingScroll
                && !sizeChg && !scrollOff && !smooth && presented
                && !newCommit && noCursor
                && !anim
            let externalShared = SurfaceIdleTerms(
                hasPresentedOnce: presented,
                rowModeSatisfied: rowMode,
                hasNewCommit: newCommit,
                hasDirtyRows: dirty,
                hasDirtyRect: rect,
                hasStagedScroll: pendingScroll,
                scrollOffsetChanged: scrollOff,
                isSmoothScrolling: smooth,
                blinkStateChanged: blink,
                drawableSizeChanged: sizeChg,
                shaderAnimates: anim
            ).skipsBlinkWithNoCursor(cursorVertexCount: noCursor ? 0 : 1)
            checkGate(externalShared, externalOriginal && rowMode, "external blink mask=\(mask)")
        }
    }

    /// The idle counter both surfaces now share. What each surface used to do
    /// inline, restated: a recent commit or a held clock resets the run; every
    /// other empty frame extends it; the loop stops one frame PAST the
    /// threshold, not on it.
    private static func verifyIdleCounter() {
        var c = DrawLoopIdleCounter(threshold: 3)

        // Below and at the threshold the loop keeps running.
        for i in 1...3 {
            if c.noteIdle(hadRecentCommit: false) {
                failures += 1
                print("FAIL: idle counter stopped the loop at frame \(i) of 3")
            }
        }
        // One past it, it stops.
        if !c.noteIdle(hadRecentCommit: false) {
            failures += 1
            print("FAIL: idle counter did not stop the loop past its threshold")
        }

        // A recent commit resets the run rather than extending it: the empty
        // frame is a timing race, and counting it deactivates mid-scroll.
        var r = DrawLoopIdleCounter(threshold: 3)
        _ = r.noteIdle(hadRecentCommit: false)
        _ = r.noteIdle(hadRecentCommit: false)
        _ = r.noteIdle(hadRecentCommit: true)
        if r.idleFrames != 0 {
            failures += 1
            print("FAIL: a recent commit left the run at \(r.idleFrames)")
        }
        for _ in 1...3 {
            if r.noteIdle(hadRecentCommit: false) {
                failures += 1
                print("FAIL: the run was not actually reset by the recent commit")
            }
        }

        // A held clock does the same, and outranks the absence of a commit.
        var h = DrawLoopIdleCounter(threshold: 1)
        _ = h.noteIdle(hadRecentCommit: false)
        if h.noteIdle(hadRecentCommit: false, heldActive: true) {
            failures += 1
            print("FAIL: the loop stopped while something held it active")
        }
        if h.idleFrames != 0 {
            failures += 1
            print("FAIL: a held clock left the run at \(h.idleFrames)")
        }

        // A frame that rendered clears the run too.
        var a = DrawLoopIdleCounter(threshold: 1)
        _ = a.noteIdle(hadRecentCommit: false)
        a.noteActive()
        if a.idleFrames != 0 {
            failures += 1
            print("FAIL: a rendered frame left the run at \(a.idleFrames)")
        }
    }

    /// The scroll-offset latch both surfaces now share, against the two pairs
    /// of Bools it replaced.
    ///
    ///     main     smoothScrolling = hasActiveScrollOffset
    ///                                  || lastDrawnHadActiveScrollOffset
    ///     external smoothScrolling = scrollOffsetActive
    ///                                  || lastPresentedScrollOffsetActive
    ///
    /// The same expression under two sets of names, so one enumeration covers
    /// both: every assignment of (active now, active on the previous frame),
    /// and every latch-then-restore round trip — what a frame that is encoded
    /// and then abandoned does.
    private static func verifyScrollOffsetLatch() {
        for activeNow in [false, true] {
            for previous in [false, true] {
                var latch = SurfaceScrollOffsetLatch()
                latch.setActive(previous)
                latch.latch(previous)
                latch.setActive(activeNow)

                check(latch.isSmoothScrolling, activeNow || previous,
                      "latch smooth active=\(activeNow) previous=\(previous)")

                // A latch hands back what it displaced, and restoring it puts
                // the pair back exactly: an abandoned frame must leave no
                // trace, or the next one reads the wrong previous frame.
                var abandoned = latch
                let displaced = abandoned.latch(activeNow)
                if displaced != previous {
                    failures += 1
                    print("FAIL: latch returned \(displaced), expected \(previous)")
                }
                abandoned.restore(previousFrameWasActive: displaced)
                if abandoned.previousFrameWasActive != latch.previousFrameWasActive
                    || abandoned.isActive != latch.isActive
                {
                    failures += 1
                    print("FAIL: restore did not undo the latch")
                }

                // A latch that is kept moves the pair forward instead.
                var kept = latch
                kept.latch(activeNow)
                if kept.previousFrameWasActive != activeNow {
                    failures += 1
                    print("FAIL: a kept latch did not record this frame")
                }
            }
        }
    }

    /// The cursor owner both surfaces now share, against the bracket protocol
    /// each of them wrote out.
    ///
    ///     stage      pendingCursorGridId = id
    ///     commit     committedCursorGridId = pendingCursorGridId
    ///     abandon    pendingCursorGridId = committedCursorGridId
    ///     guard      count != 0 || pendingCursorGridId == id
    ///
    /// The guard is what this is really protecting: a cursor CLEAR arrives for
    /// whichever grid lost the cursor, so accepting one from a grid that does
    /// not own it erases a cursor still on screen. Every ordering of stage,
    /// commit and abandon over a set of owners is enumerated, including the two
    /// roots the surfaces start from — 1 for main, nil for external.
    private static func verifyCursorOwner() {
        let owners: [Int64?] = [nil, 1, 4, 7]
        for initial in owners {
            for first in owners {
                for second in owners {
                    // Stage, then commit: both halves become the staged owner
                    // and only that owner may clear.
                    var committing = SurfaceCursorOwner(initial: initial)
                    committing.stage(first)
                    committing.commit()
                    committing.stage(second)
                    for probe in owners {
                        guard let probe else { continue }
                        check(committing.owns(probe), second == probe,
                              "owns after stage init=\(String(describing: initial))"
                                + " staged=\(String(describing: second)) probe=\(probe)")
                    }

                    // Stage, then abandon: the staged owner goes back to what
                    // is on screen, which is the committed one.
                    var abandoning = SurfaceCursorOwner(initial: initial)
                    abandoning.stage(first)
                    abandoning.commit()
                    abandoning.stage(second)
                    abandoning.restoreStagedFromCommitted()
                    if abandoning.staged != first {
                        failures += 1
                        print("FAIL: an abandoned bracket left"
                            + " \(String(describing: abandoning.staged)) staged,"
                            + " expected \(String(describing: first))")
                    }
                    if abandoning.committed != first {
                        failures += 1
                        print("FAIL: abandoning moved what is on screen")
                    }
                }
            }
        }

        // Admission: an empty clear from a non-owner is dropped and leaves the
        // owner alone; the owner's clear and any non-empty cursor stage.
        var admitting = SurfaceCursorOwner(initial: 1)
        if admitting.admit(4, count: 0) || admitting.staged != 1 {
            failures += 1
            print("FAIL: an empty clear from a non-owner was admitted")
        }
        if !admitting.admit(4, count: 6) || admitting.staged != 4 || admitting.stagedRootRow != -1 {
            failures += 1
            print("FAIL: a layer cursor was not staged")
        }
        if !admitting.admit(4, count: 0) || admitting.staged != 4 {
            failures += 1
            print("FAIL: the owner's own clear was refused")
        }
        if !admitting.admit(1, count: 6, rootRow: 3) || admitting.stagedRootRow != 3 {
            failures += 1
            print("FAIL: a root cursor lost its row")
        }

        // A nil start owns nothing at all — the case that drops a clear
        // arriving before any cursor has been staged.
        let fresh = SurfaceCursorOwner(initial: nil)
        for probe in Int64(0)...Int64(8) where fresh.owns(probe) {
            failures += 1
            print("FAIL: a nil owner claimed grid \(probe)")
        }
        let rooted = SurfaceCursorOwner(initial: 1)
        if !rooted.owns(1) || rooted.owns(2) {
            failures += 1
            print("FAIL: a rooted owner does not own exactly its root")
        }

        // The root row travels with the owner through the same bracket: a
        // root cursor names its row, a layer cursor names none (-1), and an
        // abandoned bracket puts the row back with the owner. Both surfaces
        // kept the row beside the owner and one of them forgot the -1.
        var rowed = SurfaceCursorOwner(initial: 1)
        rowed.stage(1, rootRow: 7)
        if rowed.committedRootRow != -1 {
            failures += 1
            print("FAIL: a staged row was visible before commit")
        }
        rowed.commit()
        if rowed.committedRootRow != 7 {
            failures += 1
            print("FAIL: commit did not publish the staged row")
        }
        rowed.stage(4)
        if rowed.stagedRootRow != -1 {
            failures += 1
            print("FAIL: a layer cursor kept the root row \(rowed.stagedRootRow)")
        }
        rowed.restoreStagedFromCommitted()
        if rowed.stagedRootRow != 7 || rowed.staged != 1 {
            failures += 1
            print("FAIL: abandoning did not put the row back with the owner")
        }
        rowed.stage(4)
        rowed.commit()
        if rowed.committedRootRow != -1 {
            failures += 1
            print("FAIL: a committed layer cursor still names a root row")
        }
    }

    /// The committed extent both surfaces now share, against the two fallback
    /// rules it replaced.
    ///
    ///     main      if committedW > 0 && committedH > 0 { use both }
    ///               else { use the live drawable for both }
    ///     external  rows = committedRows > 0 ? committedRows : liveRows
    ///               cols = committedCols > 0 ? committedCols : liveCols
    ///
    /// The two agree on every pair a surface can actually hold, because the
    /// pair is published together and is therefore all-or-nothing. This
    /// enumerates the mixed pairs too — the ones the invariant forbids — and
    /// asserts the shared rule takes the all-or-nothing answer there, which is
    /// the safe one: a committed width beside a live height describes no frame
    /// that ever existed.
    private static func verifyCommittedExtent() {
        let values: [UInt32] = [0, 1, 40, 80]
        let liveW: UInt32 = 7
        let liveH: UInt32 = 9
        var mixedSeen = 0
        for w in values {
            for h in values {
                var extent = SurfaceCommittedExtent()
                extent.commit(width: w, height: h)
                let got = extent.resolved(liveWidth: liveW, liveHeight: liveH)

                let mainRule: (UInt32, UInt32) = (w > 0 && h > 0) ? (w, h) : (liveW, liveH)
                let externalRule: (UInt32, UInt32) =
                    (w > 0 ? w : liveW, h > 0 ? h : liveH)

                check(got.width == mainRule.0 && got.height == mainRule.1, true,
                      "extent vs main rule w=\(w) h=\(h)")

                if (w == 0) == (h == 0) {
                    // The pairs a surface can hold: the two rules agree.
                    check(got.width == externalRule.0 && got.height == externalRule.1, true,
                          "extent vs external rule w=\(w) h=\(h)")
                } else {
                    mixedSeen += 1
                    // The invariant forbids these, and the two rules disagree
                    // on them: the shared one takes all-or-nothing.
                    if got.width != liveW || got.height != liveH {
                        failures += 1
                        print("FAIL: a mixed extent w=\(w) h=\(h) did not fall back whole")
                    }
                }
            }
        }
        if mixedSeen == 0 {
            failures += 1
            print("FAIL: the enumeration produced no mixed pair, so it proved nothing")
        }
    }

    /// A precise gesture is handed to discrete scrolling only once one event
    /// asks for more than the lookahead can request in one input: the events
    /// it may send per input, each worth 'mousescroll' rows. Below that the
    /// finger keeps its sub-row compensation. The old rule cut over at one
    /// row of travel, which an ordinary flick crosses on most events.
    private static func verifyFastScrollThreshold() {
        func expect(_ actual: Double, _ expected: Double, _ what: String) {
            if abs(actual - expected) > 1e-9 {
                failures += 1
                print("FAIL fast-scroll threshold \(what): got \(actual) expected \(expected)")
            }
        }
        // 40px rows on a 2x display, three rows per wheel event, three
        // events per input: 9 rows = 360px = 180pt.
        expect(fastScrollThresholdPt(rowHeightPx: 40, rowsPerWheelEvent: 3, maxEventsPerInput: 3, scale: 2), 180, "ver=3")
        expect(fastScrollThresholdPt(rowHeightPx: 40, rowsPerWheelEvent: 1, maxEventsPerInput: 3, scale: 2), 60, "ver=1")
        // 'mousescroll' ver:0 disables mouse scrolling; the caller never
        // reaches this with it, but the function must not answer zero, which
        // would hand every gesture to discrete mode.
        expect(fastScrollThresholdPt(rowHeightPx: 40, rowsPerWheelEvent: 0, maxEventsPerInput: 3, scale: 2), 20, "ver=0 falls back to one row")
    }

    /// SurfaceScrollBlitGate against both hand-written originals, over every
    /// assignment of its seven terms.
    ///
    /// GridSurfaceRenderer.draw (refusal ladder, first match wins):
    ///     !presented -> "presented"; smooth -> "smooth";
    ///     sizeChanged || !newCommit -> "resize"; glow -> "glow";
    ///     blur && !twoPass -> "blur"
    /// ExternalGridView.draw (mayGpuScrollCopy's surface-wide terms):
    ///     newCommit && presented && !smooth && !sizeChanged && !glow
    ///         && (!blur || twoPass)
    private static func verifyScrollBlitGate() {
        var allowed = 0
        for mask in 0..<(1 << 7) {
            let presented = bit(mask, 0)
            let smooth = bit(mask, 1)
            let sizeChg = bit(mask, 2)
            let newCommit = bit(mask, 3)
            let glow = bit(mask, 4)
            let blur = bit(mask, 5)
            let twoPass = bit(mask, 6)
            let mainOriginal: String?
            if !presented {
                mainOriginal = "presented"
            } else if smooth {
                mainOriginal = "smooth"
            } else if sizeChg || !newCommit {
                mainOriginal = "resize"
            } else if glow {
                mainOriginal = "glow"
            } else if blur && !twoPass {
                mainOriginal = "blur"
            } else {
                mainOriginal = nil
            }
            let externalOriginal = newCommit && presented && !smooth && !sizeChg && !glow
                && (!blur || twoPass)
            let refusal = SurfaceScrollBlitGate(
                hasPresentedOnce: presented,
                smoothScrolling: smooth,
                drawableSizeChanged: sizeChg,
                hasNewCommit: newCommit,
                glowEnabled: glow,
                blurEnabled: blur,
                useTwoPass: twoPass
            ).refusal
            if refusal != mainOriginal || (refusal == nil) != externalOriginal {
                failures += 1
                if failures <= 10 {
                    print("FAIL scroll blit gate mask=\(mask): shared=\(String(describing: refusal))"
                        + " main=\(String(describing: mainOriginal)) external=\(externalOriginal)")
                }
            }
            if refusal == nil { allowed += 1 }
        }
        // Only presented, !smooth, !sizeChg, newCommit, !glow, and the three
        // blur/twoPass pairs other than (blur, !twoPass) allow a blit.
        if allowed != 3 {
            failures += 1
            print("FAIL scroll blit gate: \(allowed) assignments allow a blit, expected 3")
        }
    }

    /// settleSurfaceAgainstOwnCommit's postcondition: it returns with the
    /// lock held, and true only when no commit landed after the last service
    /// (the frame's rows and scroll state come from one commit). A commit
    /// storm that outlasts maxAttempts must answer false, not true.
    private static func verifySettleAgainstOwnCommit() {
        // `commitsDuringService[i]` commits land while service call i runs.
        func run(_ commitsDuringService: [Int], maxAttempts: Int) -> (settled: Bool, services: Int, lockHeld: Bool) {
            let lock = NSLock()
            var revision: UInt64 = 0
            var services = 0
            let settled = settleSurfaceAgainstOwnCommit(
                lock: lock,
                commitRevision: { revision },
                service: {
                    if services < commitsDuringService.count {
                        revision += UInt64(commitsDuringService[services])
                    }
                    services += 1
                },
                maxAttempts: maxAttempts
            )
            let lockHeld = !lock.try()
            // Either the settle's hold or the try's; release it.
            lock.unlock()
            return (settled, services, lockHeld)
        }
        func expect(_ got: (settled: Bool, services: Int, lockHeld: Bool),
                    settled: Bool, services: Int, _ what: String) {
            if got.settled != settled || got.services != services || !got.lockHeld {
                failures += 1
                print("FAIL settle \(what): settled=\(got.settled) services=\(got.services)"
                    + " lockHeld=\(got.lockHeld), expected settled=\(settled) services=\(services) lockHeld=true")
            }
        }
        expect(run([], maxAttempts: 3), settled: true, services: 1, "quiet")
        expect(run([1], maxAttempts: 3), settled: true, services: 2, "one commit, then quiet")
        expect(run([1, 1], maxAttempts: 3), settled: true, services: 3, "settles on the last attempt")
        expect(run([1, 1, 1], maxAttempts: 3), settled: false, services: 3, "storm outlasts the bound")
        expect(run([1], maxAttempts: 1), settled: false, services: 1, "one attempt, raced")
    }

    static func main() {
        verifyScrollBlitGate()
        verifyMainSurface()
        verifyCommittedExtent()
        verifyCursorOwner()
        verifyScrollOffsetLatch()
        verifyExternalSurface()
        verifyBlinkOnlySkip()
        verifyIdleCounter()
        verifyFastScrollThreshold()
        verifySettleAgainstOwnCommit()

        // A term a surface does not have must never block its skip. The main
        // surface has no staged scroll, no scroll-offset latch and no cursor
        // flag; an external one has no dirty rect and no per-layer work.
        // Leaving those at their defaults has to read as "nothing pending", or
        // a surface would pay for a concept it does not implement.
        if !SurfaceIdleTerms(hasPresentedOnce: true).skipsFrame {
            failures += 1
            print("FAIL: a surface with nothing but a presented frame does not skip")
        }

        // Both outcomes must actually occur, or the loops assert nothing.
        if skipSeen == 0 || drawSeen == 0 {
            failures += 1
            print("FAIL: the enumeration produced skip=\(skipSeen) draw=\(drawSeen)")
        }

        if failures != 0 {
            print("surface draw gate: \(failures) failure(s)")
            exit(1)
        }
        print("surface draw gate: \(skipSeen + drawSeen) idle assignments agree"
            + " (skip=\(skipSeen) draw=\(drawSeen))")
    }
}
