import AppKit

/// Manages in-terminal text search state and match navigation.
///
/// The search operates on the visible grid content (the current viewport).
/// Matches are represented as (row, startCol, endCol) tuples.
/// The controller drives selection highlighting via InputHandler.
class TerminalSearchController {
    weak var state: TerminalState?
    weak var inputHandler: InputHandler?

    /// Current search query.
    private(set) var query: String = ""

    /// Whether search is case-sensitive.
    var caseSensitive: Bool = false {
        didSet { if oldValue != caseSensitive { performSearch() } }
    }

    /// All matches in the current viewport, ordered top-to-bottom, left-to-right.
    private(set) var matches: [(row: Int, startCol: Int, endCol: Int)] = []

    /// Index of the currently focused match (-1 if no match).
    private(set) var currentMatchIndex: Int = -1

    /// Whether the search bar is visible.
    var isActive: Bool = false

    init(state: TerminalState, inputHandler: InputHandler) {
        self.state = state
        self.inputHandler = inputHandler
    }

    // MARK: - Search

    /// Update the search query and find all matches.
    func search(for query: String) {
        self.query = query
        performSearch()
    }

    /// Re-run the search against the current grid content.
    /// Call this after grid updates to keep matches in sync.
    func refreshSearch() {
        guard isActive, !query.isEmpty else { return }
        performSearch()
    }

    /// Find all matches in the viewport grid.
    private func performSearch() {
        matches.removeAll()
        currentMatchIndex = -1

        guard !query.isEmpty, let state = state, let grid = state.fetchGrid() else {
            inputHandler?.clearSelection()
            return
        }

        let searchQuery = caseSensitive ? query : query.lowercased()

        // Extract text line-by-line from the grid and find matches
        var cellMap: [Int: [Int: TerminalGrid.CellData]] = [:]
        for cell in grid.cells {
            if cellMap[cell.row] == nil { cellMap[cell.row] = [:] }
            cellMap[cell.row]![cell.col] = cell
        }

        for row in 0..<grid.rows {
            // Build the line string with column-index tracking
            var lineChars: [Character] = []
            // Map from character index in lineChars to grid column
            var charToCol: [Int] = []

            for col in 0..<grid.cols {
                if let cell = cellMap[row]?[col] {
                    let ch = cell.char
                    if ch == "\u{0}" {
                        // Continuation cell of wide char — skip
                        continue
                    }
                    charToCol.append(col)
                    lineChars.append(ch)
                } else {
                    charToCol.append(col)
                    lineChars.append(" ")
                }
            }

            let lineStr = String(lineChars)
            let haystack = caseSensitive ? lineStr : lineStr.lowercased()

            // Find all occurrences in this line
            var searchStart = haystack.startIndex
            while let range = haystack.range(of: searchQuery, range: searchStart..<haystack.endIndex) {
                let startIdx = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
                let endIdx = haystack.distance(from: haystack.startIndex, to: range.upperBound) - 1

                if startIdx < charToCol.count && endIdx < charToCol.count {
                    matches.append((
                        row: row,
                        startCol: charToCol[startIdx],
                        endCol: charToCol[endIdx]
                    ))
                }

                // Move past the current match start to find overlapping matches
                searchStart = haystack.index(after: range.lowerBound)
            }
        }

        if !matches.isEmpty {
            currentMatchIndex = 0
            highlightCurrentMatch()
        } else {
            inputHandler?.clearSelection()
        }
    }

    // MARK: - Navigation

    /// Move to the next match (wraps around).
    func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        highlightCurrentMatch()
    }

    /// Move to the previous match (wraps around).
    func previousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        highlightCurrentMatch()
    }

    // MARK: - Selection

    /// Set the selection to highlight the current match.
    private func highlightCurrentMatch() {
        guard currentMatchIndex >= 0 && currentMatchIndex < matches.count,
              let input = inputHandler
        else { return }

        let match = matches[currentMatchIndex]
        input.selectionAnchor = (row: match.row, col: match.startCol)
        input.selectionEnd = (row: match.row, col: match.endCol)
    }

    /// Close search and clear state.
    func close() {
        isActive = false
        query = ""
        matches.removeAll()
        currentMatchIndex = -1
        inputHandler?.clearSelection()
    }

    /// Format match count for display (e.g., "3 of 12" or "No results").
    var matchStatusText: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        return "\(currentMatchIndex + 1) of \(matches.count)"
    }
}
