/// What one on_vertices_row callback updates, decoded by the core's rule
/// (zonvie_core_row_update, zonvie_frontend.h): MAIN replaces the rows,
/// CURSOR without MAIN is cursor-only. The core sets exactly one; `none` is
/// only the decode of a word it never sends. The Windows frontend reads the
/// raw bits and asserts that instead.
enum VertexRowUpdate: Equatable {
    case main, cursorOnly, none

    init(flags: UInt32) {
        switch UInt32(zonvie_core_row_update(flags)) {
        case UInt32(ZONVIE_ROW_UPDATE_MAIN): self = .main
        case UInt32(ZONVIE_ROW_UPDATE_CURSOR_ONLY): self = .cursorOnly
        default: self = .none
        }
    }
}
