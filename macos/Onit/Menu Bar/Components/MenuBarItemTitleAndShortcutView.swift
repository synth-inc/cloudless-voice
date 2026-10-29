// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarItemTitleAndShortcutView.swift
//  Onit
//
//  Created by Loyd Kim on 4/27/26.
//

import AppKit

final class MenuBarItemTitleAndShortcutView: NSView {
    // MARK: - Properties

    private let title: String
    private let shortcutText: String
    private let onClick: @MainActor () -> Void

    // MARK: - Initialization

    init(
        title: String,
        shortcutText: String,
        onClick: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.shortcutText = shortcutText
        self.onClick = onClick

        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: menuItemWidth,
                height: menuItemHeight
            )
        )

        configureView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Private Variables

    private let menuItemWidth: CGFloat = 280
    private let menuItemHeight: CGFloat = 24
    private let leadingPadding: CGFloat = 16
    private let trailingPadding: CGFloat = -16
    private let highlightInset: CGFloat = 5
    private let highlightCornerRadius: CGFloat = 7

    private let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    private let hoverHighlightView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .selection
        view.state = .active
        view.isEmphasized = true
        view.blendingMode = .behindWindow
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private var trackingArea: NSTrackingArea?

    private var isHovered: Bool = false {
        didSet {
            let hoverStateChanged = oldValue != isHovered
            guard hoverStateChanged else { return }
            hoverHighlightView.isHidden = !isHovered
        }
    }

    // MARK: - Configuration

    private func configureView() {
        wantsLayer = true

        configureHoverHighlightView()
        addSubview(hoverHighlightView)

        configureLabels()
        addSubview(titleLabel)
        addSubview(shortcutLabel)

        configureSubviewConstraints()
    }

    private func configureHoverHighlightView() {
        hoverHighlightView.layer?.cornerRadius = highlightCornerRadius
        hoverHighlightView.layer?.masksToBounds = true
    }

    private func configureLabels() {
        titleLabel.stringValue = title
        titleLabel.font = font
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutLabel.stringValue = shortcutText
        shortcutLabel.font = font
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSubviewConstraints() {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(
                equalToConstant: menuItemHeight
            ),

            hoverHighlightView.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: highlightInset
            ),
            hoverHighlightView.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -highlightInset
            ),
            hoverHighlightView.topAnchor.constraint(
                equalTo: topAnchor
            ),
            hoverHighlightView.bottomAnchor.constraint(
                equalTo: bottomAnchor
            ),

            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: leadingPadding
            ),
            titleLabel.centerYAnchor.constraint(
                equalTo: centerYAnchor
            ),

            shortcutLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: trailingPadding
            ),
            shortcutLabel.centerYAnchor.constraint(
                equalTo: centerYAnchor
            )
        ])
    }

    // MARK: - Hover Detection

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingTrackingArea = trackingArea {
            removeTrackingArea(existingTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    // MARK: - Click Dispatch

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        enclosingMenuItem?.menu?.cancelTrackingWithoutAnimation()
        onClick()
    }
}
