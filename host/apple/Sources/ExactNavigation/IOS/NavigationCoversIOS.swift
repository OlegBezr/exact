// @ref LLP 1075.003 §3.5 — what Exact's containers cover of each route, told
// to the kernel as covers, and the development check of what Exact owns on
// the objects it handed a hatch.
#if os(iOS) || os(tvOS)
import UIKit
import ExactKit

extension NavigationHost {
    // MARK: The content area (LLP 1075.003 §3.5)

    /// Whether the root's routes have a native primary container (a stack
    /// or the tabs), so the session's view takes the whole of its own
    /// (ExactViewIOS `fit`): the document and the window the viewport units
    /// resolve against. Its bars, whether shown or not, and a
    /// presentation's containers never decide it (LLP 1123 D1); its routes
    /// clear what covers them (`reportCovers`). Not under the agent's own
    /// chrome, where no native container shows.
    var wantsWholeView: Bool { (primaryOwner != nil || bootOwner != nil) && !ExactEnv.authoredChrome }

    /// @ref LLP 1075.003 §3.7, LLP 1083.000 D4 — the native container stands
    /// for the routes in the navigation root's paint order. Its box can extend
    /// past the routes' authored boxes: a column the author placed beside
    /// routes offset past it shows on the web and would be covered here. A
    /// child of the root beside the routes, which they therefore paint nothing
    /// over (`PanelSiblings.beside`: no shown route's box meets it, and no
    /// route's view covers it except to its side), paints over the container;
    /// one a route's box meets keeps CSS's order under it. A child with no
    /// area is decided by the box its children paint over, within what clips
    /// them, and one with a `clip-path` by its own (`paintedBox`).
    /// The tab panels and a tablist replaced by the native bar are the
    /// container's own. Such a child that reaches the container's top edge
    /// and one side (a column) grows the container's safe area on that side
    /// by its width, so UIKit lays the bars' contents out clear of it, as a
    /// hand-built screen insets its bars from a view beside them; the routes
    /// clear only the part of that inset their own boxes reach
    /// (`reportCovers`). With the tab bar hidden, an in-flow row below the
    /// panels bounds the bottom too, whether the root's child or nested beside
    /// them. A node nested beside the panels that paints over the container is
    /// lifted into a layer just after it (`panelSiblings`, LLP 1083.000 D4),
    /// and one that reaches the top edge and one side grows the safe area as a
    /// root child does.
    func clearBesideRoutes(tabBarHidden: Bool? = nil) {
        guard let owner = primaryOwner, let root = container, let holder = owner.viewIfLoaded,
              holder.superview === ownerMount(root) else { return }
        // Each shown route's box where CSS lays it out, within its logical parent (UIKit holds a tab's route at its
        // container's origin, sized to the page, which leaves out the panel's place; a parent with no box of its
        // own leaves the frame as it is), and where its view is drawn
        let shown = primaryRoutes.filter { $0.viewIfLoaded?.window != nil && presenter.views[$0.node.id] === $0.node }
        let routes = shown.map { c in
            let parent = logicalParent(of: c.node) ?? root
            let frame = parent.container.convert(c.node.frame, to: root), within = frame.intersection(parent.convert(parent.bounds, to: root))
            return within.isEmpty ? frame : within
        }.filter { !$0.isEmpty }
        let drawn = shown.map { $0.node.convert($0.node.bounds, to: root) }.filter { !$0.isEmpty }
        let owned = Set(tabPanels + (tablistAppearanceNone ? [] : [adoptedTablist].compactMap { $0 }))
        let area = holder.convert(holder.bounds, to: root)
        let before = besideOwner === owner ? besideInsets : .zero
        var changed = false, reach = UIEdgeInsets.zero
        siblings.place(in: ownerMount(root))
        var walk = panelSiblings(in: area, routes: routes, drawn: drawn, skipping: owned, hidden: tabBarHidden)
        if !walk.promote.isEmpty {
            // A flat leaf that paints over the container gets a view, mounted now, and lifts with the rest
            for id in walk.promote { presenter.flats.promote(id) }
            presenter.flats.flush()
            walk = panelSiblings(in: area, routes: routes, drawn: drawn, skipping: owned, hidden: tabBarHidden)
        }
        let (bottom, rows, lifts) = (walk.bottom, walk.rows, walk.lifts)
        #if os(iOS)
        // The adopted More on screen at its list, as its stack names it from the start of a pop to it (reading
        // `moreNavigationController` makes a More where UIKit has none); not the tab controller's selection, which
        // names More only after More's `didShow` for its pop to the list
        let moreList = more.map { $0.viewIfLoaded?.window != nil && $0.topViewController === $0.viewControllers.first } ?? false
        #else
        let moreList = false
        #endif
        // With no route in the window, under a full-screen cover, the last decision stands, as the covers do;
        // More's list, inside the container, shows no route for a node to be beside, so it lifts nothing
        if !routes.isEmpty || moreList { siblings.apply(lifts, in: ownerMount(root), after: holder) }
        // A lifted column beside the routes; one over them, an overlay, insets nothing, as CSS moves nothing for it
        for lift in lifts {
            let box = paintedBox(lift.node, in: root)
            guard box.minY <= area.minY + 0.5, PanelSiblings.beside(box, routes, drawn: drawn) else { continue }
            let left = box.minX <= area.minX + 0.5, right = box.maxX >= area.maxX - 0.5
            if left, !right { reach.left = max(reach.left, box.maxX - area.minX) }
            if right, !left { reach.right = max(reach.right, area.maxX - box.minX) }
        }
        for case let child as NodeView in ownerMount(root).subviews {
            let box = paintedBox(child, in: root)
            let below = rows.contains { $0 === child }
            let clears = !ExactEnv.authoredChrome && !routes.isEmpty && !owned.contains(child.id) && !box.isEmpty
                && box.intersects(area) && (below || PanelSiblings.beside(box, routes, drawn: drawn))
            if child.clearsNavigation != clears {
                child.clearsNavigation = clears
                changed = true
            }
            guard clears, box.minY <= area.minY + 0.5 else { continue }
            let left = box.minX <= area.minX + 0.5, right = box.maxX >= area.maxX - 0.5
            if left, !right { reach.left = max(reach.left, box.maxX - area.minX) }
            if right, !left { reach.right = max(reach.right, area.maxX - box.minX) }
        }
        // UIKit already supplies the indicator and any inset inherited from an outer container.
        reach.bottom = max(0, bottom - max(0, holder.safeAreaInsets.bottom - before.bottom))
        if changed { PaintOrder.changed(ownerMount(root)) }
        // Exact's part only: what an app's hatch set on its container stays
        let now = owner.additionalSafeAreaInsets
        let wanted = UIEdgeInsets(top: now.top - before.top + reach.top, left: now.left - before.left + reach.left,
                                  bottom: now.bottom - before.bottom + reach.bottom, right: now.right - before.right + reach.right)
        besideInsets = reach
        besideOwner = owner
        if now != wanted { owner.additionalSafeAreaInsets = wanted }
    }

