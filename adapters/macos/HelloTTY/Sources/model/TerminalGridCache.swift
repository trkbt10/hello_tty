import Foundation

/// Owns the cached terminal grid and handles differential updates.
///
/// Responsibilities:
///   - Fetch grid data from MoonBit (session-targeted)
///   - Maintain dirty state for lazy fetching
///   - Apply differential updates (none/all/rect)
///   - Track cursor position (lightweight, separate from full grid)
///
/// NOT responsible for:
///   - PTY I/O
///   - SwiftUI observation
///   - Rendering
class TerminalGridCache {
    /// The cached grid, fetched lazily on demand.
    private(set) var grid: TerminalGrid?

    /// Cursor position — updated via lightweight FFI (no JSON).
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0

    /// Whether the grid is stale and needs refetching.
    var dirty: Bool = false

    /// Current grid dimensions.
    private(set) var rows: Int = 24
    private(set) var cols: Int = 80

    private let bridge = MoonBitBridge.shared
    private let sessionId: Int32

    init(sessionId: Int32) {
        self.sessionId = sessionId
    }

    /// Mark the grid as stale. Called after PTY output is processed.
    func markDirty() {
        dirty = true
    }

    /// Update cursor position from MoonBit (lightweight, no JSON overhead).
    func refreshCursor() {
        if let cursor = bridge.getCursor() {
            cursorRow = cursor.row
            cursorCol = cursor.col
        }
    }

    /// Fetch the grid, applying differential updates.
    /// Returns nil if the grid hasn't been fetched yet and isn't dirty.
    func fetch() -> TerminalGrid? {
        guard dirty else { return grid }

        let newGrid: TerminalGrid?
        if sessionId >= 0 {
            newGrid = bridge.getGridFor(sessionId: sessionId)
        } else {
            newGrid = bridge.getGrid()
        }

        if let newGrid = newGrid {
            switch newGrid.dirty {
            case .none:
                if let existing = grid {
                    grid = TerminalGrid(
                        rows: existing.rows, cols: existing.cols,
                        cursor: newGrid.cursor, cells: existing.cells)
                }

            case .all:
                grid = newGrid

            case .rect(let top, let left, let bottom, let right):
                if let existing = grid,
                   existing.rows == newGrid.rows && existing.cols == newGrid.cols {
                    var kept = existing.cells.filter { cell in
                        !(cell.row >= top && cell.row <= bottom &&
                          cell.col >= left && cell.col <= right)
                    }
                    kept.append(contentsOf: newGrid.cells)
                    grid = TerminalGrid(
                        rows: existing.rows, cols: existing.cols,
                        cursor: newGrid.cursor, cells: kept)
                } else {
                    grid = newGrid
                }
            }
        }
        dirty = false
        return grid
    }

    /// Force a fresh fetch (sets dirty=true then fetches).
    func forceRefresh() -> TerminalGrid? {
        dirty = true
        return fetch()
    }

    /// Update tracked dimensions (called on resize).
    func updateDimensions(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}
