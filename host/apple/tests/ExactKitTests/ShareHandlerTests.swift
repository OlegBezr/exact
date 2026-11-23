// LLP 1133.024 D4 (amended 2026-11-22), D9: the share handler's outcomes in the
// iOS confirmation, through a stub extension context. The handler here is a
// stand-in that answers as the app's source would; the runtime that runs the
// app's source is tested in `host/apple/src/abi_entry_tests.rs` and
// `js/tests/it/snapshot.rs`.
#if canImport(UIKit)
import Foundation
import UIKit
import XCTest
@testable import ExactShare

private final class HandlerContext: NSExtensionContext {
    var items: [Any] = []
    var completed = false
    var cancelled: Error?
    override var inputItems: [Any] { items }
    override func completeRequest(returningItems: [Any]?, completionHandler: ((Bool) -> Void)? = nil) { completed = true }
    override func cancelRequest(withError error: Error) { cancelled = error }
}

final class ShareHandlerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("share-handler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    /// An app that maps `text` alone, as the issue's league app does, with a member for pictures.
    private let info = ShareTargetInfo(group: "group.com.exact.test", appId: "com.exact.test", mapped: ["text"], members: [(name: "images", types: ["public.image"])])

    private func item(_ text: String, link: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: text)
        item.attachments = link.map { [NSItemProvider(object: URL(string: $0)! as NSURL)] } ?? []
        return item
    }

    /// The controller over `items`, its handler answering `reply` (none: never), and what the handler was asked.
    private func confirm(_ items: [NSExtensionItem], bound: TimeInterval = 30, reply: ShareReply?) -> (ExactShareConfirmationViewController, HandlerContext, () -> [[String: String]]) {
        let context = HandlerContext()
        context.items = items
        var asked: [[String: String]] = []
        let confirmation = ExactShareConfirmationViewController()
        confirmation.info = info
        confirmation.container = scratch
        confirmation.stubContext = context
        confirmation.handleBound = bound
        confirmation.handle = { members, _, answer in
            asked.append(members)
            if let reply { DispatchQueue.main.async { answer(reply) } }
        }
        _ = confirmation.view
        confirmation.viewDidAppear(false)
        return (confirmation, context, { asked })
    }

    private func inbox() throws -> [String] {
        let shares = scratch.appendingPathComponent("shares")
        guard FileManager.default.fileExists(atPath: shares.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: shares.path)
    }

    /// Nothing is left in staging however the share ended.
    private func staged() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("share-handler").path)) ?? []
    }

    /// `done`: the handler gets the members as the `action` route would (a link joins the text when `url` is not
    /// mapped), the checkmark shows with its line under the name, nothing reaches the inbox, and the request
    /// completes.
    func testDoneShowsTheLineAndSavesNothing() throws {
        let (confirmation, context, asked) = confirm([item("Puzzle 0:39", link: "https://league.test/p/1")], reply: .done("Ranked 2 of 4"))
        waitFor("the checkmark") { confirmation.confirmed }
        XCTAssertEqual(asked(), [["text": "Puzzle 0:39\nhttps://league.test/p/1"]])
        XCTAssertEqual(confirmation.line, "Ranked 2 of 4")
        XCTAssertEqual(try inbox(), [])
        XCTAssertEqual(staged(), [])
        waitFor("the request's completion", late: 4) { context.completed }
        XCTAssertNil(context.cancelled)
    }

    /// `refused`: an alert's error carries the line, the request is cancelled with it, and nothing is saved.
    func testRefusedCancelsWithTheLine() throws {
        let (confirmation, context, _) = confirm([item("hello")], reply: .refused("That isn't a puzzle result."))
        waitFor("the cancel") { context.cancelled != nil }
        XCTAssertFalse(confirmation.confirmed)
        XCTAssertEqual(context.cancelled?.localizedDescription, "That isn't a puzzle result.")
        XCTAssertEqual(try inbox(), [])
        XCTAssertEqual(staged(), [])
    }

    /// `open`, which a throw and an unrunnable generation also are (`ShareHandler.run`): the share is in the inbox,
    /// as without a handler, and the checkmark shows with no line.
    func testOpenPutsTheShareInTheInbox() throws {
        let (confirmation, context, _) = confirm([item("Puzzle 0:39")], reply: .open)
        waitFor("the checkmark") { confirmation.confirmed }
        XCTAssertNil(confirmation.line)
        let shares = try inbox()
        XCTAssertEqual(shares.count, 1)
        let data = try Data(contentsOf: scratch.appendingPathComponent("shares/\(shares[0])/share.json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String, "Puzzle 0:39")
        XCTAssertEqual(staged(), [])
        waitFor("the request's completion") { context.completed }
    }

    /// A handler that does not answer within the bound: the share goes to the inbox, and a late answer changes
    /// nothing.
    func testAHandlerPastItsBoundOpensTheShare() throws {
        var late: ((ShareReply) -> Void)?
        let context = HandlerContext()
        context.items = [item("Puzzle 0:39")]
        let confirmation = ExactShareConfirmationViewController()
        confirmation.info = info
        confirmation.container = scratch
        confirmation.stubContext = context
        confirmation.handleBound = 0.3
        confirmation.handle = { _, _, answer in late = answer }
        _ = confirmation.view
        confirmation.viewDidAppear(false)
        waitFor("the checkmark") { confirmation.confirmed }
        XCTAssertEqual(try inbox().count, 1)
        late?(.done("too late"))
        waitForMainQueue()
        XCTAssertNil(confirmation.line)
        XCTAssertEqual(try inbox().count, 1)
    }

    /// A share with a file goes to the inbox without asking the handler, which takes no files.
    func testAShareWithAFileSkipsTheHandler() throws {
        let picture = scratch.appendingPathComponent("p.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: picture)
        let shared = item("Look")
        shared.attachments = [NSItemProvider(contentsOf: picture)!]
        let (confirmation, _, asked) = confirm([shared], reply: .done("taken"))
        waitFor("the checkmark") { confirmation.confirmed }
        XCTAssertEqual(asked(), [])
        XCTAssertEqual(try inbox().count, 1)
    }

    /// Dismissed while the handler runs: nothing is kept, the request is cancelled, and the answer is ignored.
    func testDismissingWhileTheHandlerRunsKeepsNothing() throws {
        let (confirmation, context, asked) = confirm([item("Puzzle 0:39")], reply: nil)
        waitFor("the handler's question") { !asked().isEmpty }
        confirmation.viewDidDisappear(false)
        XCTAssertTrue(confirmation.saveEnded)
        XCTAssertEqual((context.cancelled as? CocoaError)?.code, .userCancelled)
        XCTAssertEqual(try inbox(), [])
        XCTAssertEqual(staged(), [])
    }

    /// The members are the route's: `title` and `text` only when mapped, and a link in `url` when it is mapped.
    func testMembersAreWhatTheRouteReceives() {
        let record: [String: Any] = ["title": "Trip", "text": "Bring water", "url": "https://x.test/a"]
        XCTAssertEqual(ShareHandler.members(of: record, mapped: ["title", "text", "url"]), ["title": "Trip", "text": "Bring water", "url": "https://x.test/a"])
        XCTAssertEqual(ShareHandler.members(of: ["text": "See https://x.test/a", "url": "https://x.test/a"], mapped: ["text"]), ["text": "See https://x.test/a"])
        XCTAssertEqual(ShareHandler.members(of: ["url": "https://x.test/a"], mapped: ["text"]), ["text": "https://x.test/a"])
        XCTAssertEqual(ShareHandler.members(of: ["url": "https://x.test/a"], mapped: ["title"]), [:])
    }
}
#endif
