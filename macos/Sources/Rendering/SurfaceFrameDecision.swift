import Foundation

/// What a surface knows about one frame, after its scroll blit has run and
/// before its render pass is described. The decision itself is the core's
/// (`zonvie_core_surface_frame_decision`, zonvie_frontend.h), shared with the
/// Windows paint drivers; this is the Swift spelling of its terms. A surface
/// that lacks a concept leaves the term at the value that cannot change its
/// own answer.
struct SurfaceFrameTerms {
    /// Row vertices are in use, so dirty rows describe the frame.
    var rowMode = true

    /// Row mode is a precondition of skipping the pass. The main surface's
    /// whole-grid gate already returned when it had nothing to draw, so it
    /// passes true here regardless of `rowMode`; an external surface passes
    /// its `rowMode`.
    var rowModeSatisfied = true

    var hasPresentedOnce = false
    var drawableSizeChanged = false
    var isSmoothScrolling = false
    var blurEnabled = false

    /// Blur's two-pass background/glyph pipelines exist.
    var useTwoPass = false

    var glowEnabled = false

    /// ext-cmdline and friends: their viewport origin offset means partial
    /// scissor rects do not line up, so they never reuse the back texture.
    var isDecoratedSurface = false

    /// The popupmenu keeps every cell's own opaque background. Only the
    /// external surface hosting that grid passes true.
    var isPopupmenu = false

    /// This frame's back texture goes through the decorated custom-shader
    /// chain, which discards alpha.
    var shaderChainConsumesSurface = false

    /// The configured background alpha for a blurred, undecorated surface.
    var configuredBlurAlpha: Float = 1

    /// The committed rows were generated with the font metrics in force now.
    var fontIsCurrent = true

    /// The layout moved under this surface, or its background colour changed.
    var hasLayoutDamage = false

    /// A damaged pixel rectangle no row expresses. Main only.
    var hasDirtyRect = false

    /// The root pass has rows to draw this frame.
    var hasDirtyRows = false

    /// A layer the main surface hosts owes work; drawn from its own pass.
    var hasLayerWork = false

    /// The commit this frame draws changed no back-texture pixel. The main
    /// surface passes `!hasNewCommit || cursorOnlyCommit`; an external surface
    /// passes true because its pixel-changing commits raise other terms.
    var commitChangesNoPixels = true

    /// A row scroll staged but not yet consumed. External only.
    var hasStagedScroll = false

    /// The sub-row scroll offset differs from the last presented frame's.
    var scrollOffsetChanged = false

    /// This surface hosts layers whose contents are NOT in its dirty-row set.
    var hostsLayersOutsideDirtySet = false

    /// A GPU scroll blit shifted pixels in the back texture this frame.
    var scrollBlitKeptBackTexture = false

    /// The blit shifted the root pass's OWN rows. The main surface's root never
    /// scrolls and passes false; an external surface passes its blit flag.
    var rootScrollBlitVacatedBand = false

    fileprivate var cTerms: zonvie_surface_frame_terms {
        var t = zonvie_surface_frame_terms()
        t.row_mode = rowMode
        t.row_mode_satisfied = rowModeSatisfied
        t.has_presented_once = hasPresentedOnce
        t.drawable_size_changed = drawableSizeChanged
        t.is_smooth_scrolling = isSmoothScrolling
        t.blur_enabled = blurEnabled
        t.use_two_pass = useTwoPass
        t.glow_enabled = glowEnabled
        t.is_decorated_surface = isDecoratedSurface
        t.is_popupmenu = isPopupmenu
        t.shader_chain_consumes_surface = shaderChainConsumesSurface
        t.font_is_current = fontIsCurrent
        t.has_layout_damage = hasLayoutDamage
        t.has_dirty_rect = hasDirtyRect
        t.has_dirty_rows = hasDirtyRows
        t.has_layer_work = hasLayerWork
        t.commit_changes_no_pixels = commitChangesNoPixels
        t.has_staged_scroll = hasStagedScroll
        t.scroll_offset_changed = scrollOffsetChanged
        t.hosts_layers_outside_dirty_set = hostsLayersOutsideDirtySet
        t.scroll_blit_kept_back_texture = scrollBlitKeptBackTexture
        t.root_scroll_blit_vacated_band = rootScrollBlitVacatedBand
        t.refuses_reuse = false
        t.configured_blur_alpha = configuredBlurAlpha
        return t
    }
}

