//
//  UpdateManager.swift
//  Menucal
//
//  Created by ruihelin on 2026/4/28.
//

import Foundation
import Combine
import AppKit

private struct ReleaseInfo {
    let version: String
    let downloadURL: URL?
}

enum UpdateCheckSource {
    case automatic
    case manual
}

enum UpdateAvailability {
    case unknown
    case upToDate
    case available(version: String)
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "更新信息解析失败"
        case .requestFailed(let message):
            return message
        }
    }
}

@MainActor
class UpdateManager: NSObject, ObservableObject, @preconcurrency URLSessionDownloadDelegate {
    static let shared = UpdateManager()

    private enum DefaultsKey {
        static let lastSuccessfulCheckDate = "update.lastSuccessfulCheckDate"
        static let latestVersion = "update.latestVersion"
    }

    private let apiLatestReleaseURL = URL(string: "https://api.github.com/repos/ervinsae/Menucal/releases/latest")!
    private let webLatestReleaseURL = URL(string: "https://github.com/ervinsae/Menucal/releases/latest")!
    private let releaseDownloadBaseURL = "https://github.com/ervinsae/Menucal/releases/download"
    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: String
    private let automaticCheckInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let startupDelay: TimeInterval
    private var automaticCheckTimer: Timer?
    private var automaticCheckTask: Task<Void, Never>?
    private var automaticCheckTaskID: UUID?
    private var wakeObserver: NSObjectProtocol?
    private var automaticChecksStarted = false
    private var lastAttemptFailed = false

    @Published private(set) var availability: UpdateAvailability = .unknown
    @Published private(set) var isChecking = false
    @Published private(set) var checkError: String?
    @Published private(set) var lastSuccessfulCheckDate: Date?
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedFileURL: URL?
    @Published private(set) var downloadError: String?

    var updateAvailable: Bool {
        if case .available = availability {
            return true
        }
        return false
    }

    var latestVersion: String? {
        guard case .available(let version) = availability else {
            return nil
        }
        return version
    }

