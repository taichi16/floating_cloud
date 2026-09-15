import AppKit

final class CandidateCaretOverlayController: NSWindowController {
    static let shared = CandidateCaretOverlayController()

    private let caretView = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 20))

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 3, height: 20)
        let window = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        caretView.wantsLayer = true
        caretView.layer?.backgroundColor = NSColor.clear.cgColor
        caretView.layer?.cornerRadius = 1.5
        window.contentView = caretView

        super.init(window: window)
        window.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(anchor: CGPoint) {
        _ = anchor
        hide()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

final class BasicCandidatePanelController: NSWindowController {
    static let shared = BasicCandidatePanelController()

    private final class CandidateListView: NSView {
        var rowStartIndex = 0
        var candidates: [String] = []
        var selectedIndex = 0
        var lineHeight: CGFloat = 22
        var horizontalPadding: CGFloat = 8
        var verticalPadding: CGFloat = 8
        var numberColumnWidth: CGFloat = 20
        var separatorX: CGFloat = 31
        var contentColumnLeading: CGFloat = 38

        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let contentFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let contentBoldFont = NSFont.systemFont(ofSize: 16, weight: .semibold)

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            for (offset, value) in candidates.enumerated() {
                let absoluteIndex = rowStartIndex + offset
                let rowY = verticalPadding + (CGFloat(offset) * lineHeight)
                let isSelected = (absoluteIndex == selectedIndex)

                // 1. Draw modern mint pill selection background
                if isSelected {
                    let pillRect = NSRect(
                        x: horizontalPadding - 3,
                        y: rowY - 1,
                        width: bounds.width - ((horizontalPadding - 3) * 2),
                        height: lineHeight + 2
                    )
                    // #95D3CE (RGB: 149, 211, 206) Accent Pill
                    let pillColor = NSColor(red: 149.0/255.0, green: 211.0/255.0, blue: 206.0/255.0, alpha: 0.95)
                    pillColor.setFill()
                    let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
                    pillPath.fill()
                }

                // 2. Draw number index
                let numberColor: NSColor
                if isSelected {
                    numberColor = NSColor(red: 16.0/255.0, green: 60.0/255.0, blue: 55.0/255.0, alpha: 0.85)
                } else {
                    numberColor = NSColor.secondaryLabelColor
                }
                let numberAttrs: [NSAttributedString.Key: Any] = [
                    .font: numberFont,
                    .foregroundColor: numberColor
                ]
                let numberText = NSString(string: "\(absoluteIndex + 1)")
                let numberSize = numberText.size(withAttributes: numberAttrs)
                let numberY = rowY + floor((lineHeight - numberSize.height) / 2)
                numberText.draw(
                    at: CGPoint(
                        x: horizontalPadding + numberColumnWidth - numberSize.width,
                        y: numberY
                    ),
                    withAttributes: numberAttrs
                )

                // 3. Draw candidate text
                let textColor: NSColor
                let textFont: NSFont
                if isSelected {
                    textColor = NSColor(red: 10.0/255.0, green: 40.0/255.0, blue: 36.0/255.0, alpha: 1.0)
                    textFont = contentBoldFont
                } else {
                    textColor = NSColor.labelColor
                    textFont = contentFont
                }
                let contentAttrs: [NSAttributedString.Key: Any] = [
                    .font: textFont,
                    .foregroundColor: textColor
                ]
                let textY = rowY + floor((lineHeight - textFont.pointSize) / 2) - 1
                NSString(string: value).draw(
                    at: CGPoint(x: contentColumnLeading, y: textY),
                    withAttributes: contentAttrs
                )
            }
        }
    }

    private let listView = CandidateListView(frame: .zero)
    private let bubble: NSVisualEffectView
    private var pinnedTopLeft: NSPoint?
    private let maxVisibleRows = 7

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 168, height: 240)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true

        let content = NSView(frame: rect)
        panel.contentView = content

        // Frosted liquid glass effect
        bubble = NSVisualEffectView(frame: rect)
        bubble.material = .popover
        bubble.blendingMode = .behindWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        bubble.layer?.masksToBounds = true
        bubble.layer?.borderWidth = 0.5
        bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        content.addSubview(bubble)

        listView.wantsLayer = true
        listView.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.addSubview(listView)

        super.init(window: panel)
        panel.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare() {
        _ = window
        bubble.layoutSubtreeIfNeeded()
        listView.layoutSubtreeIfNeeded()
    }

    func prewarm() {
        prepare()
        let originalPinnedTopLeft = pinnedTopLeft
        show(anchor: CGPoint(x: 160, y: 160), candidates: ["預熱", "候選"], selectedIndex: 0)
        hide()
        pinnedTopLeft = originalPinnedTopLeft
    }

    func show(anchor: CGPoint?, candidates: [String], selectedIndex: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(anchor: anchor, candidates: candidates, selectedIndex: selectedIndex)
            }
            return
        }
        guard let window, !candidates.isEmpty else { return }
        let safeIndex = max(0, min(selectedIndex, candidates.count - 1))
        let visibleCount = min(maxVisibleRows, candidates.count)
        let startIndex = min(max(0, safeIndex - visibleCount / 2), max(0, candidates.count - visibleCount))
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 8
        let numberColumnWidth: CGFloat = 16
        let textGap: CGFloat = 8
        let contentColumnLeading: CGFloat = horizontalPadding + numberColumnWidth + textGap
        let visibleCandidates = Array(candidates[startIndex..<(startIndex + visibleCount)])
        let font = listView.contentBoldFont
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let valueWidest = visibleCandidates
            .map { ceil(($0 as NSString).size(withAttributes: valueAttrs).width) }
            .max() ?? 60
        let lineHeight: CGFloat = 24
        let height = CGFloat(visibleCount) * lineHeight + (verticalPadding * 2)
        let width = min(max(contentColumnLeading + valueWidest + horizontalPadding + 6, 96), 180)
        
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        bubble.frame = NSRect(x: 0, y: 0, width: width, height: height)
        listView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        listView.rowStartIndex = startIndex
        listView.candidates = visibleCandidates
        listView.selectedIndex = safeIndex
        listView.lineHeight = lineHeight
        listView.horizontalPadding = horizontalPadding
        listView.verticalPadding = verticalPadding
        listView.numberColumnWidth = numberColumnWidth
        listView.contentColumnLeading = contentColumnLeading

        if let anchor, let screen = screenVisibleFrame(containing: anchor) {
            var topLeftX = anchor.x - (width * 0.42)
            var topLeftY = anchor.y - helperCandidatePanelYOffset
            if topLeftX + width > screen.maxX {
                topLeftX = screen.maxX - width - 8
            }
            if topLeftX < screen.minX {
                topLeftX = screen.minX + 8
            }
            if topLeftY - height < screen.minY + 8 {
                let flippedTopLeftY = anchor.y + height + helperCaretHeight + helperCandidateFlipGap
                topLeftY = min(screen.maxY - 8, flippedTopLeftY)
            }
            if topLeftY > screen.maxY - 8 {
                topLeftY = screen.maxY - 8
            }
            pinnedTopLeft = NSPoint(x: topLeftX, y: topLeftY)
        } else if pinnedTopLeft == nil {
            if let screen = screenVisibleFrame(containing: lastKnownCandidateAnchor) {
                pinnedTopLeft = NSPoint(x: screen.maxX - width - 24, y: screen.maxY - 24)
            }
        }
        if let pinnedTopLeft {
            window.setFrameTopLeftPoint(pinnedTopLeft)
        }
        bubble.needsDisplay = true
        listView.needsDisplay = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        window.orderFrontRegardless()
    }

    func show(anchor: CGPoint?, candidateEntries: [CandidateEntry], selectedIndex: Int) {
        show(anchor: anchor, candidates: candidateEntries.map(\.text), selectedIndex: selectedIndex)
    }

    func hide() {
        pinnedTopLeft = nil
        window?.orderOut(nil)
    }
}