    /// What a route's padding clears of its controller's safe area (`safe`),
    /// its local inset on each edge it executes (LLP 1123 D3): the kernel
    /// adds it to the route's authored padding, or credits a padding that
    /// reads the inset, and turns off an edge the route opts out of (D4).
    /// The top is a collapsing title's scroller's when it has one; the sides
    /// and the bottom only while the containers take the whole view
    /// (`whole`) or the page covers it (`covered`, `viewport-fit="cover"`),
    /// and the bottom only as far as the route reaches it.
    static func routeEdges(safe: UIEdgeInsets, whole: Bool, covered: Bool = false, collapses: Bool, reached: CGFloat) -> HostCover.Edges {
        let edges = whole || covered
        return .init(top: collapses ? 0 : max(0, safe.top),
                     right: edges ? max(0, safe.right) : 0,
                     bottom: edges ? max(0, min(safe.bottom, reached)) : 0,
                     left: edges ? max(0, safe.left) : 0)
    }

    /// What covers `node` but for `kept`, which stays in the page: the node
    /// itself, or, where it holds any of `kept`, each part of it that holds
    /// none (host/painted/src/bars.rs `covered`).
    static func covered(_ node: NodeView, keeping kept: [NodeView]) -> [NodeView] {
        guard kept.contains(where: { $0.isDescendant(of: node) }) else { return [node] }
        return node.container.subviews.compactMap { $0 as? NodeView }
            .filter { child in !kept.contains { $0 === child } }
            .flatMap { child in kept.contains { $0.isDescendant(of: child) } ? covered(child, keeping: kept) : [child] }
    }

    /// Whether `sv` is pulled past where its title's inset rests (`origin`),
    /// as to refresh. UIKit grows the scroller's safe area with the pull, and
    /// with the refresh control's room while it shows, and gives it back as
    /// the list returns: neither is the bar's inset, where CSS scrollTop 0
    /// rests, and a hand-built list lays out nothing for it. Reported, each
    /// frame of a pull laid the page out again.
    static func stretched(_ sv: UIScrollView, origin: CGFloat) -> Bool {
        origin > 0 && sv.contentOffset.y < -origin - 0.5
    }

    /// The navigation controller a pop is taking `c` from, while UIKit's
    /// transition runs.
    private func leavingNavigation(of c: RouteController) -> UINavigationController? {
        (primaryStacks.compactMap { $0 as? UINavigationController } + presenter.modals.navigations).lazy
            .first { $0.transitionCoordinator?.viewController(forKey: .from) === c }
    }

