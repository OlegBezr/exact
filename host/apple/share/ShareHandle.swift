// @ref LLP 1133.024 D4, amended 2026-11-22 — the share handler: the data
// source `share_target.handle` names, run headless on a share before it goes
// to the inbox, on the runtime a widget's refresh uses (LLP 1126 D8). The bake
// compiles this file, under EXACT_SHARE_HANDLE, only for an app that names a
// handler, and links the app's ExactCore with it; an app with none gets the
// extension ShareInbox.swift and its presentation make alone.
//
// The share is written as the confirmation writes it (ShareConfirmation.swift),
// but into a staging container in the App Group, where the app's claim does not
// look. The handler then decides: `done` and `refused` remove it, and `open`
// (a throw, the bound, no generation) moves it into the inbox by a rename.
#if EXACT_SHARE_HANDLE
import ExactCore
import ExactSnapshot
import Foundation
import os

/// What the handler answered.
public enum ShareReply: Equatable {
    /// Taken: the checkmark with the line under it, and nothing in the inbox.
    case done(String?)
    /// Not taken: an alert with the line, and nothing saved.
    case refused(String?)
    /// The inbox and the app's `action` route, as without a handler.
    case open
}

/// Asks the handler about a share's members and answers on the main queue, once. `withdrawn` says, from any thread,
/// that the share no longer waits for it (the person dismissed the sheet, or it went to the inbox): a handler that has
/// not started then does not.
public typealias ShareHandling = (_ members: [String: String], _ withdrawn: @escaping () -> Bool, _ answer: @escaping (ShareReply) -> Void) -> Void

/// How a handled share ended, for the controller to show.
public enum ShareHandled {
    /// In the inbox: the checkmark as without a handler.
    case saved
    /// Taken by the handler: the checkmark and its line.
    case taken(String?)
    /// Refused by the handler, or not saved: an alert with the error.
    case failed(Error)
}

/// The app's handler as the extension runs it: the share entry's plan (`plans/share.plan`) booted headless from the
/// extension's own copy of the build's plans and TypeScript module, never a generation the app published, so an
/// update to the app's code reaches the handler with the next binary. Fetches go out under the app's grants,
/// `secret.keep` values are read from the shared Keychain group, and a store write ends the run as a failure (the
/// runner's refresh rule).
public struct ShareHandler {
    /// From the start of the boot to the answer: LLP 1111's bound for a call into an app's code.
    public static let bound: TimeInterval = 10
    private static let queue = DispatchQueue(label: "exact.share-handler", qos: .userInitiated)
    /// The group's environment is set once, before the session reads it.
    private static let configured: Void = WidgetContainer.configure()
    static let log = Logger(subsystem: "dev.exact.share", category: "handler")
    /// Where the plans and module are; nil for the extension's resources.
    public var root: URL?

    public init(root: URL? = nil) { self.root = root }

    /// The handler this extension was built for, or nil when the app names none.
    public init?(bundle: Bundle) {
        guard bundle.object(forInfoDictionaryKey: "ExactShareHandle") is String else { return nil }
        self.init()
    }

