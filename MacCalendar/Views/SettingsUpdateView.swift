//
//  SettingsUpdateView.swift
//  Menucal
//
//  Created by ruihelin on 2026/4/28.
//


import SwiftUI
import AppKit

struct SettingsUpdateView: View {
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var operationError: String?
    @State private var isInstalling = false

    private var currentVersion: String {
        Bundle.main.appVersion ?? "1.0.0"
    }
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(currentVersion)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("检查更新")
                    Spacer()
                    Button(action: {
                        checkForUpdates()
                    }) {
                        if updateManager.isChecking {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Text("检查更新")
                        }
                    }
                    .disabled(updateManager.isChecking || updateManager.isDownloading || isInstalling)
                }

                Text("启动后每小时自动检查更新，发现新版本时会在左下方显示标识。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let date = updateManager.lastSuccessfulCheckDate {
                    HStack {
                        Text("上次检查")
                        Spacer()
                        Text(date, style: .date)
                        Text(date, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            
            Section {
                if updateManager.isDownloading {
                    downloadProgressView
                } else {
                    statusView
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var downloadProgressView: some View {
        HStack(spacing: 12) {
            Text("下载中")
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView(value: updateManager.downloadProgress)
                .progressViewStyle(.linear)
                .frame(width: 200)

            Text(String(format: "%.1f%%", updateManager.downloadProgress * 100))
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .trailing)

            Button("取消", action: cancelDownload)
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(8)
    }

    @ViewBuilder
    private var statusView: some View {
        if isInstalling {
            statusPanel(
                icon: "externaldrive.badge.checkmark",
                color: .blue,
                title: "正在挂载安装包",
                message: "安装包打开后，请将 Menucal 拖入“应用程序”文件夹"
            )
        } else if let operationError {
            statusPanel(
                icon: "xmark.circle",
                color: .red,
                title: "更新失败",
                message: operationError
            )
        } else if updateManager.isChecking {
            statusPanel(
                icon: "magnifyingglass",
                color: .blue,
                title: "检查更新中...",
                message: "正在获取最新版本信息"
            )
        } else {
            switch updateManager.availability {
            case .unknown:
                if let checkError = updateManager.checkError {
                    checkErrorView(checkError)
                } else {
                    statusPanel(
                        icon: "info.circle",
                        color: .secondary,
                        title: "检查更新",
                        message: "将自动获取最新版本，也可以点击上方按钮立即检查"
                    )
                }
            case .upToDate:
                if let checkError = updateManager.checkError {
                    checkErrorView(checkError)
                } else {
                    statusPanel(
                        icon: "checkmark.circle",
                        color: .green,
                        title: "已经是最新版本",
                        message: "当前版本 v\(currentVersion)"
                    )
                }
            case .available(let version):
                availableUpdateView(version: version)
            }
        }
    }

    private func checkErrorView(_ message: String) -> some View {
        statusPanel(
            icon: "xmark.circle",
            color: .red,
            title: "检查更新失败",
            message: message
        )
    }

    private func statusPanel(
        icon: String,
        color: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(16)
    }

    private func availableUpdateView(version: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 24))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("发现新版本 v\(version)")
                    .font(.headline)

                Text(updateAvailabilityMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("下载并安装", action: downloadAndInstallUpdate)
                .buttonStyle(.borderedProminent)
                .disabled(updateManager.downloadURL == nil)
        }
        .padding(16)
    }

    private var updateAvailabilityMessage: String {
        if let checkError = updateManager.checkError {
            return "最近一次检查失败：\(checkError)"
        }
        return "当前版本 v\(currentVersion)"
    }

    private func checkForUpdates() {
        operationError = nil

        Task {
            await updateManager.checkForUpdates(source: .manual)
        }
    }

    private func downloadAndInstallUpdate() {
        operationError = nil

        updateManager.downloadUpdate { dmgURL, error in
            DispatchQueue.main.async {
                if let dmgURL = dmgURL {
                    self.isInstalling = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.installUpdate(from: dmgURL)
                    }
                } else if let error = error {
                    self.operationError = error.localizedDescription
                }
            }
        }
    }

    private func installUpdate(from dmgURL: URL) {
        updateManager.installUpdate(from: dmgURL) { success, errorMessage in
            DispatchQueue.main.async {
                if success {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApplication.shared.terminate(nil)
                    }
                } else {
                    self.isInstalling = false
                    self.operationError = errorMessage ?? "挂载失败"
                }
            }
        }
    }

    private func cancelDownload() {
        updateManager.cancelDownload()
        operationError = nil
    }
}