/// The per-frame decisions both draw drivers consume, as the core decided them.
struct SurfaceFrameDecision {
    let reusesRootContents: Bool
    let reusesHostedContents: Bool
    let partialHostedContents: Bool
    let skipsSurfacePass: Bool
    let canDirtyOnlyWithBlur: Bool
    /// The render pass loads the back texture instead of clearing it.
    let loadsPreviousContents: Bool
    let rowPassPlan: SurfaceRowPassPlan
    /// The alpha the row shader multiplies background colours by.
    let backgroundAlpha: Float
    /// What the decision was made from, for the trace line.
    let terms: SurfaceFrameTerms

    static func make(terms: SurfaceFrameTerms) -> SurfaceFrameDecision {
        var t = terms.cTerms
        var d = zonvie_surface_frame_decision()
        zonvie_core_surface_frame_decision(&t, &d)
        let plan: SurfaceRowPassPlan
        switch UInt32(d.row_pass_plan) {
        case UInt32(ZONVIE_ROW_PASS_DIRTY_ROWS_ONLY): plan = .dirtyRowsOnly
        case UInt32(ZONVIE_ROW_PASS_DIRTY_ROWS_AFTER_SCROLL_BLIT): plan = .dirtyRowsAfterScrollBlit
        case UInt32(ZONVIE_ROW_PASS_ALL_ROWS_WITH_RETAINED): plan = .allRowsWithRetained
        case UInt32(ZONVIE_ROW_PASS_ALL_ROWS): plan = .allRows
        default:
            // ABI drift. Redrawing every row is correct for any frame.
            assertionFailure("unknown row_pass_plan \(d.row_pass_plan)")
            plan = .allRows
        }
        return SurfaceFrameDecision(
            reusesRootContents: d.reuses_root_contents,
            reusesHostedContents: d.reuses_hosted_contents,
            partialHostedContents: d.partial_hosted_contents,
            skipsSurfacePass: d.skips_surface_pass,
            canDirtyOnlyWithBlur: d.can_dirty_only_with_blur,
            loadsPreviousContents: d.loads_previous_contents,
            rowPassPlan: plan,
            backgroundAlpha: d.background_alpha,
            terms: terms
        )
    }

    /// The background-alpha rule alone, for a surface that needs it before its
    /// first frame decision (the external view's init-time log).
    static func backgroundAlpha(
        blurEnabled: Bool,
        isDecoratedSurface: Bool,
        shaderChainConsumesSurface: Bool,
        isPopupmenu: Bool,
        configuredBlurAlpha: Float
    ) -> Float {
        var terms = SurfaceFrameTerms()
        terms.blurEnabled = blurEnabled
        terms.isDecoratedSurface = isDecoratedSurface
        terms.shaderChainConsumesSurface = shaderChainConsumesSurface
        terms.isPopupmenu = isPopupmenu
        terms.configuredBlurAlpha = configuredBlurAlpha
        return make(terms: terms).backgroundAlpha
    }

    /// The load decision and every term behind it, for `ZONVIE_DRAW_TRACE=1`.
    /// One field set for both surfaces. GUI scenarios parse this line
    /// (`gate=load`, `layout=`, `rowDirty=`, `gpuScroll=`, `-> reuse=`), so
    /// those names are part of its contract. `reuse` is whether the pass keeps
    /// the previous back texture.
    func traceLine(surface: Int64) -> String {
        let t = terms
        let rowDirty = t.rowMode && (t.hasDirtyRows || t.hasLayerWork)
        let fields: [String] = [
            "surface=\(surface) gate=load",
            "glow=\(t.glowEnabled ? 1 : 0)",
            "fontCurrent=\(t.fontIsCurrent ? 1 : 0)",
            "layout=\(t.hasLayoutDamage ? 1 : 0)",
            "decorated=\(t.isDecoratedSurface ? 1 : 0)",
            "layersOutside=\(t.hostsLayersOutsideDirtySet ? 1 : 0)",
            "gpuScroll=\(t.scrollBlitKeptBackTexture ? 1 : 0)",
            "dirtyBlur=\(canDirtyOnlyWithBlur ? 1 : 0)",
            "reuseHosted=\(reusesHostedContents ? 1 : 0)",
            "reuseRoot=\(reusesRootContents ? 1 : 0)",
            "partialHosted=\(partialHostedContents ? 1 : 0)",
            "rect=\(t.hasDirtyRect ? 1 : 0)",
            "rowDirty=\(rowDirty ? 1 : 0)",
            "smooth=\(t.isSmoothScrolling ? 1 : 0)",
            "plan=\(rowPassPlan)",
            "-> reuse=\(loadsPreviousContents ? 1 : 0) skip=\(skipsSurfacePass ? 1 : 0)",
        ]
        return fields.joined(separator: " ")
    }
}