    /// What Exact's containers cover of each route — its controller's safe
    /// area: a shown bar's top, and every edge while the containers take the
    /// whole view — and the header a bar replaces, reported when they change,
    /// after the batch being applied.
    func reportCovers() {
        // An image's extension grows with the safe areas it meets.
        defer { for image in presenter.carrying("backgroundExtension") { image.syncBackgroundExtension() } }
        clearBesideRoutes()
        var changes: [(UInt32, HostCover?)] = []
        var wanted: [UInt32: HostCover] = [:]
        var owners: [UInt32: OwnerReport] = [:]
        for c in controllers.values where presenter.views[c.node.id] === c.node {
            // A lifted header takes no room, on a stack yet or not (`coverLifted`).
            for node in (c.lifted.map({ [$0] }) ?? c.barNodes) + [c.scoped].compactMap({ $0 }) { wanted[node.id] = .whole }
            // Include the departing route until UIKit finishes its transition:
            // a pop has taken it from its controller (`navigationController`
            // is nil), and a swipe back still shows it beside the one beneath.
            let nav = c.navigationController ?? leavingNavigation(of: c)
            let stacked = c.stack?.shownStackRoutes.contains(c) == true || nav?.transitionCoordinator?.viewController(forKey: .from) === c
            guard stacked else { continue }
            // A presented route's controller takes its sheet's whole view, and
            // the document's insets (`env()`) are not the sheet's: its route is
            // covered for its own safe area whatever the document's fit (LLP
            // 1123 D2; its own clearance and credit are stage 2's)
            let presented = isPresented(nav)
            let covered = wantsWholeView && presenter.viewportFit == "cover"
            let whole = presented || (wantsWholeView && !covered)
            let shows = nav.map(barShows) ?? !ExactEnv.authoredChrome
            guard shows || whole else { continue }
            var edges: HostCover.Edges?
            // What the route clears, its values' content root (`ownerReports`)
            var ownerClearance: HostCover.Edges?
            // A collapsing title's scroller goes under the bar, which insets it;
            // its expanded inset is where CSS scrollTop 0 rests.
            // While the bar is not as the route wants it (mid-transition to or
            // from a route without one, §9.10), or the route is not in a window
            // (a tab UIKit has yet to show), its last cover stands.
            // An active search's bar is UIKit's: the content follows it, as
            // UIKit's own does, but a title's insets are not sampled.
            // A plain tab's route has no bar of its own: More's shows above it
            // under More, and none on the tab bar.
            c.safeArea.sync(c)
            let search = searching(c)
            // Nested in the list's, the detail's routes are under the list's bar.
            let barNav = split.flatMap { $0.nested && nav === $0.detail ? $0.list : nil } ?? nav
            let barAbove = nav.map { c.parent is PlainTab ? !$0.isNavigationBarHidden : routeShowsBar(c, in: $0) } ?? false
            let settled = c.surface.window != nil && !c.safeAreaNeedsLayout && (search || (barNav?.isNavigationBarHidden ?? true) != barAbove)
            // A route showing no bar has no title: its inset is the status bar's, none in landscape (LLP 1130 D3).
            let barless = !barAbove
            if !c.ignoresSafeArea("top"), settled, !search, let node = c.collapseScroll, let sv = c.collapseScrollView, sv === node.scrollView, sv.adjustedContentInset.top > 0 || barless {
                let inset = sv.adjustedContentInset.top
                if c.insetsBarless != barless { c.insetsBarless = barless; node.scrollCollapsed = 0 }
                // tvOS has no large titles: every title is inline.
                #if os(tvOS)
                let inline = true
                #else
                let inline = c.navigationItem.largeTitleDisplayMode != .always || barless
                #endif
                if Self.stretched(sv, origin: node.scrollOrigin) {
                    // Pulled past its top, as to refresh: no title's inset.
                } else if inline {
                    // An inline title does not collapse: its inset is the one it has.
                    node.scrollOrigin = inset; node.scrollCollapsed = inset
                } else if nav?.transitionCoordinator == nil {
                    // A large title's widest and narrowest, at rest only.
                    if inset > node.scrollOrigin { node.scrollOrigin = inset }
                    if node.scrollCollapsed == 0 || inset < node.scrollCollapsed { node.scrollCollapsed = inset }
                }
            }
            if settled {
                var safe = c.surface.safeAreaInsets
                // PROTO (rule 4, `EdgeFramesIOS.swift`): whether UIKit moves the top edge: a large title collapsing, the
                // bar minimizing as configured, or UIKit having moved it where the system decides
                #if os(iOS)
                let moves = c.navigationItem.largeTitleDisplayMode == .always || Self.minimizes(c.navigationItem) || presenter.movedTops.contains(c.node.id)
                #else
                let moves = false
                #endif
                // PROTO (rule 4): a moving top rests where the large title is expanded and the bar unminimized, plus the
                // route's own additional inset or its held run inset. UIKit's `sizeThatFits` measured equal to the full
                // height while collapsed or minimized, whatever the bar shows now; a bar whose top stays (an inline
                // title) measures the large title's height there, which the route never shows, so it rests where it is.
                if moves, !ExactSession.protoLive, let bar = barNav.map({ $0.navigationBar }), !(barNav?.isNavigationBarHidden ?? true), bar.window != nil {
                    let inset = max(c.additionalSafeAreaInsets.top, presenter.geometry.run?.restingInset(for: c) ?? 0)
                    let full = c.surface.convert(bar.bounds, from: bar).minY + bar.sizeThatFits(CGSize(width: bar.bounds.width, height: .greatestFiniteMagnitude)).height + inset
                    safe.top = max(safe.top, full)
                }
                c.restingTop = safe.top
                if moves && !barless && !ExactSession.protoLive { presenter.movingTops.insert(c.node.id) } else { presenter.movingTops.remove(c.node.id) }
                // A route offset in its block, past a box beside it (`clearBesideRoutes`), clears only the part of
                // each side's inset its box reaches. PROTO (safe-area design r2 §2.1): the root is laid out inside
                // its clearance, so its box before that clearance is its laid-out box outset by the sides last reported.
                var box = c.node.convert(c.node.boxBounds, to: c.surface)
                if case .edges(let held)? = covers[c.node.id] { box = box.inset(by: UIEdgeInsets(top: 0, left: -held.left, bottom: 0, right: -held.right)) }
                safe.left = max(0, safe.left - max(0, box.minX))
                safe.right = max(0, safe.right - max(0, c.surface.bounds.maxX - box.maxX))
                // PROTO (safe-area design r2 §2.1): the bottom clearance is the part of the inset the block still overlaps
                // (a block the keyboard ends above the bars has none), measured from the block, not the root laid out inside it.
                let block = presenter.owners.block(in: c.surface)
                var reached = block.maxY - (c.surface.bounds.maxY - safe.bottom)
                // Each side on the device's pixel grid, as the layout it moves is: a side measured from a box laid out
                // in the side last told carries that layout's rounding back, so unrounded it never settles. A sidebar
                // 495⅔ points wide at a partial fold told a side an ulp smaller every pass, each a change that laid
                // the route out again, and the app froze.
                let scale = c.surface.traitCollection.displayScale
                safe = UIEdgeInsets(top: PixelGrid.round(safe.top, scale: scale), left: PixelGrid.round(safe.left, scale: scale),
                                    bottom: PixelGrid.round(safe.bottom, scale: scale), right: PixelGrid.round(safe.right, scale: scale))
                reached = PixelGrid.round(reached, scale: scale)
                // A transparent bar covers nothing of the route's top, scroller or not: the content starts under it.
                // PROTO (safe-area design r2 §2.3): a title's collapsing scroller and an arrangement's top pane leave the
                // route below the bar, and reach the edge (`SafeReachIOS`), where UIKit insets them.
                edges = Self.routeEdges(safe: safe, whole: whole, covered: covered,
                                        collapses: !c.ridingBars.isEmpty || RouteGeometry.insetsNoTop(c.node), reached: reached)
                // What the route clears, its values' content root (`ownerReports`): a band riding the bar goes under it
                // while the content root starts at the bar's bottom; where the route clears nothing of its top (a
                // transparent bar), the content root starts at the top edge too
                let cleared = Self.routeEdges(safe: safe, whole: whole, covered: covered, collapses: false, reached: reached)
                ownerClearance = RouteGeometry.insetsNoTop(c.node)
                    ? HostCover.Edges(top: 0, right: cleared.right, bottom: cleared.bottom, left: cleared.left) : cleared
                // An edge the route opts out of has no clearance to take (LLP 1123 D4).
                c.bottomClearance = RouteGeometry.clearanceOff(c.node) & 4 != 0 ? 0 : edges?.bottom ?? 0
            } else if case .edges(let e)? = covers[c.node.id] {
                edges = e
            } else { edges = nil }
            // An edge the route turns off (`-exact-safe-area`, LLP 1123 D4) has no clearance: the content root
            // reaches it, and its values say the inset there.
            ownerClearance = ownerClearance.map { e in
                HostCover.Edges(top: c.ignoresSafeArea("top") ? 0 : e.top, right: c.ignoresSafeArea("right") ? 0 : e.right,
                                bottom: c.ignoresSafeArea("bottom") ? 0 : e.bottom, left: c.ignoresSafeArea("left") ? 0 : e.left)
            }
            // PROTO (safe-area design r2 §2.3): the route's root is laid out in its safe area and its scrollers reach
            // the edges natively (`SafeReachIOS`), where UIKit insets them: no `Inset` cover subtracts the bars again,
            // and no clearance is added to a scroller's `contentInset` (`applyClearance`).
            if settled, let report = ownerReport(of: c, clearance: ownerClearance) { owners[c.node.id] = report }
            else if let held = ownerReports[c.node.id] { owners[c.node.id] = held }
            guard let edges else { continue }
            if edges != .init(top: 0, right: 0, bottom: 0, left: 0) { wanted[c.node.id] = .edges(edges) }
        }
        // The tablist whose place the tab bar takes takes no room. One that
        // holds the root's panels keeps them, and their routes, in the page.
        if let list = adoptedTablist.flatMap({ presenter.views[$0] }) {
            measuredTablist = presenter.session?.view.map { list.convert(list.boxBounds, to: $0) }
            if adopts(tablist: list) {
                for node in Self.covered(list, keeping: tabPanels.compactMap { presenter.views[$0] }) { wanted[node.id] = .whole }
            }
            else if tablistAppearanceNone, list.style["display"]?.string != "none",
                    wantsWholeView, presenter.viewportFit != "cover",
                    let view = presenter.session?.view, view.window != nil {
                // Authored tabs are page content outside the routes. Protect
                // only the edges they reach; leave the viewport and bar
                // backgrounds full-size. A sheet leaves them where they are
                // (LLP 1123 D1).
                // Authored overflow outside the viewport is no additional unsafe area.
                let rect = list.convert(list.boxBounds, to: view).intersection(view.bounds)
                if !rect.isNull && !rect.isEmpty {
                    let safe = view.bounds.inset(by: view.safeAreaInsets)
                    let edges = HostCover.Edges(
                        top: max(0, min(rect.height, safe.minY - rect.minY)),
                        right: max(0, min(rect.width, rect.maxX - safe.maxX)),
                        bottom: max(0, min(rect.height, rect.maxY - safe.maxY)),
                        left: max(0, min(rect.width, safe.minX - rect.minX)))
                    if edges != .init(top: 0, right: 0, bottom: 0, left: 0) { wanted[list.id] = .edges(edges) }
                }
            }
        }
        // A pane a native arrangement hides is the arrangement's to cover whole (`ArrangementHost.reportHiddenPanes`):
        // nothing is told of it here, and once shown again it is told afresh.
        var arranged = Set<UInt32>()
        #if os(iOS)
        if #available(iOS 27.1, *) { arranged = Set(presenter.arrangements.hiddenPanes) }
        #endif
        for id in arranged { wanted[id] = nil }
        for (id, cover) in wanted where covers[id] != cover { changes.append((id, cover)) }
        for id in covers.keys where wanted[id] == nil && presenter.views[id] != nil && !arranged.contains(id) { changes.append((id, nil)) }
        covers = wanted
        let locals = reportLocalInsets()
        let ownersChanged = owners != ownerReports
        ownerReports = owners
        // PROTO (rule 4): deliver moving-edge changes even when a mode switch leaves the covers unchanged
        guard !changes.isEmpty || locals || ownersChanged || presenter.movingTops != presenter.deliveredMovingTops else {
            return writeCarriedScrollsWhenAnswered()
        }
        // A scroller's least content height is the port its cover leaves
        // (`scrollFloor`); the kernel sends no new content size when only that changed.
        for (id, _) in changes { presenter.views[id]?.fitScroll() }
        countReport()
        // Under Q3 (c) a cold launch's first frame runs no app code: a hatch
        // that changes a bar the plan already showed moves the content once.
        if replayingHatches, changes.contains(where: { presenter.views[$0.0]?.props["navigationKey"] != nil }) {
            presenter.session?.log("hatch: the content area moved after the first frame, by a hatch run at launch")
        }
        // Never inside a batch: the stack is installed partway through the
        // first one, whose remaining frames would overwrite the covered ones.
        presenter.afterBatch { [weak self] in self?.deliverCovers() }
    }

