# Thymer-style edit effects via custom shaders — design

Date: 2026-08-28
Status: draft, awaiting review

## Goal

Let a user-supplied custom shader reproduce the two edit effects seen in the
Thymer editor demo (x.com/wcools/status/2093081211090403391, frames archived
under `tmp/thymer/`), while keeping every existing Ghostty/Shadertoy shader
working unchanged. Deliver both the plumbing and a reference shader.

1. **Cursor shear** — while the cursor moves, its body is skewed and
   stretched along the direction of travel and relaxes back over ~120 ms.
2. **Glyph blur-in / ghost-out** — a glyph typed in Insert mode appears as a
   blurred blob that sharpens over ~150 ms; a glyph deleted with backspace
   lingers as a fading, progressively blurrier ghost at its old position for
   the same window.

## What the current pipeline cannot do

Verified against `macos/Sources/Rendering/MetalTerminalRenderer.swift`:

- A post-process shader sees only the final composite (`iChannel0`), time,
  and the cursor rects. It has no way to learn *which cell changed when*,
  and a deleted glyph is already gone from `iChannel0`.
- The last custom shader pass renders straight into the drawable (`:3680`),
  so the shader's own output is not retained across frames. A ghost that
  lasts ~9 frames cannot be built from "one frame back" of the composite
  — by the second frame the pre-deletion pixels are gone. The ghost has to
  come from the previous *shader output*, fed back and decayed.
- The cursor is drawn on the drawable **after** the shader (`:2925`,
  `:3805`), so `iChannel0` has no cursor and a shader cannot deform it. The
  shear needs the shader to draw the cursor and the frontend to skip the
  native pass.

## Non-goals

- No change to what the core emits as vertices. Users with shaders disabled
  see byte-identical output and pay nothing.
- No `iChannel1..3`. Ghostty reserves those (commented out in
  `tmp/ghostty/src/renderer/shaders/shadertoy_prefix.glsl:42-44`); Zonvie
  inputs get Zonvie names.
- No effect for Normal-mode edits, scrolling, pastes or full redraws.
- Float and external grids are excluded from v1 (see Open questions).
- Windows: same ABI, same core logic, D3D11 work described at contract
  level; hardware smoke is a follow-up as with other Windows work here.

## Compatibility argument

Everything is additive:

- New uniform fields are appended to `zonvie_shader_uniforms` (std140).
  Offsets 0..159 do not move.
- New samplers get new binding indices. GLSL ignores unreferenced
  declarations, so `cursor_blaze.glsl` and the rest of
  `tmp/ghostty-shaders/` compile and run unchanged.
- The cursor-ownership marker (below) is an opt-in comment; shaders without
  it keep today's behaviour exactly.

## Architecture

### A. Feedback texture (`iPrevFrame`)

When a custom shader is active, the **last** shader pass renders into one
of two persistent `feedback[0/1]` textures (drawable size, drawable pixel
format, allocated by the same size-gated path as `customShaderPong`) instead
of the drawable, alternating each frame. The existing copy pass
(`copyRPD`, `:3700`) then copies it to the drawable. The texture not
written this frame is bound to the shader as `iPrevFrame`.

Cost: one full-screen copy per frame — the same copy the non-shader path
already performs today, so the shader path stops being the exception. No
per-frame allocation.

`iPrevFrame` holds the previous frame's *final* output: shader effects and
the shader-drawn cursor included, native cursor excluded (the native cursor
pass draws on the drawable after the copy). The preamble gives `iPrevFrame`
the same screen-UV wrapper `iChannel0` has, so
`texture(iPrevFrame, fragCoord / iResolution.xy)` works per view.

Multi-window: each view has its own back buffer and its own feedback pair.
Views without a shader have none.

### B. Cell-age texture (`iCellAge`)

One texel per cell, `R32Float`. Value = the `iTime` at which the cell was
last stamped; `0` = never / cleared. The shader derives `age = iTime -
texel` (`zonvieCellAge(px)` in the preamble).

