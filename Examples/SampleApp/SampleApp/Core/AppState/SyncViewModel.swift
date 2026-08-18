import Foundation
import Observation
import TrackerCore
import TrackerSync
import os

/// The upload instrument.
///
/// `TrackerSync` is the one target with no visible surface in this app, which meant the only way
/// to find out whether an endpoint worked was to ship an integration and watch a server log. The
/// queue, the batching, the backoff and the 401 teardown were all there and none of it was
/// pressable.
///
/// Deliberately does **not** hold a `SyncConfig` of its own beyond the form: `SyncEngine` owns the
/// configuration once `configure` is called, and a second copy here would be a second answer to
/// "what is this app uploading to".
@MainActor
@Observable
final class SyncViewModel {

    private static let logger = Logger(subsystem: "com.fieldtrack360.tracker.sample", category: "sync")

    // MARK: Form

    /// Left empty on purpose. A default endpoint would be a request this app makes to somebody
    /// else's server on first launch.
    var endpoint = ""

    /// Sent as `Authorization` when non-empty. A 401 from a stale one is worth demonstrating —
    /// it is the only sync outcome that tears the uploader down.
    var bearerToken = ""

    var autoSync = true

    // MARK: State

    /// Read from the engine, never remembered here.
    ///
    /// A local flag was wrong twice over: this screen is created fresh on every navigation, so it
    /// showed NOT CONFIGURED for an engine that was uploading — and a 401 tears the configuration
    /// down without the screen doing anything, so even a persisted flag would drift.
    private(set) var isConfigured = false

    /// What the engine is actually sending to, as opposed to what is typed in the form above.
    /// The two differ the moment a host edits the field without pressing Configure, and the
    /// screen has to be able to say which is live.
    private(set) var configuredEndpoint: URL?

    private(set) var pending: Int?
    private(set) var lastResult: String?
    private(set) var feed: [String] = []

    @ObservationIgnored private var eventTask: Task<Void, Never>?

    private static let feedLimit = 60

    // MARK: - Lifecycle

    /// Idempotent — `TabView` and `NavigationStack` both re-run a `.task` on reappearance, and a
    /// second subscription would double every line in the feed.
    func onAppear() async {
        await self.refreshPending()

        // Prefilled from the engine, so returning to this screen shows the endpoint in force
        // rather than an empty field beside a CONFIGURED badge.
        if self.endpoint.isEmpty, let live = self.configuredEndpoint {
            self.endpoint = live.absoluteString
        }
        guard self.eventTask == nil else { return }
        self.eventTask = Task { [weak self] in
            for await event in SyncEngine.shared.events() {
                await self?.handle(event)
            }
        }
    }

    // MARK: - Commands

    /// Hands the endpoint to the engine along with the SDK's own queue.
    ///
    /// `Tracker.shared.pendingUploads` is the seam that keeps the dependency pointing one way:
    /// `TrackerCore` never imports `TrackerSync`, so the uploader is given the store rather than
    /// reaching for it.
    func configure() async {
        guard let url = URL(string: self.endpoint), url.scheme != nil, url.host != nil else {
            self.lastResult = "not a URL: \(self.endpoint)"
            return
        }

        var config = SyncConfig(url: url)
        config.autoSync = self.autoSync
        if !self.bearerToken.isEmpty {
            config.headers["Authorization"] = "Bearer \(self.bearerToken)"
        }

        SyncEngine.shared.configure(config, store: Tracker.shared.pendingUploads)
        self.readConfiguration()
        self.lastResult = "configured for \(url.absoluteString)"
        self.record("CONFIG", url.absoluteString)
        await self.refreshPending()
    }

    /// Drains now and reports what happened.
    ///
    /// `syncNow()` awaits the outcome, unlike `requestSync()`, which is why the button can say
    /// what the server did rather than only that it was asked.
    func syncNow() async {
        guard self.isConfigured else {
            self.lastResult = "configure an endpoint first"
            return
        }

        switch await SyncEngine.shared.syncNow() {
        case .uploaded(let count):
            self.lastResult = "uploaded \(count)"
        case .empty:
            self.lastResult = "nothing queued"
        case .retry(let reason):
            self.lastResult = "retry — \(reason)"
        case .authExpired:
            self.lastResult = "401 — uploader torn down"
        @unknown default:
            self.lastResult = "unrecognised result"
        }

        await self.refreshPending()
    }

    /// Fire-and-forget, coalesced by the engine. The other half of the manual trigger, shown so a
    /// host can see there are two and why they differ.
    func requestSync() {
        guard self.isConfigured else {
            self.lastResult = "configure an endpoint first"
            return
        }
        SyncEngine.shared.requestSync()
        self.lastResult = "sync requested"
    }

    func refreshPending() async {
        self.readConfiguration()
        switch await SyncEngine.shared.pendingCount() {
        case .success(let count):
            self.pending = count
        case .failure(_, let message):
            self.pending = nil
            self.lastResult = message
        @unknown default:
            self.pending = nil
        }
    }

    /// The engine's state, never this screen's memory of it.
    ///
    /// Re-read on every refresh because a 401 tears the configuration down between one look at
    /// this screen and the next, with nothing the host did to cause it.
    private func readConfiguration() {
        self.configuredEndpoint = SyncEngine.shared.endpoint
        self.isConfigured = SyncEngine.shared.isConfigured
    }

    // MARK: - Events

    private func handle(_ event: SyncEvent) async {
        switch event {
        // The case this screen exists for. A 500, a 422 and a timeout produce the same retry,
        // and only the status tells a host which of the three it is looking at.
        case .httpResponse(let statusCode, let count):
            let status = statusCode.map(String.init) ?? "no response"
            self.record("HTTP", "\(status) for \(count) point\(count == 1 ? "" : "s")")

        case .uploaded(let count):
            self.record("UPLOADED", "\(count)")
            await self.refreshPending()

        case .retryScheduled(let afterSec, let reason):
            self.record("RETRY", "in \(Int(afterSec))s — \(reason)")

        case .authExpired:
            // Terminal, and the only event a host must act on: refresh belongs to the auth stack.
            self.record("AUTH", "401 — configuration torn down")
            self.readConfiguration()

        @unknown default:
            self.record("EVENT", "unrecognised")
        }
    }

    private func record(
        _ kind: String,
        _ detail: String
    ) {
        let stamp = Self.time.string(from: Date())
        self.feed.insert("\(stamp)  \(kind)  \(detail)", at: 0)
        if self.feed.count > Self.feedLimit {
            self.feed.removeLast(self.feed.count - Self.feedLimit)
        }
        Self.logger.debug("\(kind, privacy: .public) \(detail, privacy: .public)")
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