    /// What the kernel is told is what is wanted when it is told. A report
    /// queued behind a batch ran after later ones that did not wait, and its
    /// covers, measured under the bar's first frame before the status bar's
    /// inset (116 points with a large title of 168), won: team-kanban's
    /// persona switcher lay under the large title, drawn over by it and
    /// untappable (LLP 1116.006 D1).
    func deliverCovers() {
        // A delivery asked for while one runs (an answer applied in it reports again, or the write or the sync that
        // closes a pass does) runs in that one, after the pass
        guard !deliveringCovers else { deliverAgain = true; return }
        // A callback the runtime waits on can make no runtime call: deliver once it returns
        if Owner.shared.isServingMain {
            DispatchQueue.main.async { [weak self] in self?.deliverCovers() }
            return
        }
        deliveringCovers = true
        defer { deliveringCovers = false }
        for _ in 0..<8 {
            deliverAgain = false
            deliverCoversOnce()
            guard deliverAgain else { return }
            if untoldChain?.spent == true { break }
        }
        // What a report past the chain's eighth pass changed stays untold until a report outside the chain tells it
        if untoldChain?.spent == true {
            presenter.session?.log("Navigation covers did not settle in 8 passes; what the last changed is told with the next change no answer causes")
            return
        }
        // A chain a slice landed meanwhile started is told on the main queue's next turn, so one call holds main for
        // eight passes at most and leaves no counted report untold
        DispatchQueue.main.async { [weak self] in self?.deliverCovers() }
    }