    /// Runs the handler on `members` off the main queue, within `bound` of this call; `answer` runs on main. Anything
    /// but an answer of `done` or `refused` is `open`, and a share withdrawn before the handler starts is not handed
    /// to it.
    public func run(_ members: [String: String], withdrawn: @escaping () -> Bool, answer: @escaping (ShareReply) -> Void) {
        let deadline = DispatchTime.now() + .milliseconds(Int(Self.bound * 1000))
        Self.queue.async {
            guard !withdrawn() else { return DispatchQueue.main.async { answer(.open) } }
            let reply = autoreleasepool { () -> ShareReply in
                _ = Self.configured
                let root = self.root ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
                #if EXACT_INSPECT
                let probe = ShareProbe.begin()
                var outcome = "open"
                defer { probe.finish(members, outcome: outcome) }
                #endif
                do {
                    let plan = try Data(contentsOf: root.appendingPathComponent("plans/share.plan"))
                    let session = try HeadlessSession(plan: plan, entry: "share", size: CGSize(width: 1, height: 1),
                                                      facts: SessionFacts(displayScale: 2, preferences: .platformInput, date: Date()), assetRoot: root)
                    defer { session.close() }
                    let typescript = Bundle.main.object(forInfoDictionaryKey: "ExactWidgetTypeScript") as? Bool == true
                    let bytes = try session.share(try JSONSerialization.data(withJSONObject: members), moduleRoot: typescript ? root : nil, deadline: deadline)
                    let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    let message = (object?["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    #if EXACT_INSPECT
                    outcome = object?["outcome"] as? String ?? "open"
                    #endif
                    switch object?["outcome"] as? String {
                    case "done": return .done(message)
                    case "refused": return .refused(message)
                    default: return .open
                    }
                } catch {
                    #if EXACT_INSPECT
                    outcome = "failed: \(error)"
                    #endif
                    Self.log.error("share handler: \(String(describing: error), privacy: .private)")
                    return .open
                }
            }
            DispatchQueue.main.async { answer(reply) }
        }
    }

    /// The members the `action` route receives for `record` (the inbox's `share.json`), under their member names, as
    /// the runner's share location composes them (`exact_runner::picker::shared::location`): `title` and `text`
    /// only when mapped, which the record already is, and a link in `text` when `url` is not mapped.
    public static func members(of record: [String: Any], mapped: Set<String>) -> [String: String] {
        let title = record["title"] as? String, url = record["url"] as? String
        var text = record["text"] as? String
        if !mapped.contains("url"), let url {
            text = text.map { $0.contains(url) ? $0 : "\($0)\n\(url)" } ?? url
        }
        var members: [String: String] = [:]
        for (name, value) in [("title", title), ("text", text), ("url", url)] where mapped.contains(name) {
            members[name] = value
        }
        return members
    }
}

/// One share through the handler: written to staging, handed to the handler, then removed or moved into the inbox.
/// Its steps run on the main queue.
public final class HandledShare {
    private let info: ShareTargetInfo
    private let inbox: URL
    private let staging: URL
    private var save: ShareSave?
    private var timer: DispatchWorkItem?
    /// `ended`, as the handler's queue reads it.
    private let lock = NSLock()
    private var over = false
    private var done: ((ShareHandled) -> Void)?
    /// Whether it is over: shown, failed, or withdrawn.
    public private(set) var ended = false

    private init(info: ShareTargetInfo, inbox: URL, done: @escaping (ShareHandled) -> Void) {
        self.info = info
        self.inbox = inbox
        staging = inbox.appendingPathComponent("share-handler", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.done = done
    }

    /// Takes `items` as the confirmation does, then asks `handle` and waits for it at most `bound` seconds: past it the
    /// share goes to the inbox. `container` is the App Group's when nil. A share with files goes to the inbox
    /// without the handler, which takes none.
    public static func start(_ items: [NSExtensionItem], info: ShareTargetInfo?, container: URL?, handle: @escaping ShareHandling,
                             bound: TimeInterval = ShareHandler.bound + 1, done: @escaping (ShareHandled) -> Void) -> HandledShare? {
        guard let info, let inbox = container ?? ShareInboxWriter.container(info) else { return nil }
        let share = HandledShare(info: info, inbox: inbox, done: done)
        share.removeAbandoned()
        // Staging is a container of its own, and its writer pings a name no app observes: the inbox's ping, which
        // Darwin may coalesce with the next, is the commit's alone.
        let staged = ShareTargetInfo(group: info.group, appId: "\(info.appId).share-handler", mapped: info.mapped, members: info.members)
        share.save = ShareInboxWriter.save(items, info: staged, container: share.staging) { [weak share] error in
            guard let share else { return }
            if let error { return share.end(.failed(error)) }
            // A share that brought a file, kept or dropped, is the app's to see: the handler takes none.
            guard let record = share.record(), (record["files"] as? [Any])?.isEmpty != false,
                  (record["dropped"] as? [String: Any])?.isEmpty != false else { return share.commit() }
            let members = ShareHandler.members(of: record, mapped: info.mapped)
            let timer = DispatchWorkItem { [weak share] in share?.commit() }
            share.timer = timer
            // The runtime ends a source at its bound; this catches a boot that never returns. The probe's ramp runs
            // until iOS ends the extension, so it is not cut short.
            #if EXACT_INSPECT
            let ramp = members["text"] == ShareProbe.ramp
            #else
            let ramp = false
            #endif
            if !ramp { DispatchQueue.main.asyncAfter(deadline: .now() + bound, execute: timer) }
            handle(members, { [weak share] in share?.isOver ?? true }) { [weak share] reply in
                guard let share, !share.ended else { return }
                switch reply {
                case .done(let message): share.end(.taken(message))
                case .refused(let message):
                    share.end(.failed(NSError(domain: "exact.share", code: 7, userInfo: [NSLocalizedDescriptionKey: message ?? "The share was not accepted."])))
                case .open: share.commit()
                }
            }
        }
        return share
    }

    /// The share is gone before it ended: nothing is kept, and `done` does not run.
    public func withdraw() {
        guard !ended else { return }
        save?.withdraw()
        done = nil
        end(nil)
    }

    /// Removes what a run that ended without an answer left in staging (iOS ended the extension): nothing was shown
    /// for it, so nothing is kept. A run in progress is younger than an hour.
    private func removeAbandoned() {
        let base = staging.deletingLastPathComponent(), stale = Date().addingTimeInterval(-3600)
        for run in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey])) ?? []
        where (try? run.resourceValues(forKeys: [.creationDateKey]).creationDate).flatMap({ $0 < stale }) ?? false {
            try? FileManager.default.removeItem(at: run)
        }
    }