There is one texture per **surface**: the main window's is `cols × rows`
of the screen (composited floats are stamped there at their `win_pos`
offset); every external window (a `win_external_pos` grid, the
ext-cmdline surface) has its own, indexed by that grid's coordinates, and
its `iGridOrigin` uniform is where that grid starts in screen space.

The **core** decides what to stamp (Gate rules) and hands the frontend a
per-flush list. The **frontend** owns the textures (GPU resources, tied to
the shader pipeline's lifetime, absent when shaders are off) and uploads
only the stamped texels. Resize recreates a texture zero-filled. Clears
are per texture (see ABI); a bulk update clears all of them.

### C. Uniform additions

Appended after `_pad_cursor` (offset 160); UBO size 160 → 192:

```
float   iCellSize[2];        /* 160..167  cell (w, h) in drawable px            */
float   iGridOrigin[2];      /* 168..175  main grid top-left, drawable px       */
float   iTimeLastEdit;       /* 176..179  iTime of the most recent stamp        */
int32_t iCursorVisible;      /* 180..183  0 while blink-off; Ghostty name/type  */
int32_t iCurrentCursorStyle; /* 184..187  Ghostty enum, see below              */
int32_t iPreviousCursorStyle;/* 188..191  style before the last cursor change  */
```

`iCellSize` / `iGridOrigin` map `fragCoord` to a cell for the `iCellAge`
lookup and confine blur to one cell. `iTimeLastEdit` is the early-out.
`iCursorVisible` is filled from the renderer's blink state
(`cursorBlinkState`, `:702`) so a shader-drawn cursor blinks like the native
one.

The three `int32_t` fields use Ghostty's names, types and values
(`tmp/ghostty/src/renderer/cursor.zig:7`): `0 block`, `1 block_hollow`,
`2 bar`, `3 underline`, `4 lock`. Zonvie maps its `mode_info_set` shapes
`block → 0`, `vertical → 2`, `horizontal → 3`; `block_hollow` and `lock`
are never emitted. `iPreviousCursorStyle` rotates with the existing
previous-cursor rotation in `evaluateCursorShaderChange`. Shaders written
against Ghostty's cursor-style uniforms then port without edits, which is
the second reason to add them.

### D. Cursor ownership marker

A shader that contains the comment token `@zonvie-owns-cursor` (detected by
the same whole-word regex scan `CustomShaderPipeline.detectNeedsAnimation`
already does for `iTime`) tells the frontend to **skip the native cursor
pass for every cursor shape**; the shader draws the cursor from
`iCurrentCursor` / `iCurrentCursorStyle`. `guicursor` still decides the
shape. What is lost is the glyph under a block cursor: the native pass
painted it in the cell background colour, which a post-process shader does
not know, so the reference shader draws a solid block. (Two heuristics for
recovering that colour were tried and both misfired visibly.)

No config key: the shader file states what it needs.

## Gate rules (core)

The question the core answers is "is this flush essentially a keystroke
edit on this surface?" — by the flush's **composition**, never by editor
mode (Normal-mode `x` is an edit; a `mode_change` can trail the first typed
character's `grid_line` inside one batch).

Per `grid_line` tuple:

1. **Surface.** Grid 1 and composited sub-grids (`win_pos`) stamp the main
   texture at their screen offset; an external grid stamps its own texture
   with grid-local coordinates; a sub-grid with neither has no screen
   position and stamps nothing.
2. **Glyph identity only.** A cell counts as changed when its codepoint
   changed, not its highlight. An IME preedit committed with Enter swaps
   the underlined preedit highlight for the normal one on the same glyphs,
   and that must not read as typing the text a second time.
3. **Near the cursor.** Only rows within one of the cursor's row, in the
   same coordinate space (an external grid only when the cursor is on
   it). Showmode / ruler / statusline repaints neither stamp nor clear.
4. **Not a reflow.** The span of *changed* cells wider than half the row
   is a scroll / reflow / `:s`, and turns the flush into a full clear. The
   span, not the number of cells *sent*: Neovim resends the whole row for
   an insert at column 0 or on a short line (every line of a small float),
   and judging by cells sent turned one typed glyph into a bulk repaint.
5. **Flush-level bulk guard.** More than `max_stamped_rows` (2) distinct
   rows stamped in one flush, or more runs than `cell_stamp_capacity`, is
   a bulk update: full clear.

Non-edit events mark the **texture** they invalidate, not the flush:
`grid_resize` / `grid_clear` / `grid_destroy` / `grid_scroll` /
`win_viewport` with `scroll_delta != 0` → that grid's texture;
`win_pos` / `win_float_pos` / `win_hide` / `win_close` /
`win_external_pos` → the main texture (composited layout changed);
`default_colors_set` → all. At flush, each invalidated texture gets a clear
marker and its stamps are dropped; stamps on other textures still go out.
This matters: every keystroke in an external float is followed by a flush
that repaints the main window's ruler with a `win_viewport`, and clearing
everything there erased the float's smoke one frame after it appeared.

The ext-cmdline surface is rebuilt from `cmdline_show` on every flush, so
its edits are recovered by diffing the rebuilt row against a snapshot of
the previous one (up to 512 columns); a cmdline that just opened, or one
where more than half the row changed, is a repaint.

## Data flow

```
nvim ──grid_line──▶ core redraw_handler
                       │ rules 1-3 per event
                       ▼
                   per-flush stamp list (row, col, count) — fixed capacity
                       │ rule 4 at flush end → list, or CLEAR
                       ▼
                   on_cell_age_stamps (only if frontend opted in)
                       ▼
               frontend: upload texels / zero-fill iCellAge
                       ▼
        shader pass: iChannel0 + iPrevFrame + iCellAge → feedback[n]
                       ▼
        copy → drawable → native cursor pass (skipped per section D)
```

The stamp list is a fixed-capacity per-flush buffer in the core (bounded
by `MAX_STAMPED_ROWS × cols`; overflow triggers the rule-4 clear, which is
the right outcome for a bulk update anyway). No allocation on the flush
path.

## ABI changes (coordinated core + macOS + Windows)

- `zonvie_shader_uniforms`: append section C fields. Size 160 → 192.
  Struct doc-comment and `shader_compiler.zig` preamble updated together.
- New callback at the **end** of `zonvie_callbacks`, guarded by
  `callbacks_size`:
  ```
  void (*on_cell_age_stamps)(void *ud, const zonvie_cell_stamp *stamps,
                             size_t n, int clear);
  ```
  `clear != 0` = zero every texture (`stamps` may be empty). Otherwise the
  entries are processed in order: `count == 0` = zero the texture `grid`
  selects; any other entry stamps a run on that texture. At most once per
  flush, after vertex submission and before `on_flush_end`. Invoked only
  after the frontend opts in via
  `zonvie_core_set_shader_inputs_enabled(core, bool)`, toggled on pipeline
  load/unload, so a shader-less frontend pays nothing.
- `zonvie_cell_stamp { uint16_t row; uint16_t col; uint16_t count;
  int16_t grid; }` — `grid` = 1 for the main texture, else the external
  grid id (`-100` = ext-cmdline), with row/col local to that grid. A
  frontend without per-window textures ignores `grid != 1` (Windows).
- `shader_compiler.zig` preamble: `iPrevFrame` at binding 2, `iCellAge` at
  binding 3 (0 = `iChannel0`, 1 = UBO); the MSL/HLSL remap table gains
  both entries. `iPrevFrame` gets the same wrapper type and `texture()`
  overload as `iChannel0`.

Enum values, existing layouts and existing callback signatures untouched.

## Frontend work

macOS (`MetalTerminalRenderer.swift`):
- Feedback pair + alternation; last pass targets `feedback[n]`, copy pass
  to drawable. Bind `feedback[1-n]` as texture(2).
- `iCellAge` (R32Float, cols × rows) recreated with grid size; upload via
  `replace(region:)` from the stamp callback (core thread, same rules as
  atlas region uploads). Bind as texture(3).
- Fill the new uniform fields in the per-frame uniform writer (`:4489`
  area). `iCursorVisible` from `cursorBlinkState`; the two style fields
  from the resolved mode shape, rotated alongside the previous-cursor
  rect.
- Marker scan in `CustomShaderPipeline.load`; native cursor pass skipped
  per section D (marker present and style is bar/underline).
- Call `zonvie_core_set_shader_inputs_enabled` on load/unload.

Windows: D3D11 mirror — feedback RTV pair, `R32_FLOAT` cell-age texture via
`UpdateSubresource`, SRV slots 2/3, uniform append, marker scan, cursor
skip. Compile-verified in the same change.

## Reference shader — `tmp/shaders/thymer.glsl`

Shadertoy form (`mainImage`), compiled through `zonvie_shader_compile_glsl`
so it runs on both backends. It references `iTime`, which arms the
continuous draw loop (`needsAnimation`); outside its effect windows every
fragment costs one tap.

Coordinate facts it relies on (from the preamble / renderer):
`fragCoord` is screen px, **top-left origin** (`iWindowOffset + local`);
`iCurrentCursor` = `(left, bottom, w, h)` in the same space, so the rect
spans `y-h .. y`; `iGridOrigin` is where this surface's cell grid starts.

### What the demo actually does (measured frame by frame)

Every glyph that was just typed or just deleted gets **one soft "smoke
puff"**: a blurred blob in the ink colour, about half a cell across, with
a random offset, size and timing per glyph, that fades over 0.1–1.5 s. A
typed glyph's puff is a blurred copy of the glyph itself that sits above
it and rises while it dissolves into a blob; a deleted glyph's puff stays
where the glyph was and swells. Fast typing or a held Backspace leaves a
train of puffs. The blobs are ink-coloured (blurred ink, not the cursor)
and darken the paper by 25–35/255 at their core. An earlier revision built
this as an `iPrevFrame` feedback ghost plus a per-cell halo; both were
wrong in kind (the halo's cell-shaped mask read as a blurred vertical line
on the previous glyph) and are gone. The reference shader no longer reads
`iPrevFrame` at all; the input stays available for other shaders.

### Tunables (current values)

```
PUFF_LIFE_MIN_S / MAX_S   0.10 / 1.50   life drawn uniformly per puff
PUFF_DELAY_MAX_S          0.16          random onset delay
PUFF_FADE_IN_S            0.03
PUFF_SIGMA_CELL / JIT     0.21 / 0.08   deleted-glyph blob radius
PUFF_MAX                  0.70          peak blend toward ink
PUFF_RISE_CELL / DRIFT    0.16 / 0.14   typed puff start height / rise
PUFF_JITTER_X             0.30
PUFF_SHAPE_BLUR_MIN / MAX 0.06 / 0.34   glyph-copy blur at birth / at death
PUFF_SHAPE_GAIN           1.4
PUFF_SHAPE_BLOB_MIN / MAX 0.10 / 0.70   blob weight under the glyph copy
PUFF_GROW                 0.8           deleted blob swell over its life
SHEAR_DURATION_S 0.12, SHEAR_MAX 0.10, SHEAR_DIR +1, STRETCH_MAX 0.55
```

### Algorithm

1. **Gate.** `iTime - iTimeLastEdit` past the longest possible puff → skip.
2. **Paper / ink estimate** for this row, from cells inside this window
   only: paper = most common colour at cell top-left corners (a spot that
   is background for practically every glyph — centre samples made a run
   of `l`/`t`/`i` stems the majority and bleached the glyphs), ink = the
   cell-centre sample farthest from paper. Cells outside the window would
   return the padding colour and swap the two.
3. **Puffs.** For the cells of this row, the row below and the row above
   (`dx ±2`): skip unless `zonvieCellAge` is within the window; draw three
   independent hashes of the cell (shape, timing, dissipation); onset
   delay, life, spread, dissipation curve and fade curve come from them.
   Typed cell (ink present under the cell centre): puff = the cell's ink
   sampled at `fragCoord - offset` through a disc blur whose radius grows
   with age, taps confined to the source cell, plus a Gaussian blob whose
   weight grows with age; on the grid's top row the rise is nearly zero so
   a one-row float does not push it out of its drawable. Deleted cell: a
   Gaussian blob that swells. Blend toward ink on paper pixels only
   (`distance(pixel, paper)` small).
4. **Cursor.** `@zonvie-owns-cursor`: rounded box in `iCurrentCursorColor`
   for every style; on a horizontal move the top edge shears
   `SHEAR_MAX·h` in the direction of travel and the box widens
   symmetrically by `STRETCH_MAX·w`, both relaxing as `(1-m)²` over
   `SHEAR_DURATION_S`.

Tap budget: idle 1; during an edit ≈ 15 age fetches + 9×2 estimate taps +
per active cell 5 (ink test) + 25 (glyph copy), only within the puff
window.

### What the reference shader does not do

- Vertical cursor smear on line changes (Thymer's Enter animation was not
  measured).
- The small dots Thymer draws ahead of the cursor while typing.
- Windows external windows: no per-window texture there, so no smoke in
  them (main window only).

## Performance constraints

- Nothing new on the vertex path; nothing new with shaders off.
- Per keystroke: one small texture upload (1-3 texels typical).
- Per frame with a shader: the full-screen copy the non-shader path already
  does; no extra allocation.
- Memory while a shader is loaded: two extra drawable-sized textures per
  shaded view, plus a `cols × rows` float texture.
- Final summary must include a measurement: frame time with/without
  `thymer.glsl` during held-key typing and during a held-key scroll (the
  scroll case verifies the idle path stays idle).

## Testing

Core (`zig build test`):
- Gate table: for each rule an event failing only that rule stamps
  nothing; an event passing all four yields the expected runs (with
  `repeat` expansion). Rule 4: `MAX_STAMPED_ROWS + 1` rows → `clear = 1`,
  empty list; exactly `MAX_STAMPED_ROWS` → stamps.
- Opt-in off → callback never invoked.
- Preamble: compiling `cursor_blaze.glsl` and `thymer.glsl` through
  `zonvie_shader_compile_glsl` for both MSL and HLSL succeeds; a shader
  referencing `iChannel1` still fails (Ghostty slots stay unclaimed).
- Sabotage check per repo lesson: flip each rule's comparison and confirm
  its test fails.

E2E (`zig build e2e`): type three characters in Insert mode, `<Esc>`, `x`;
assert three stamp callbacks with the expected cells and none for `x`.
Then `<C-e>` in Insert mode at a full screen; assert a `clear`.

GUI (`zig build gui-test`, macOS): with `thymer.glsl` loaded, type then
backspace; screenshot mid-window and assert the deleted cell's region is
not background-coloured; after `EDIT_DURATION_S`, assert it is. Assert the
native cursor pass is skipped (frame trace) while the marker is present and
the cursor is a bar, and runs in Normal mode (block). Visual smoke on
hardware for the shear.

## Open questions for review

1. `R32Float` vs `R16Float` for `iCellAge`: 16-bit loses precision past
   ~2048 s of `iTime`. R32Float; revisit only if the upload measures.
2. Replace mode (`R`): yes, an edit (composition rule, no mode gate).
3. Multi-grid: done — per-surface textures on macOS, `grid` is the texture
   selector; Windows keeps the main texture only.

## Decisions taken in review (2026-08-29)

- Reference shader lives at `tmp/shaders/thymer.glsl` for now; a
  permanent home is decided when the feature ships.
- Cursor ownership keys off `iCurrentCursorStyle` (Ghostty enum), not
  rect geometry. Both style uniforms are added.