    private var downloadCompletion: ((URL?, Error?) -> Void)?
    private var pendingDownloadURL: URL?
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        currentVersion: String? = nil,
        automaticCheckInterval: TimeInterval = 60 * 60,
        retryInterval: TimeInterval = 15 * 60,
        startupDelay: TimeInterval = 2
    ) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion ?? Bundle.main.appVersion ?? "1.0.0"
        self.automaticCheckInterval = automaticCheckInterval
        self.retryInterval = retryInterval
        self.startupDelay = startupDelay
        super.init()
        lastSuccessfulCheckDate = defaults.object(forKey: DefaultsKey.lastSuccessfulCheckDate) as? Date
        restoreCachedAvailability()
    }

    func startAutomaticChecks() {
        guard !automaticChecksStarted else { return }
        automaticChecksStarted = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheck()
            }
        }
        scheduleAutomaticCheck(after: startupDelay)
    }

    func stopAutomaticChecks() {
        automaticChecksStarted = false
        automaticCheckTimer?.invalidate()
        automaticCheckTimer = nil
        automaticCheckTask?.cancel()
        automaticCheckTask = nil
        automaticCheckTaskID = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func performAutomaticCheck() {
        guard automaticChecksStarted, automaticCheckTask == nil else { return }
        guard !isChecking else {
            scheduleAutomaticCheck(after: startupDelay)
            return
        }
        automaticCheckTimer?.invalidate()
        let taskID = UUID()
        automaticCheckTaskID = taskID
        automaticCheckTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.automaticCheckTaskID == taskID else { return }
            await self.checkForUpdates(source: .automatic)
            if self.automaticCheckTaskID == taskID {
                self.automaticCheckTask = nil
                self.automaticCheckTaskID = nil
            }
        }
    }

    private func scheduleAutomaticCheck(after delay: TimeInterval) {
        guard automaticChecksStarted else { return }
        automaticCheckTimer?.invalidate()
        let timer = Timer(fire: Date(timeIntervalSinceNow: max(0.1, delay)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performAutomaticCheck()
            }
        }
        timer.tolerance = min(60, max(0.01, delay * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        automaticCheckTimer = timer
    }

    private func scheduleNextAutomaticCheck() {
        if lastAttemptFailed {
            scheduleAutomaticCheck(after: retryInterval)
        } else {
            let elapsed = lastSuccessfulCheckDate.map { Date().timeIntervalSince($0) } ?? 0
            scheduleAutomaticCheck(after: automaticCheckInterval - elapsed)
        }
    }

    func checkForUpdates(source: UpdateCheckSource = .manual) async {
        guard !isChecking else { return }

        switch source {
        case .automatic:
            guard shouldPerformAutomaticCheck else {
                scheduleNextAutomaticCheck()
                return
            }
        case .manual:
            break
        }

        isChecking = true
        if case .manual = source {
            checkError = nil
        }

        defer {
            isChecking = false
            if !Task.isCancelled {
                scheduleNextAutomaticCheck()
            }
        }

        do {
            let release = try await fetchLatestRelease()
            try Task.checkCancellation()
            let comparisonResult = compareVersions(currentVersion, release.version)

            lastAttemptFailed = false
            checkError = nil
            if comparisonResult == .orderedAscending {
                availability = .available(version: release.version)
                downloadURL = release.downloadURL
            } else {
                availability = .upToDate
                downloadURL = nil
            }
            persistSuccessfulCheck(version: release.version)
        } catch {
            guard !Task.isCancelled else { return }
            lastAttemptFailed = true
            if case .manual = source {
                checkError = error.localizedDescription
            }
        }
    }

    private var shouldPerformAutomaticCheck: Bool {
        guard let lastCheckDate = lastSuccessfulCheckDate else {
            return true
        }

        return Date().timeIntervalSince(lastCheckDate) >= automaticCheckInterval
    }

    private func restoreCachedAvailability() {
        guard let cachedVersion = defaults.string(
            forKey: DefaultsKey.latestVersion
        ) else {
            return
        }

        if compareVersions(currentVersion, cachedVersion) == .orderedAscending {
            availability = .available(version: cachedVersion)
            downloadURL = fallbackDownloadURL(forVersion: cachedVersion)
        } else {
            availability = .upToDate
        }
    }

    private func persistSuccessfulCheck(version: String) {
        let date = Date()
        defaults.set(version, forKey: DefaultsKey.latestVersion)
        defaults.set(date, forKey: DefaultsKey.lastSuccessfulCheckDate)
        lastSuccessfulCheckDate = date
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        do {
            return try await fetchLatestReleaseFromAPI()
        } catch {
            try Task.checkCancellation()
            return try await fetchLatestReleaseFromLatestPage()
        }
    }

    private func fetchLatestReleaseFromAPI() async throws -> ReleaseInfo {
        var request = URLRequest(url: apiLatestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Menucal/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = releaseErrorMessage(from: data) ?? "网络请求失败，状态码: \(httpResponse.statusCode)"
            throw UpdateError.requestFailed(message)
        }

        guard let release = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            throw UpdateError.invalidResponse
        }

        if let message = release["message"] as? String {
            throw UpdateError.requestFailed(message)
        }

        guard let tagName = release["tag_name"] as? String else {
            throw UpdateError.invalidResponse
        }

        let version = normalizedVersion(from: tagName)
        let downloadURL = ((release["assets"] as? [[String: Any]]) ?? [])
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:))

        return ReleaseInfo(
            version: version,
            downloadURL: downloadURL ?? fallbackDownloadURL(forVersion: version)
        )
    }

    private func fetchLatestReleaseFromLatestPage() async throws -> ReleaseInfo {
        let request = URLRequest(url: webLatestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (_, response) = try await session.data(for: request)

        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let finalURL = response.url,
              let tagName = finalURL.pathComponents.last,
              tagName.hasPrefix("v") else {
            throw UpdateError.invalidResponse
        }

        let version = normalizedVersion(from: tagName)
        return ReleaseInfo(
            version: version,
            downloadURL: fallbackDownloadURL(forVersion: version)
        )
    }

    private func normalizedVersion(from tagName: String) -> String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }

    private func fallbackDownloadURL(forVersion version: String) -> URL? {
        URL(string: "\(releaseDownloadBaseURL)/v\(version)/Menucal-\(version).dmg")
    }

    private func releaseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }

        return json["message"] as? String
    }

    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let components1 = v1.components(separatedBy: ".").compactMap { Int($0) }
        let components2 = v2.components(separatedBy: ".").compactMap { Int($0) }

        for i in 0..<max(components1.count, components2.count) {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0

            if c1 < c2 { return .orderedAscending }
            if c1 > c2 { return .orderedDescending }
        }

        return .orderedSame
    }

    func downloadUpdate(completion: @escaping (URL?, Error?) -> Void) {
        guard let url = downloadURL, !isDownloading else {
            completion(nil, NSError(domain: "UpdateManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No download URL available"]))
            return
        }

        downloadCompletion = completion
        pendingDownloadURL = url
        isDownloading = true
        downloadProgress = 0.0
        downloadError = nil

        let task = downloadSession.downloadTask(with: url)
        task.resume()
    }

    func cancelDownload() {
        downloadCompletion = nil
        pendingDownloadURL = nil
        downloadError = nil
        downloadSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        isDownloading = false
        downloadProgress = 0.0
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempURL = location

        do {
            let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let appDir = appSupportDir.appendingPathComponent("Menucal")
            
            if !FileManager.default.fileExists(atPath: appDir.path) {
                try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            }
            
            let destinationURL = appDir.appendingPathComponent("Menucal.dmg")

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: tempURL, to: destinationURL)

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadProgress = 1.0
                self.downloadedFileURL = destinationURL
                let completion = self.downloadCompletion
                self.downloadCompletion = nil
                self.pendingDownloadURL = nil
                completion?(destinationURL, nil)
            }
        } catch {
            DispatchQueue.main.async {
                self.isDownloading = false
                let completion = self.downloadCompletion
                self.downloadCompletion = nil
                self.pendingDownloadURL = nil
                completion?(nil, error)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }

        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.downloadProgress = progress
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }

            DispatchQueue.main.async {
                self.isDownloading = false
                self.downloadError = error.localizedDescription
                let completion = self.downloadCompletion
                self.downloadCompletion = nil
                self.pendingDownloadURL = nil
                completion?(nil, error)
            }
        }
    }

    func installUpdate(from dmgURL: URL, completion: @escaping (Bool, String?) -> Void) {
        let dmgPathStr = dmgURL.path
        
        guard FileManager.default.fileExists(atPath: dmgPathStr) else {
            completion(false, "下载的文件不存在")
            return
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: dmgPathStr)
            if let fileSize = attributes[.size] as? Int64 {
                if fileSize < 1024 {
                    completion(false, "下载的文件不完整，大小: \(fileSize) 字节")
                    return
                }
            }
        } catch {
            completion(false, "无法获取文件信息: \(error.localizedDescription)")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.launchPath = "/usr/bin/hdiutil"
            task.arguments = ["attach", dmgPathStr, "-nobrowse", "-noverify"]
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            task.standardOutput = outputPipe
            task.standardError = errorPipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                
                if task.terminationStatus == 0 {
                    var mountPoint: String?
                    for line in output.components(separatedBy: .newlines) {
                        if let range = line.range(of: "/Volumes/") {
                            mountPoint = String(line[range.lowerBound...])
                            break
                        }
                    }
                    
                    Thread.sleep(forTimeInterval: 0.5)
                    
                    if let mp = mountPoint {
                        let openTask = Process()
                        openTask.launchPath = "/usr/bin/open"
                        openTask.arguments = [mp]
                        try? openTask.run()
                        openTask.waitUntilExit()
                    } else {
                        let openTask = Process()
                        openTask.launchPath = "/usr/bin/open"
                        openTask.arguments = ["/Volumes"]
                        try? openTask.run()
                        openTask.waitUntilExit()
                    }
                    
                    DispatchQueue.main.async {
                        completion(true, nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false, "挂载失败: exitCode=\(task.terminationStatus), error=\(errorOutput)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, "执行挂载命令失败: \(error.localizedDescription)")
                }
            }
        }
    }
}
