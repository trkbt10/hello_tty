import AppKit

/// Floating search bar overlay for in-terminal text search.
///
/// Appears at the top-right of the terminal view when Cmd+F is pressed.
/// Contains a search field, prev/next buttons, match count, and close button.
/// Escape or the close button dismisses it.
class SearchBarView: NSView {
    private let searchField = NSTextField()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    weak var searchController: TerminalSearchController?

    /// Called when the search bar should be dismissed.
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0.3, alpha: 1.0).cgColor

        // Shadow
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
        layer?.shadowOpacity = 1.0

        // Search field
        searchField.placeholderString = "Find"
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.isBordered = true
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        searchField.delegate = self

        // Previous button
        prevButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")
        prevButton.bezelStyle = .inline
        prevButton.isBordered = false
        prevButton.target = self
        prevButton.action = #selector(prevClicked)
        prevButton.setContentHuggingPriority(.required, for: .horizontal)

        // Next button
        nextButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")
        nextButton.bezelStyle = .inline
        nextButton.isBordered = false
        nextButton.target = self
        nextButton.action = #selector(nextClicked)
        nextButton.setContentHuggingPriority(.required, for: .horizontal)

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Close button
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        // Layout using auto layout
        let stackView = NSStackView(views: [searchField, prevButton, nextButton, statusLabel, closeButton])
        stackView.orientation = .horizontal
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
    }

    /// Focus the search field and select its text.
    func activate() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    /// Update the status label with current match info.
    func updateStatus() {
        statusLabel.stringValue = searchController?.matchStatusText ?? ""
    }

    // MARK: - Actions

    @objc private func searchFieldChanged() {
        let query = searchField.stringValue
        searchController?.search(for: query)
        updateStatus()
        triggerRedraw()
    }

    @objc private func prevClicked() {
        searchController?.previousMatch()
        updateStatus()
        triggerRedraw()
    }

    @objc private func nextClicked() {
        searchController?.nextMatch()
        updateStatus()
        triggerRedraw()
    }

    @objc private func closeClicked() {
        searchController?.close()
        onClose?()
    }

    private func triggerRedraw() {
        // Request a redraw of the terminal view
        if let superview = superview as? TerminalBaseView {
            if let gpuView = superview as? TerminalGPUView {
                gpuView.setNeedsRender()
            } else {
                superview.needsDisplay = true
            }
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        let keyCode = event.keyCode

        switch keyCode {
        case 53: // Escape
            searchController?.close()
            onClose?()
        case 36: // Return/Enter
            if event.modifierFlags.contains(.shift) {
                searchController?.previousMatch()
            } else {
                searchController?.nextMatch()
            }
            updateStatus()
            triggerRedraw()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSTextFieldDelegate

extension SearchBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        searchController?.search(for: query)
        updateStatus()
        triggerRedraw()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape key
            searchController?.close()
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Enter → next match
            searchController?.nextMatch()
            updateStatus()
            triggerRedraw()
            return true
        }
        return false
    }
}
