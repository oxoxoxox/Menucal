import AppKit
import Combine
import Foundation

private enum TestFailure: Error {
    case failed(String)
}

private final class ReleaseStub: URLProtocol {
    struct Response {
        let url: URL
        let status: Int
        let data: Data
        let delay: TimeInterval
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var version = "1.1.2"
        private var offline = false
        private var apiUnavailable = false
        private var count = 0
        private var delay: TimeInterval = 0

        func configure(version: String = "1.1.2", offline: Bool = false, apiUnavailable: Bool = false, delay: TimeInterval = 0) {
            lock.lock()
            defer { lock.unlock() }
            self.version = version
            self.offline = offline
            self.apiUnavailable = apiUnavailable
            self.delay = delay
        }

        func reset() {
            configure()
            lock.lock()
            count = 0
            lock.unlock()
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func respond(to request: URLRequest) -> Response {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            let isAPI = request.url!.host == "api.github.com"
            if offline || (isAPI && apiUnavailable) {
                return Response(url: request.url!, status: 503, data: Data("{}".utf8), delay: delay)
            }
            let asset = "https://github.com/ervinsae/Menucal/releases/download/v\(version)/Menucal-\(version).dmg"
            let json: [String: Any] = ["tag_name": "v\(version)", "assets": [["browser_download_url": asset]]]
            let url = isAPI ? request.url! : URL(string: "https://github.com/ervinsae/Menucal/releases/tag/v\(version)")!
            return Response(url: url, status: 200, data: try! JSONSerialization.data(withJSONObject: json), delay: delay)
        }
    }

    static let state = State()
    private let responseLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.state.respond(to: request)
        if response.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [weak self] in
                self?.deliver(response)
            }
        } else {
            deliver(response)
        }
    }

    private func deliver(_ response: Response) {
        responseLock.lock()
        defer { responseLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: response.url, statusCode: response.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        responseLock.lock()
        stopped = true
        responseLock.unlock()
    }
}