    /// Count a report that changed the covers or the local insets, in the chain of the work making it
    /// (`ExactSession.coversCause`), or in a new one. Reports told together are told in the chain with more passes left,
    /// so a change no answer causes keeps its own eight. A report in a spent chain is not counted: no delivery tells it in
    /// that chain, so no carried position waits for its answer (`coversAnswerOwed`).
    func countReport() {
        let chain = presenter.session?.coversCause as? CoversChain ?? CoversChain()
        untoldChain = untoldChain.map { $0.passes <= chain.passes ? $0 : chain } ?? chain
        if !chain.spent { coversReported += 1 }
    }

    /// Deliver the covers and local insets not yet told, in their chain, unless it is spent. Every pass is one of its
    /// chain's eight, and the runtime's answers and the write and the sync that close it run in the chain, so what they
    /// report is told in that chain.
    private func deliverCoversOnce() {
        let views = presenter.views
        let untold = !untoldCovers().isEmpty || !untoldOwners().isEmpty || localInsets.changed(live: { views[$0] != nil })
            || presenter.movingTops != presenter.deliveredMovingTops // PROTO (rule 4)
        let chain = untoldChain ?? CoversChain(), spent = chain.spent
        // A spent chain keeps what it left untold, so a delivery asked again tells nothing in it
        if untold, spent { presenter.session?.log("Navigation covers did not settle in 8 passes; what the last changed is told with the next change no answer causes") }
        if !untold || !spent { untoldChain = nil }
        if !spent { chain.passes += 1 }
        // The last report this pass answers: every one counted before it sends (a spent chain's untold ones are not)
        let told = coversReported
        let inChain = { (work: () -> Void) in if let session = self.presenter.session { session.inCoversChain(chain, work) } else { work() } }
        inChain {
            // A stack change held for a lifted header (`liftHeld`) is given to
            // UIKit by the sync of the runtime's answer to its cover. The session
            // applies answers in the order asked, a slice in flight first: the
            // hold ends just before this answer, and what it did not sync (an
            // answer that moved nothing) syncs after it. An answer applied here
            // can lift another header, whose own delivery runs once this one ends.
            let release = { [weak self] in
                guard let self else { return }
                liftReleased = max(liftReleased, told)
            }
            let idle = { [weak self] (work: @escaping () -> Void) in
                guard let session = self?.presenter.session else { return work() }
                session.whenIdle(bound: true, work, cancelled: release)
            }
            let held = liftHeld
            if held { idle(release) }
            if untold, !spent {
                // PROTO (rule 4): the routes whose top edge moves, told first
                let moving = presenter.movingTops.symmetricDifference(presenter.deliveredMovingTops).map { ($0, presenter.movingTops.contains($0)) }
                presenter.deliveredMovingTops = presenter.movingTops
                if !moving.isEmpty { presenter.onMovingTops?(moving) }
                presenter.session?.localInsets(localInsets.take { views[$0] != nil })
                // Read the covers once the local insets are told, so covers their answer changes at once, as it does
                // when no work waits, go out in this pass. A report that answer makes stays owed, and the next pass
                // answers it, telling what is still untold, local insets among it, or nothing.
                let changes = untoldCovers(), owners = untoldOwners()
                delivered = covers
                deliveredOwners = ownerReports
                // A route no frame has shown is told first, still (`tellStill`).
                tellStill(changes, owners) { if !$0.isEmpty || !$1.isEmpty { presenter.onCovers?($0, $1) } }
            }
            writeCarriedScrollsWhenAnswered(through: told)
            if held || liftHeld { idle { [weak self] in release(); self?.liftAnswered() } }
        }
    }

    /// The covers the kernel has not been told, and the scrollers still shown that no longer have the one it was told
    private func untoldCovers() -> [(UInt32, HostCover?)] {
        var changes: [(UInt32, HostCover?)] = []
        for (id, cover) in covers where delivered[id] != cover { changes.append((id, cover)) }
        for id in delivered.keys where covers[id] == nil && presenter.views[id] != nil { changes.append((id, nil)) }
        return changes
    }

