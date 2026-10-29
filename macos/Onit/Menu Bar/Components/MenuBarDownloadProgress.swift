// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MenuBarDownloadProgress.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-03-19.
//

import AppKit

// MARK: - Menu Item

@MainActor
final class MenuBarDownloadProgress: MenuBarItemBase {

    // MARK: - Properties

    private(set) weak var progressView: DownloadProgressItemView?

    // MARK: - Initializer

    convenience init() {
        self.init(title: "", action: nil as Selector?, keyEquivalent: "")
    }

    override func initializeProperties() {
        self.title = ""
        self.action = nil
        self.keyEquivalent = ""
        self.isEnabled = false
    }

    override func runPostInitilizationSetup() {
        let view = DownloadProgressItemView()
        self.view = view
        self.progressView = view
        self.refresh()
    }

    /// Pull the active model's reactive label + percentage from the shared indicator. Called once at
    /// setup and on every poll tick so a dictation → Smart Cleanup hand-off updates copy *and* %.
    func refresh() {
        guard let current = ModelDownloadIndicator.current else { return }
        self.progressView?.update(label: current.label, progress: current.progress)
    }
}

// MARK: - Custom View

final class DownloadProgressItemView: NSView {

    // MARK: - Properties

    /// Reactive title - "Downloading local dictation model… (Don't quit)" /
    /// "Downloading Smart Cleanup model… (Don't quit)".
    private let titleLabel: NSTextField
    private let percentLabel: NSTextField
    private let progressIndicator: NSProgressIndicator

    /// Toggled by `update`: the bar leaves room for "X%" during the download phase, and claims the
    /// full width during the (no-percentage) warmup phase.
    private var barTrailingToPercent: NSLayoutConstraint?
    private var barTrailingToEdge: NSLayoutConstraint?

    // MARK: - Layout Constants

    private let menuItemWidth: CGFloat = 280
    private let menuItemHeight: CGFloat = 38
    private let menuItemLeftPadding: CGFloat = 14
    private let menuItemRightPadding: CGFloat = -14
    private let percentLabelWidth: CGFloat = 36

    // MARK: - Initializer

    init() {
        self.titleLabel = NSTextField(labelWithString: "")
        self.percentLabel = NSTextField(labelWithString: "0%")
        self.progressIndicator = NSProgressIndicator()

        super.init(
            frame: NSRect(
                x: 0,
                y: 0,
                width: self.menuItemWidth,
                height: self.menuItemHeight
            )
        )

        // Grow/shrink with the menu's width (which is driven by the widest item) instead of staying
        // pinned at a static width - the subviews pin to self's edges, so they follow.
        self.autoresizingMask = [.width]

        self.configureView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureView() {
        self.wantsLayer = true

        // Title - top row, left aligned, truncates if the menu is narrow.
        self.titleLabel.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        self.titleLabel.textColor = .secondaryLabelColor
        self.titleLabel.lineBreakMode = .byTruncatingTail
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
        self.titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Percent - bottom row, right-aligned, sits inline with the progress bar.
        self.percentLabel.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        self.percentLabel.textColor = .secondaryLabelColor
        self.percentLabel.alignment = .right
        self.percentLabel.translatesAutoresizingMaskIntoConstraints = false

        // Progress indicator - always determinate, fills from 0% to 100%.
        self.progressIndicator.style = .bar
        self.progressIndicator.isIndeterminate = false
        self.progressIndicator.minValue = 0
        self.progressIndicator.maxValue = 1
        self.progressIndicator.doubleValue = 0
        self.progressIndicator.controlSize = .small
        self.progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(self.titleLabel)
        self.addSubview(self.percentLabel)
        self.addSubview(self.progressIndicator)

        // The bar's trailing edge is switchable (see `update`): left of the percentage during
        // download, or the full right edge during warmup so the barber-pole spans the whole width.
        let barTrailingToPercent = self.progressIndicator.trailingAnchor.constraint(
            equalTo: self.percentLabel.leadingAnchor,
            constant: -8
        )
        let barTrailingToEdge = self.progressIndicator.trailingAnchor.constraint(
            equalTo: self.trailingAnchor,
            constant: self.menuItemRightPadding
        )
        self.barTrailingToPercent = barTrailingToPercent
        self.barTrailingToEdge = barTrailingToEdge

        NSLayoutConstraint.activate([
            self.heightAnchor.constraint(equalToConstant: self.menuItemHeight),

            // Title - top row, spanning the width.
            self.titleLabel.leadingAnchor.constraint(
                equalTo: self.leadingAnchor,
                constant: self.menuItemLeftPadding
            ),
            self.titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: self.trailingAnchor,
                constant: self.menuItemRightPadding
            ),
            self.titleLabel.topAnchor.constraint(equalTo: self.topAnchor, constant: 4),

            // Progress bar - bottom row, fills remaining width.
            self.progressIndicator.leadingAnchor.constraint(
                equalTo: self.leadingAnchor,
                constant: self.menuItemLeftPadding
            ),
            self.progressIndicator.topAnchor.constraint(
                equalTo: self.titleLabel.bottomAnchor,
                constant: 4
            ),
            barTrailingToPercent, // default: download phase

            // Percent - bottom row, pinned to the right edge.
            self.percentLabel.trailingAnchor.constraint(
                equalTo: self.trailingAnchor,
                constant: self.menuItemRightPadding
            ),
            self.percentLabel.widthAnchor.constraint(equalToConstant: self.percentLabelWidth),
            self.percentLabel.centerYAnchor.constraint(equalTo: self.progressIndicator.centerYAnchor),
        ])
    }

    // MARK: - Updates

    /// Set the reactive label + progress. A non-nil progress (0.0–1.0) renders a determinate bar +
    /// percentage (download phase); `nil` renders an indeterminate barber-pole with no percentage
    /// (warmup phase). The "(Don't quit)" warning is appended here so the indicator's base label
    /// stays surface-agnostic.
    func update(label: String, progress: Double?) {
        self.titleLabel.stringValue = label + " " + String.localized("(Don't quit)", table: "Onboarding")

        if let progress = progress {
            // Download phase: leave room for "X%" to the right of the bar.
            self.barTrailingToEdge?.isActive = false
            self.barTrailingToPercent?.isActive = true

            self.progressIndicator.stopAnimation(nil)
            self.progressIndicator.isIndeterminate = false
            self.progressIndicator.doubleValue = progress
            self.percentLabel.stringValue = "\(Int((progress * 100).rounded()))%"
        } else {
            // Warmup phase: no percentage, so the barber-pole spans the full width.
            self.barTrailingToPercent?.isActive = false
            self.barTrailingToEdge?.isActive = true

            self.percentLabel.stringValue = ""
            self.progressIndicator.isIndeterminate = true
            self.progressIndicator.startAnimation(nil)
        }
    }
}