@MainActor
@main
struct RegressionTests {
    static var assertions = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure.failed(message) }
        assertions += 1
    }

    static func waitUntil(_ message: String, timeout: TimeInterval = 3, predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try require(predicate(), message)
    }

    static func makeManager(
        defaults: UserDefaults,
        interval: TimeInterval = 0.25,
        startupDelay: TimeInterval = 0.1,
        retryInterval: TimeInterval = 0.15
    ) -> (UpdateManager, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseStub.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        return (UpdateManager(
            defaults: defaults, session: session, currentVersion: "1.1.2",
            automaticCheckInterval: interval, retryInterval: retryInterval, startupDelay: startupDelay
        ), session)
    }

    static func withDefaults(_ operation: (UserDefaults) async throws -> Void) async throws {
        let name = "Ervin.Menucal.Regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        ReleaseStub.state.reset()
        try await operation(defaults)
    }

    static func testQuietHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for hour in 0..<24 {
            let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour))!
            try require(HourlyChimeService.shouldPlayChime(at: date, enabled: true, nighttimeDoNotDisturb: true, calendar: calendar)
                == (hour >= 8 && hour < 22), "quiet hours at \(hour):00")
            try require(HourlyChimeService.shouldPlayChime(at: date, enabled: true, nighttimeDoNotDisturb: false, calendar: calendar),
                "disabling quiet hours restores \(hour):00")
            try require(!HourlyChimeService.shouldPlayChime(at: date, enabled: false, nighttimeDoNotDisturb: false, calendar: calendar),
                "main switch disables \(hour):00")
        }
        for (hour, minute, expected) in [(21, 59, true), (22, 0, false), (23, 59, false), (0, 0, false), (7, 59, false), (8, 0, true)] {
            let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: hour, minute: minute))!
            try require(HourlyChimeService.shouldPlayChime(at: date, enabled: true, nighttimeDoNotDisturb: true, calendar: calendar)
                == expected, "nighttime boundary \(hour):\(minute)")
        }
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 22))!
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        try require(HourlyChimeService.shouldPlayChime(at: date, enabled: true, nighttimeDoNotDisturb: true, calendar: calendar),
            "quiet hours use local time, not a fixed UTC offset")
        print("PASS nighttime boundaries, main switch and time zones")
    }

    static func raster(_ image: NSImage, scale: CGFloat) throws -> NSBitmapImageRep {
        let width = Int(ceil(image.size.width * scale))
        let height = Int(ceil(image.size.height * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }

    static func testDateIcons(bundle: Bundle) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for scale in [CGFloat(1), CGFloat(2)] {
            var renderedDates = Set<Data>()
            for day in 1...31 {
                let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: day))!
                let image = MenuBarDateIconRenderer.image(for: date, calendar: calendar, bundle: bundle)
                try require(image.isTemplate, "day \(day) supports menu bar tinting")
                let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
                try require(bitmaps.contains { $0.pixelsWide == Int(image.size.width) }
                    && bitmaps.contains { $0.pixelsWide == Int(image.size.width * 2) },
                    "day \(day) has bundled 1x and 2x representations independent of OS symbols")
                let bitmap = try raster(image, scale: scale)
                var alpha = Data()
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        alpha.append(UInt8((bitmap.colorAt(x: x, y: y)!.alphaComponent * 255).rounded()))
                    }
                }
                try require(alpha.contains { $0 > 0 }, "day \(day) must render visible pixels at \(scale)x")
                if let native = NSImage(systemSymbolName: "\(day).calendar", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)) {
                    let reference = try raster(native, scale: scale)
                    try require(bitmap.pixelsWide == reference.pixelsWide && bitmap.pixelsHigh == reference.pixelsHigh,
                        "day \(day) retains the original symbol dimensions")
                    var difference: CGFloat = 0
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            difference += abs(bitmap.colorAt(x: x, y: y)!.alphaComponent
                                - reference.colorAt(x: x, y: y)!.alphaComponent)
                        }
                    }
                    try require(difference / CGFloat(bitmap.pixelsWide * bitmap.pixelsHigh) < 0.025,
                        "day \(day) retains the original symbol shape at \(scale)x")
                }
                renderedDates.insert(alpha)
            }
            try require(renderedDates.count == 31, "all 31 dates must have distinct digits at \(scale)x")
        }
        print("PASS all 31 bundled date icons at 1x and 2x")
    }

    static func testPolling() async throws {
        try await withDefaults { defaults in
            let (manager, session) = makeManager(defaults: defaults)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            manager.startAutomaticChecks()
            manager.startAutomaticChecks()
            try await waitUntil("startup checks without opening settings") { manager.lastSuccessfulCheckDate != nil }
            try require(ReleaseStub.state.requestCount == 1, "starting twice creates one polling loop")
            ReleaseStub.state.configure(version: "1.1.3")
            try await waitUntil("a later release is discovered while app stays running") { manager.latestVersion == "1.1.3" }
            try require(manager.updateAvailable, "new release drives the existing brand badge")
            try require(manager.downloadURL?.lastPathComponent == "Menucal-1.1.3.dmg", "new release asset resolves")
            manager.stopAutomaticChecks()
            let count = ReleaseStub.state.requestCount
            try await Task.sleep(nanoseconds: 400_000_000)
            try require(ReleaseStub.state.requestCount == count, "stop cancels future polls")
        }
        print("PASS startup, repeated polling, release badge and stop")
    }

    static func testThrottleAndManualCheck() async throws {
        try await withDefaults { defaults in
            defaults.set(Date(), forKey: "update.lastSuccessfulCheckDate")
            defaults.set("1.1.2", forKey: "update.latestVersion")
            let (manager, session) = makeManager(defaults: defaults, interval: 3600)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            await manager.checkForUpdates(source: .automatic)
            try require(ReleaseStub.state.requestCount == 0, "automatic check respects the one-hour interval")
            ReleaseStub.state.configure(version: "1.1.3")
            await manager.checkForUpdates(source: .manual)
            try require(manager.updateAvailable, "manual check bypasses polling throttle")
            await manager.checkForUpdates(source: .automatic)
            try require(ReleaseStub.state.requestCount == 1, "fresh successful check prevents duplicate requests")
        }
        print("PASS cache throttle and manual check")
    }

    static func testWakeAndCache() async throws {
        try await withDefaults { defaults in
            defaults.set(Date().addingTimeInterval(-7200), forKey: "update.lastSuccessfulCheckDate")
            defaults.set("1.1.3", forKey: "update.latestVersion")
            let (manager, session) = makeManager(defaults: defaults, interval: 3600, startupDelay: 60)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            try require(manager.latestVersion == "1.1.3", "cached badge survives restart")
            manager.startAutomaticChecks()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await waitUntil("wake performs an overdue check before the startup timer") { ReleaseStub.state.requestCount == 1 && !manager.isChecking }
        }
        print("PASS wake catch-up and cached availability")
    }

    static func testRetryAndFallback() async throws {
        try await withDefaults { defaults in
            ReleaseStub.state.configure(offline: true)
            let (manager, session) = makeManager(defaults: defaults)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            manager.startAutomaticChecks()
            try await waitUntil("failed automatic request reaches both API and fallback") { ReleaseStub.state.requestCount >= 2 && !manager.isChecking }
            try require(manager.checkError == nil, "automatic failures do not interrupt the user")
            try require(manager.lastSuccessfulCheckDate == nil, "failed requests do not count as successful checks")
            ReleaseStub.state.configure(version: "1.1.3", apiUnavailable: true)
            try await waitUntil("retry recovers using the GitHub release page") { manager.latestVersion == "1.1.3" }
        }
        print("PASS offline retry and GitHub API fallback")
    }

    static func testOverlappingWakeAndCancellation() async throws {
        try await withDefaults { defaults in
            ReleaseStub.state.configure(version: "1.1.3", delay: 0.3)
            let (manager, session) = makeManager(defaults: defaults, startupDelay: 60)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            manager.startAutomaticChecks()
            for _ in 0..<4 {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            }
            try await waitUntil("overlapping wake starts a request") { manager.isChecking && ReleaseStub.state.requestCount >= 1 }
            manager.stopAutomaticChecks()
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(!manager.isChecking, "stop cancels the active request after overlapping callbacks")
            try require(manager.lastSuccessfulCheckDate == nil && !manager.updateAvailable,
                "a stopped automatic check must not publish or persist its response")
        }
        print("PASS overlapping wake callbacks and active-request cancellation")
    }

    static func testImmediateRestart() async throws {
        try await withDefaults { defaults in
            ReleaseStub.state.configure(delay: 0.3)
            let (manager, session) = makeManager(defaults: defaults, retryInterval: 2)
            defer { manager.stopAutomaticChecks(); session.invalidateAndCancel() }
            manager.startAutomaticChecks()
            try await waitUntil("startup request is in flight") { manager.isChecking && ReleaseStub.state.requestCount == 1 }
            manager.stopAutomaticChecks()
            manager.startAutomaticChecks()
            ReleaseStub.state.configure(version: "1.1.3")
            try await waitUntil("restart keeps its startup schedule instead of the cancelled request's retry", timeout: 0.8) {
                manager.latestVersion == "1.1.3"
            }
        }
        print("PASS immediate stop/start while a request is in flight")
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            throw TestFailure.failed("test resource bundle is required")
        }
        try testQuietHours()
        try testDateIcons(bundle: bundle)
        try await testPolling()
        try await testThrottleAndManualCheck()
        try await testWakeAndCache()
        try await testRetryAndFallback()
        try await testOverlappingWakeAndCancellation()
        try await testImmediateRestart()
        print("PASS \(assertions) regression assertions")
    }
}