    /// Write the positions Exact carried across a change of its own (`Presenter.writeCarriedScrolls`) once every report
    /// that changed the covers or local insets is answered, so each lands in the layout it is for. A delivery passes
    /// the last report it told (`report`): the session runs this after the runtime's answer to it, which answers it,
    /// and a reset cancels both, which makes it moot. A call for covers and local insets that changed nothing passes
    /// none and answers nothing. While a report is unanswered a batch's restore leaves the positions
    /// (`coversAnswerOwed`), a fill's among them; inside a batch with none unanswered, the batch's restore writes them.
    func writeCarriedScrollsWhenAnswered(through report: Int? = nil) {
        let answered = { [weak self] in
            guard let self, let report else { return }
            coversAnswered = max(coversAnswered, report)
        }
        let write = { [weak self] in
            answered()
            guard let self, !coversAnswerOwed, !presenter.applying else { return }
            presenter.writeCarriedScrolls()
        }
        // Covers that changed nothing, with no answer owed, have nothing to wait for: written now, before work waiting
        // in the session can scroll the scroller
        guard let session = presenter.session, report != nil || coversAnswerOwed else { return write() }
        session.whenIdle(bound: true, write, cancelled: answered)
    }

    /// The side insets of a route in a sheet still being presented, as they are where the sheet lands
    /// (`UIPresentationController.frameOfPresentedViewInContainerView`). The sheet's own safe area during the
    /// transition is not that: on the iPhone Duo the side by the button strip read 8 points wider.
    static func landingSides(_ c: RouteController) -> (left: CGFloat, right: CGFloat)? {
        var top: UIViewController = c
        while let parent = top.parent { top = parent }
        guard top.isBeingPresented, let sheet = top.presentationController, let container = sheet.containerView else { return nil }
        let landed = sheet.frameOfPresentedViewInContainerView
        let box = c.node.convert(c.node.boxBounds, to: top.view)
        let safe = container.safeAreaInsets
        let minX = landed.minX + max(0, box.minX), maxX = landed.maxX - max(0, top.view.bounds.maxX - box.maxX)
        return (max(0, safe.left - minX), max(0, safe.right - (container.bounds.maxX - maxX)))
    }

    /// @ref LLP 1123 D9 — each route's own safe area, which its content reads
    /// as `var(--exact-safe-area-inset-*)`: its controller's view's, the bars,
    /// the status bar and the home indicator in it, on the sides only as far
    /// as the route's box reaches them, as its covers are. A route out of a
    /// window keeps the last it had, UIKit's zero there being no measurement,
    /// and so does one while its stack's transition runs, or while UIKit has
    /// announced a safe area its layout has yet to apply
    /// (`safeAreaNeedsLayout`), as its cover does; one that has none yet takes
    /// what it has from its first frame, its sides from where a sheet being
    /// presented lands (`landingSides`). And the
    /// session root's while the containers take the whole view, where `env()`
    /// is 0 but the screen's insets are not. Whether any changed.
    func reportLocalInsets() -> Bool {
        var wanted: [UInt32?: [CGFloat]] = [:]
        for c in controllers.values where presenter.views[c.node.id] === c.node {
            let last = localInsets.wanted[c.node.id]
            let view = c.surface
            guard view.window != nil, c.node.window != nil,
                  last == nil || (c.navigationController?.transitionCoordinator == nil && !c.safeAreaNeedsLayout) else {
                wanted[c.node.id] = last
                continue
            }
            // The part of the view's safe area the root's laid-out box lies in, on each edge. PROTO (safe-area design r2
            // §2.1): the root is laid out in what the route clears, which it reads as 0, and its view's reach past the
            // box to the edges (`SafeReach`) is no part of the box.
            let box = c.node.convert(c.node.boxBounds, to: view)
            let safe = view.safeAreaInsets
            var sides = (left: max(0, safe.left - max(0, box.minX)), right: max(0, safe.right - max(0, view.bounds.maxX - box.maxX)))
            if last == nil, let landing = Self.landingSides(c) { sides = landing }
            wanted[c.node.id] = [max(0, safe.top - max(0, box.minY)), sides.right, max(0, safe.bottom - max(0, view.bounds.maxY - box.maxY)), sides.left]
        }
        if wantsWholeView, let view = presenter.session?.view, view.window != nil {
            let safe = view.safeAreaInsets
            wanted[nil] = [safe.top, safe.right, safe.bottom, safe.left]
        }
        defer { localInsets.wanted = wanted }
        return localInsets.wanted != wanted
    }
    /// The owners' values the kernel has not been told, and the routes still shown that no longer have the ones it
    /// was told
    private func untoldOwners() -> [(UInt32, OwnerReport?)] {
        var owners: [(UInt32, OwnerReport?)] = []
        for (id, values) in ownerReports where deliveredOwners[id] != values { owners.append((id, values)) }
        for id in deliveredOwners.keys where ownerReports[id] == nil && presenter.views[id] != nil { owners.append((id, nil)) }
        return owners
    }

    #if os(iOS)
    /// PROTO (rule 4): whether `item`'s bar is configured to minimize as its scroller scrolls with the safe area
    /// following it (`UIBarMinimization`). Under `.automatic` the system decides, and measured on an iPhone 18 Pro and
    /// the open Duo it minimizes nothing; a route UIKit moves anyway is caught at its first move (`placeEdge`).
    static func minimizes(_ item: UINavigationItem) -> Bool {
        guard #available(iOS 27.0, *) else { return false }
        let minimization = item.navigationBarMinimization
        return minimization.safeAreaAdjustment != .disabled && [.onScrollDown, .onScrollUp].contains(minimization.minimizationBehavior)
    }
    #endif

