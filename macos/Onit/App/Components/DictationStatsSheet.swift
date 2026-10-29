// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictationStatsSheet.swift
//  Onit
//
//  Created by Loyd Kim on 4/29/26.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers


struct DictationStatsSheet: View {
    // MARK: - Properties
    
    @Binding var shouldShow: Bool

    // MARK: - Observables

    @ObservedObject private var transcriptionHistoryManager = TranscriptionHistoryManager.shared

    // MARK: - Private Variables

    private static let counterFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let speedMultiplierMinimum: Double = 2.0
    
    private let subtextColor: Color = Color.black.opacity(0.6)

    private var lifetimeStats: LifetimeTranscriptionStats? {
        return transcriptionHistoryManager.lifetimeStats
    }

    private var totalWords: Int {
        return lifetimeStats?.totalWords ?? 0
    }
    
    private var timeSavedValueAndUnit: (value: String, unit: String) {
        let timeSavedDisplay = lifetimeStats?.timeSavedDisplay() ?? .seconds(0)
        
        switch timeSavedDisplay {
        case .hours(let hours):
            return (
                String(format: "%.1f", hours),
                String.localized("hours", table: "App")
            )
        case .minutes(let minutes):
            return (
                String(format: "%.1f", minutes),
                String.localized("mins", table: "App")
            )
        case .seconds(let seconds):
            return (
                "\(seconds)",
                String.localized("secs", table: "App")
            )
        }
    }

    private var averageWPM: Int {
        return Int((lifetimeStats?.averageWPM ?? 0).rounded())
    }

    private var distinctAppsUsedCount: Int {
        return lifetimeStats?.distinctAppsUsedCount ?? 0
    }
    
    private let speedMultiplierLineFallback = String.localized("Dictate beyond the speed of typing 🔥", table: "App")

    private var speedMultiplierLine: String {
        guard let lifetimeStats
        else {
            return speedMultiplierLineFallback
        }
        
        let multiplier = lifetimeStats.averageWPM / Double(LifetimeTranscriptionStats.averageAdultWPM)
        
        if multiplier >= Self.speedMultiplierMinimum {
            let formatted = String(format: "%.1f", multiplier)
            return String.localized(
                "Dictating at %@x the speed of typing 🔥",
                table: "App",
                formatted
            )
        }
        
        return speedMultiplierLineFallback
    }
    
    // MARK: - Private Functions

    @MainActor
    private func renderSnapshotImage() -> NSImage? {
        let renderer = ImageRenderer(content: lifetimeStatsCard)
        renderer.scale = 2.0
        return renderer.nsImage
    }

    private func copyImageToClipboard() {
        guard let image = renderSnapshotImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func saveImageToDisk() {
        guard let image = renderSnapshotImage(),
              let pngData = image.pngData()
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "voice-snapshot.png"

        panel.begin { response in
            guard response == .OK,
                  let url = panel.url
            else {
                return
            }
            
            try? pngData.write(to: url)
        }
    }

    private func presentSharePicker() {
        guard let image = renderSnapshotImage() else { return }
        let picker = NSSharingServicePicker(items: [image])

        if let window = NSApp.keyWindow,
           let contentView = window.contentView
        {
            picker.show(
                relativeTo: .zero,
                of: contentView,
                preferredEdge: .minY
            )
        }
    }

    private func openX() {
        let postText = String.localized("My dictation stats with Cloudless Voice: ", table: "App")

        var components = URLComponents(string: "https://x.com/intent/tweet")
        components?.queryItems = [
            URLQueryItem(name: "text", value: postText)
        ]

        guard let url = components?.url else { return }

        copyImageToClipboard()
        NSWorkspace.shared.open(url)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            titleView
            lifetimeStatsCard
            actionButtonsRow
        }
        .padding(16)
        .background(Color.surface3)
        .overlay(alignment: .topTrailing) {
            closeButtonView
        }
    }

    // MARK: - Title View

    private var titleView: some View {
        Text(String.localized("Your Voice Snapshot", table: "App"))
            .styleText(
                size: 15,
                weight: .regular,
                color: Color.S_0,
                align: .center
            )
            .frame(maxWidth: .infinity)
    }

    // MARK: - Snapshot Card

    private var lifetimeStatsCard: some View {
        HStack(alignment: .center, spacing: 32) {
            lifetimeStatsCardLeftColumn
            lifetimeStatsCardDivider
            lifetimeStatsCardRightColumn
        }
        .padding(28)
        .frame(
            width: 476,
            height: 315
        )
        .background(Color.cloud)
        .cornerRadius(24)
    }

    private var lifetimeStatsCardLeftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String.localized("DICTATED WORDS WITH CLOUDLESS VOICE", table: "App"))
                    .styleText(
                        size: 12,
                        color: subtextColor
                    )
                Text(
                    Self.counterFormatter.string(
                        from: NSNumber(value: totalWords)
                    ) ?? "\(totalWords)"
                )
                .styleText(
                    fontFamily: .libreBaskerville,
                    size: 56,
                    weight: .regular,
                    color: Color.black
                )
            }

            Spacer()

            VStack(alignment: .leading, spacing: 13) {
                Text(speedMultiplierLine)
                    .styleText(
                        fontFamily: .libreBaskerville,
                        size: 20,
                        color: Color.black
                    )
                    .fixedSize(horizontal: false, vertical: true)

                Text(String.localized("total cost: $0 - www.cloudless.so", table: "App"))
                    .styleText(
                        fontFamily: .inter,
                        size: 13,
                        weight: .regular,
                        color: subtextColor
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lifetimeStatsCardDivider: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: proxy.size.width / 2, y: proxy.size.height))
            }
            .stroke(
                Color.black.opacity(0.2),
                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
            )
        }
        .frame(width: 1)
        .frame(maxHeight: .infinity)
    }

    private var lifetimeStatsCardRightColumn: some View {
        VStack(alignment: .leading, spacing: 41) {
            lifetimeStatRow(
                label: String.localized("TIME SAVED", table: "App"),
                value: timeSavedValueAndUnit.value,
                unit: timeSavedValueAndUnit.unit
            )
            lifetimeStatRow(
                label: String.localized("AVG. SPEED", table: "App"),
                value: "\(averageWPM)",
                unit: String.localized("WPM", table: "App")
            )
            lifetimeStatRow(
                label: String.localized("APPS USED", table: "App"),
                value: "\(distinctAppsUsedCount)",
                unit: distinctAppsUsedCount == 1
                    ? String.localized("app", table: "App")
                    : String.localized("apps", table: "App")
            )
        }
        .frame(width: 100, alignment: .leading)
    }

    private func lifetimeStatRow(
        label: String,
        value: String,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .styleText(
                    size: 12,
                    weight: .regular,
                    color: subtextColor
                )
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .styleText(
                        fontFamily: .inter,
                        size: 21,
                        weight: .regular,
                        color: Color.black
                    )
                Text(unit)
                    .styleText(
                        fontFamily: .inter,
                        size: 17,
                        weight: .regular,
                        color: Color.black
                    )
            }
        }
    }

    // MARK: - Action Buttons Row

    private var actionButtonsRow: some View {
        HStack(spacing: 12) {
            actionButton(label: String.localized("Copy image", table: "App")) {
                copyImageToClipboard()
            }
            actionButton(label: String.localized("Save image", table: "App")) {
                saveImageToDisk()
            }
            actionButton(label: String.localized("Share", table: "App")) {
                presentSharePicker()
            }
            actionButton(
                label: String.localized("Share on", table: "App"),
                rightIcon: Image(.logoX),
                tooltipPrompt: String.localized("Stats automatically copied to clipboard.\nSimply paste on X.", table: "App")
            ) {
                openX()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionButton(
        label: String,
        rightIcon: Image? = nil,
        tooltipPrompt: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(
            colorConfig: .init(
                background: Color.T_9,
                hoverBackground: Color.T_8
            ),
            sizeConfig: .init(
                horizontalPadding: 6,
                height: 30,
                cornerRadius: 8
            ),
            tooltipConfig: .init(
                prompt: tooltipPrompt
            ),
            statusConfig: .init(
                disabled: lifetimeStats == nil
            )
        ) {
            HStack(spacing: 4) {
                Text(label)
                    .styleText(
                        weight: .regular
                    )
                if let rightIcon {
                    rightIcon
                        .addIconStyles(iconSize: 15)
                }
            }
        } action: {
            action()
        }
    }

    // MARK: - Close Button

    private var closeButtonView: some View {
        Button {
            shouldShow = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.T_3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 11)
        .padding(.trailing, 16)
    }
}

// MARK: - NSImage PNG Helper

extension NSImage {
    /// PNG-encoded representation of the image, suitable for writing to disk or sharing.
    fileprivate func pngData() -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        
        return bitmap.representation(using: .png, properties: [:])
    }
}