    private var written: URL? {
        (try? FileManager.default.contentsOfDirectory(at: staging.appendingPathComponent("shares"), includingPropertiesForKeys: nil))?.first
    }

    private func record() -> [String: Any]? {
        guard let share = written, let data = try? Data(contentsOf: share.appendingPathComponent("share.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Moves the written share into the inbox, by a rename in the one container, and pings the app.
    private func commit() {
        guard !ended else { return }
        do {
            guard let share = written else { throw CocoaError(.fileNoSuchFile) }
            let shares = inbox.appendingPathComponent("shares", isDirectory: true)
            try FileManager.default.createDirectory(at: shares, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: share, to: shares.appendingPathComponent(share.lastPathComponent, isDirectory: true))
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName("\(info.appId).shares" as CFString), nil, nil, true)
            end(.saved)
        } catch {
            end(.failed(NSError(domain: "exact.share", code: 6, userInfo: [NSLocalizedDescriptionKey: "Nothing in the share could be saved."])))
        }
    }

    private var isOver: Bool {
        lock.lock(); defer { lock.unlock() }
        return over
    }

    private func end(_ outcome: ShareHandled?) {
        guard !ended else { return }
        ended = true
        lock.lock(); over = true; lock.unlock()
        timer?.cancel()
        try? FileManager.default.removeItem(at: staging)
        if let outcome { done?(outcome) }
        done = nil
    }
}

#if EXACT_INSPECT
/// The device measurement of LLP 1133.024 §20 stage 9 (S0), in a development build: the limit the extension is held
/// to (`os_proc_available_memory` at the start, plus the footprint then; zero where no limit applies, as on the
/// simulator), and the footprint's peak through the handler's boot and answer, written to
/// `<App Group>/share-probe/run.json`. A share whose text is `exact-share-probe:ramp` then allocates 1 MiB every
/// 50 ms until iOS ends the process, rewriting `ramp.json` at each step, as LLP 1126.000 §1.4 measured a widget's
/// ceiling: its last footprint is the ceiling, to a MiB.
private struct ShareProbe {
    let start = DispatchTime.now()
    let limit = Self.available() + Self.footprint().now
    let before = Self.footprint().now

    /// What the process may still allocate before iOS ends it; zero where no limit is kept.
    static func available() -> UInt64 {
        #if os(iOS)
        UInt64(os_proc_available_memory())
        #else
        0
        #endif
    }

    static func begin() -> ShareProbe { ShareProbe() }
    /// The shared text that starts the ramp.
    static let ramp = "exact-share-probe:ramp"

    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, max(info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak))))
    }

    private static var directory: URL? {
        WidgetContainer.root.map { $0.appendingPathComponent("share-probe", isDirectory: true) }
    }

    private static func write(_ name: String, _ object: [String: Any]) {
        guard let directory, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func finish(_ members: [String: String], outcome: String) {
        let (now, peak) = Self.footprint(), mib = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let run: [String: Any] = ["limitMiB": mib(limit), "startMiB": mib(before), "peakMiB": mib(peak), "endMiB": mib(now), "ms": ms, "outcome": outcome]
        ShareHandler.log.notice("share probe \(String(describing: run), privacy: .public)")
        Self.write("run.json", run)
        guard members["text"] == Self.ramp else { return }
        var held: [UnsafeMutableRawPointer] = []
        while true {
            let block = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
            block.initializeMemory(as: UInt8.self, repeating: 1, count: 1 << 20)
            held.append(block)
            let footprint = Self.footprint().now
            Self.write("ramp.json", ["footprintMiB": mib(footprint), "availableMiB": mib(Self.available()), "steps": held.count])
            usleep(50_000)
        }
    }
}
#endif
#endif