    /// Whether the kernel pads `c`'s top by its cover (`reportCovers`): a
    /// route whose title's scroller goes under the bar keeps its top cover,
    /// which the kernel pads nothing of while UIKit insets that scroller.
    func padsTop(_ c: RouteController) -> Bool {
        guard case .edges(let e)? = covers[c.node.id] else { return false }
        return e.top > 0.5 && c.collapseScroll == nil
    }

    /// What the host reports of `c`'s route as a content owner (LLP 1123 D2's
    /// owner update) beside its cover, which is its band. Its margins are
    /// UIKit's for its controller (D8): the root view's margins guide from the
    /// block's edges, a plain view's margins, the controller's system minimum
    /// and the readable width. Its segments are the parts of the document's
    /// that its content root, the block less what it clears (`clearance`),
    /// holds, in that root's coordinates (D16): the window's division moved
    /// into the route, read once the document has it (UIKit's regions trail
    /// a hinge update, `ExactView.fit`), and an agent's `prefer segments` the
    /// same way.
    func ownerReport(of c: RouteController, clearance: HostCover.Edges?) -> OwnerReport? {
        guard let view = c.viewIfLoaded, view.window != nil else { return nil }
        let e = clearance ?? .init(top: 0, right: 0, bottom: 0, left: 0)
        // PROTO (safe-area design r2 §2.2): the content root is the block less the clearance.
        let block = presenter.owners.block(in: view)
        let content = block.inset(by: UIEdgeInsets(top: e.top, left: e.left, bottom: e.bottom, right: e.right))
        guard content.width > 0, content.height > 0 else { return nil }
        let vp = presenter.viewport, document = presenter.fold
        let parts = (document.cols * document.rows > 1 ? document.rects : []).map {
            vp.convert($0.offsetBy(dx: vp.pageOrigin.x, dy: vp.pageOrigin.y), to: view).intersection(content)
        }
        let fold = ViewportFold.grid(parts.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }.map { $0.offsetBy(dx: -content.minX, dy: -content.minY) })
        return OwnerReport(margins: Self.margins(of: c, view: view, block: block), fold: fold)
    }

    /// UIKit's margins for `c`'s controller (the kernel's `OwnerMargins`), in `block`'s points.
    private static func margins(of c: UIViewController, view: UIView, block: CGRect) -> OwnerReport.Margins {
        let guide = view.layoutMarginsGuide.layoutFrame
        let root = [guide.minY - block.minY, block.maxX - guide.maxX, block.maxY - guide.maxY, guide.minX - block.minX].map { max(0, $0) }
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let m = c.systemMinimumLayoutMargins
        let minimum = [m.top, rtl ? m.leading : m.trailing, m.bottom, rtl ? m.trailing : m.leading]
        let p = plainMargins
        return OwnerReport.Margins(root: root, plain: [p.top, p.right, p.bottom, p.left], minimum: minimum,
                                   readableWidth: view.readableContentGuide.layoutFrame.width)
    }

    /// A plain view's default margins, which UIKit gives every new `UIView`.
    private static let plainMargins = UIView().layoutMargins

    // MARK: The development check (LLP 1075.003 §3.5)

    /// The delegate slots Exact keeps (LLP 1075.003 §3.5): every stack's,
    /// hooked or not, More's once adopted, and its own tab container's. A
    /// slot written outside Exact takes its container's calls from Exact, so
    /// the journal names it once each time it leaves Exact: what it holds,
    /// what Exact no longer hears and what to set instead. Checked at each
    /// batch, also while Exact is changing a stack: such a slot keeps Exact
    /// from hearing a transition end.
    func checkDelegates() {
        func say(_ what: String, _ now: AnyObject?, _ effect: String) {
            presenter.session?.log("\(what): delegate changed outside Exact, which owns it (now \(now.map { "\(type(of: $0))" } ?? "nil")); \(effect)")
        }
        // `stacks` holds a record for each slot Exact keeps: `registerStack` fills the slot, `retireStack` retires it
        for stack in stacks.values.sorted(by: { $0.order < $1.order }) {
            guard let nav = stack.controller else { continue }
            let written = !stack.proxy.fillsSlot
            if written, !stack.proxy.slotNamed {
                if nav === adoptedMore {
                    say("navigation More", nav.delegate, "Exact hears none of More's calls, and More has no forwarded delegate")
                } else {
                    say("navigation \(stack.label)", nav.delegate, "Exact hears none of this stack's calls: set ExactNavigation.delegate, which Exact forwards to")
                }
            }
            stack.proxy.slotNamed = written
        }
        guard let tabs = tabController, let proxy = tabProxy else { return }
        let written = !proxy.fillsSlot
        if written, !proxy.slotNamed {
            say("tabs", tabs.delegate, "Exact hears none of the tab container's calls: set ExactTabs.delegate, which Exact forwards to")
        }
        proxy.slotNamed = written
    }

    /// Before each batch: compare what Exact owns on each hatched object and
    /// the tabs of its own tab container with what Exact last wrote or made,
    /// and UIKit's stacks and selection at rest with the router's
    /// (`restDifference`), and journal a difference once, by name. It is
    /// detection, not enforcement; a change made and undone between two
    /// batches is not seen.
    func checkOwned() {
        guard RouteGeometry.checksOwnership else { return }
        checkDelegates()
        checkTabs()
        if let difference = restDifference { reportOnce("navigation: at rest, \(difference)") }
        guard !changing, !syncing, presenter.session?.natives.hatchesConnected == true else { return }
        // `allNavigations` leaves out a tab's own navigation controller while UIKit holds its routes in More; More has
        // no hatch, so the `hatched` guard skips it
        for nav in allNavigations {
            guard let stack = stacks[ObjectIdentifier(nav)], stack.hatched else { continue }
            if nav.transitionCoordinator == nil, !searching(nav.topViewController as? RouteController), nav.isNavigationBarHidden == topShowsBar(nav) { say("navigation \(stack.label)", "navigation bar visibility") }
            #if !os(tvOS)
            if let pop = nav.interactivePopGestureRecognizer, pop.delegate !== self { say("navigation \(stack.label)", "the pop gesture's delegate") }
            if #available(iOS 26.0, tvOS 26.0, *), let pop = nav.interactiveContentPopGestureRecognizer, pop.delegate !== self {
                say("navigation \(stack.label)", "the content pop gesture's delegate")
            }
            #endif
        }
        for c in controllers.values where c.hatched && presenter.views[c.node.id] === c.node {
            if c.navigationController != nil, c.isViewLoaded, c.node.superview !== c.contentMount { say("route \(c.key)", "view") }
            guard let node = c.ownedScroll, let scroll = node.scrollView else { continue }
            for property in RouteGeometry.ownedChanges(scroll, of: node, insetByUIKit: insetByUIKit(node), safeArea: c.safeArea.insets(for: scroll)) { say("route \(c.key)", property) }
        }
    }

    /// The tabs and their controllers Exact made with its container, hooked
    /// or not (LLP 1075.003 §3.7): Exact never replaces a tab's controller,
    /// and makes a container's `UITab`s again only when an app's
    /// `tabContainer` took their stacks and returned no container
    /// (`restoreBuiltTabs`). They are compared as members, since More's Edit
    /// reorders them as UIKit lets a person do. A container built from
    /// `UITab`s holds them in its `tabs`, and its `viewControllers` reads nil,
    /// so it is compared by its tabs. One built from controllers is compared
    /// by its `viewControllers`, which reads nil once the app sets `tabs` on it.
    private func checkTabs() {
        // Skip during a sync, which can set `builtTabs` before the container's tabs: the next batch checks them
        guard !syncing, let tabs = tabController, tabOwner === tabs else { return }
        // Compare by identity as sets: Exact's are distinct, so equal counts and equal sets are the same members
        func same(_ shown: [AnyObject], _ made: [AnyObject]) -> Bool {
            shown.count == made.count && Set(shown.map(ObjectIdentifier.init)) == Set(made.map(ObjectIdentifier.init))
        }
        if #available(iOS 18.0, tvOS 18.0, *), !builtTabs.isEmpty {
            if !same(tabs.tabs, builtTabs) { say("tabs", "tabs") }
        } else if #available(iOS 18.0, tvOS 18.0, *), tabs.viewControllers == nil {
            // Name `tabs` for a container built from controllers that now holds `UITab`s: a cleared
            // `viewControllers` reads back as no controllers, not nil (measured on iOS 27)
            say("tabs", "tabs")
        } else if !same(tabs.viewControllers ?? [], tabPanels.compactMap { tabStacks[$0] }) {
            say("tabs", "viewControllers")
        }
    }

    /// Journal that `what`'s `property`, which Exact owns, changed outside it, the first time the check finds it.
    private func say(_ what: String, _ property: String) { reportOnce("\(what): \(property) changed outside Exact, which owns it") }

    /// Journal `line` the first time the development check finds it.
    private func reportOnce(_ line: String) {
        if ownedReported.insert(line).inserted { presenter.session?.log(line) }
    }

}

