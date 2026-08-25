//
//  SettingsView.swift
//  Menucal
//
//  Created by ruihelin on 2025/10/6.
//

import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsType
    @ObservedObject var calendarManager: CalendarManager
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = SettingsManager.appearanceMode

    init(calendarManager: CalendarManager, initialSelection: SettingsType = .customized) {
        self.calendarManager = calendarManager
        self._selection = State(initialValue: initialSelection)
    }
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(SettingsType.allCases, selection: $selection) { setting in
                    Label(setting.rawValue, systemImage: setting.icon)
                        .tag(setting)
                }
                .listStyle(.sidebar)

                SettingsBrandFooter {
                    selection = .update
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            selection.view
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environmentObject(calendarManager)
                .navigationTitle(selection.rawValue)
        }
    }
}

private struct SettingsBrandFooter: View {
    @ObservedObject private var updateManager = UpdateManager.shared

    let showUpdates: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.45)

            if updateManager.updateAvailable {
                Button(action: showUpdates) {
                    brandContent
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("发现新版本，前往检查更新")
            } else {
                brandContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var brandContent: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Menucal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("v\(Bundle.main.appVersion ?? "-")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                if updateManager.updateAvailable {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)

                        Text("发现新版本")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.accentColor)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var accessibilityLabel: String {
        if updateManager.updateAvailable {
            return "Menucal，发现新版本"
        }
        return "Menucal"
    }
}