extension RouteController {
    /// Asks the navigation controller to observe again a scroll view that left
    /// one edge while the other edge may still use it. The controller registers
    /// once as each content scroll view's scroll observer, and a change on one
    /// edge removes that registration from the view the edge left, even when
    /// the view stays the other edge's (measured on iOS 27.0 and 27.1). Its
    /// bar then stops following that view's scrolling (no large
    /// title collapse or snap, no minimization) until its next layout observes
    /// the controller's content scroll views again. UIKit resolves an edge set
    /// to no scroll view itself, possibly to the view that left.
    func observeAgain(_ leaving: UIScrollView?, leftFrom edge: NSDirectionalRectEdge, for scrollView: UIScrollView?) {
        guard let leaving, leaving !== scrollView else { return }
        let other = contentScrollView(for: edge == .top ? .bottom : .top)
        if other == nil || other === leaving { navigationController?.view.setNeedsLayout() }
    }

    /// A large title at rest opens after its route appears, once UIKit has
    /// given its scroller the bar's insets. The same repair keeps it open
    /// when the text size changes. UIKit draws the title at the new size in
    /// the bar's old height, which grows only when the list is pulled:
    /// at the largest size the title ran under
    /// the bar's buttons (meal-planner, bake-off round 34), and a hand-built
    /// bar clips it the same way. A scroller at its start is pulled open on
    /// the next turn, after UIKit's layout, as a title that turns large
    /// again in place is (`restAtTop`).
    func reopenTitle() {
        guard collapseScroll != nil, let host, let sv = host.contentScrollView(of: self), !sv.isTracking, !sv.isDecelerating,
              sv.contentOffset.y <= 0.5 - sv.adjustedContentInset.top else { return }
        DispatchQueue.main.async { [weak self, weak sv] in
            guard let self, let sv, let host = self.host, sv.contentOffset.y <= 0.5 - sv.adjustedContentInset.top else { return }
            host.restAtTop(sv, in: self)
        }
    }
}

/// A chain of covers corrections: a change no answer causes, and every report that the runtime's answers to its
/// deliveries, and the writes and syncs closing them, make in turn. Covers that never settle stop after its eighth
/// pass, however its answers branch and whether they apply at once or wait behind a slice.
final class CoversChain {
    var passes = 0
    var spent: Bool { passes >= 8 }
}
#endif
