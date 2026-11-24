// @ref LLP 1127 — a list and its detail on iOS are UIKit's split view.
// Where a stack's root route holds a list whose rows push (the runner's
// rule, `StackSplit`), the stack is the two columns of a
// `UISplitViewController`: the root route in the list's navigation
// controller, the routes above it in the detail's. How many columns show,
// their widths and where the bars stand are UIKit's. Collapsed, UIKit nests
// the detail's controller in the list's and takes it back as it expands
// (LLP 1127 §1, item 2), so a pop in either is the router's Back. Expanded,
// a sheet that says `navigationInspector` is the split's inspector column
// (D14).
#if os(iOS) || os(tvOS)
import ExactKit
import UIKit

/// UIKit's split, which says when a layout changed whether the list shows
/// beside the detail: a split laid out wide from the start sends no
/// expansion to its delegate.
private final class SplitController: UISplitViewController {
    var laidOut: () -> Void = {}
    var resizing: () -> Void = {}
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        resizing()
        super.viewWillTransition(to: size, with: coordinator)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        laidOut()
    }
}

final class SplitIOS: NSObject, UISplitViewControllerDelegate {
    let controller: UISplitViewController = SplitController(style: .doubleColumn)
    /// The list's column: the stack's root route.
    let list: UINavigationController
    /// The detail's column: the routes above the root.
    let detail: UINavigationController
    /// The detail while the stack is at its root: the platform's empty page
    /// (LLP 1127 Q2).
    let empty = UIViewController()
    /// UIKit collapsed or expanded the columns, or showed or hid one.
    var changed: () -> Void = {}
    var projectionOwed: () -> Bool = { false }
    /// The stack last shown, root first: expanded again, the columns show it.
    private var stack: [RouteController] = []
    var projectedDetailTop: RouteController? { stack.dropFirst().last }
    /// `showsList` when `changed` was last called.
    private var told: Bool?
    /// The inspector's column (iOS 26), made when a route first goes there.
    private(set) var inspector: UINavigationController?
    /// The person closed the inspector's column; the router has yet to hear it.
    var inspectorClosed: () -> Void = {}
    /// The detail is about to cover the list as the columns collapse.
    var listWillBeCovered: () -> Void = {}
    #if os(iOS)
    private(set) var searchState = SplitSearchState()
    private(set) weak var searchOwner: RouteController?
    var pairedSearch: HeaderSearch? { searchOwner?.search.flatMap { $0.paired ? $0 : nil } }
    var searchProjectionEpoch: UInt64 { searchState.projectionEpoch }
    var stageForExpansion: () -> Void = {}
    #endif
    var paired: Bool {
        #if os(iOS)
        pairedSearch != nil
        #else
        false
        #endif
    }
    /// Whether there is no page above the list in the ordinary split.
    var noPageAboveList: () -> Bool = { false }
    private var laidOutSinceMove = false
    private(set) var writing = false
    /// UIKit is moving the columns, inside its animation (`moveAlong`).
    var columnsMove: () -> Void = {}
    /// UIKit has said the columns will move, or has opened a transition for a column Exact showed or hid (`moveAlong`),
    /// and has yet to open its animation. It lays them out itself, inside that animation, as it does a view constrained
    /// to the safe area: nothing here may lay them out before then, or the columns and what the safe area moves jump
    /// to their end (an inspector shown beside the sidebar would hide it at once: UIKit says the display mode will change
    /// only as it lays the columns out).
    var columnsAboutToMove: Bool { aboutToMove != nil }
    /// The transition whose animation UIKit has yet to open (`columnsAboutToMove`)
    private weak var aboutToMove: UIViewControllerTransitionCoordinator?
    /// The list whose rows made the stack a split, which keeps it one while
    /// it has no row to act on (a search that matches nothing).
    var listNode: UInt32?
    /// The locations of the detail's pages, bottom first: after a Back to the list while collapsed, the next expansion
    /// returns to them, as UIKit's own split shows the detail the person left (LLP 1127 §1, item 4). The stack at its
    /// root on a split settled expanded forgets them (`NavigationHost.noteDetail`).
    var left: [String] = []
    /// Asks the router for `left`'s locations.
    var returnTo: ([String]) -> Void = { _ in }

    init(list: UINavigationController, detail: UINavigationController) {
        self.list = list
        self.detail = detail
        super.init()
        #if os(iOS)
        empty.view.backgroundColor = .systemBackground
        #endif
        controller.delegate = self
        #if os(iOS)
        // The list's column is a sidebar, in UIKit's style for one, as SwiftUI's split sets it.
        controller.primaryBackgroundStyle = .sidebar
        #endif
        (controller as? SplitController)?.laidOut = { [weak self] in
            guard let self else { return }
            if moving { laidOutSinceMove = true }
            guard told != showsList else { return }
            told = showsList
            DispatchQueue.main.async { [weak self] in self?.changed() }
        }
        #if os(iOS)
        (controller as? SplitController)?.resizing = { [weak self] in
            guard let self, paired else { return }
            searchState.beginOwnerMove()
            changed()
        }
        #endif
        controller.setViewController(list, for: .primary)
        controller.setViewController(detail, for: .secondary)
    }

    /// Whether the list shows beside the detail.
    var showsList: Bool { !controller.isCollapsed && controller.displayMode != .secondaryOnly }
    /// Whether the list shows over the detail: then only the list is live (LLP 1127 D8).
    var overlaysDetail: Bool { !controller.isCollapsed && [.oneOverSecondary, .twoOverSecondary].contains(controller.displayMode) }
    /// Whether UIKit nests the detail's controller in the list's now.
    var nested: Bool { controller.isCollapsed && list.viewControllers.contains { $0 === detail } }
    /// Whether UIKit is expanding the columns, from asking which display mode
    /// to expand to until it has: the detail's controller leaves the list's
    /// for its column meanwhile, which is no Back. The split's own size class
    /// can still be compact then (an iPhone Duo unfolding).
    var expanding: Bool { expansion && controller.isCollapsed }
    private var expansion = false
    /// Whether UIKit is collapsing the columns, from asking which column to
    /// put on top until it has: the detail's controller enters the list's
    /// meanwhile, while the split still reads expanded. UIKit can ask and then
    /// expand instead, with no word of a collapse (an iPhone Duo unfolding):
    /// the expansion's question ends the mark, as the collapse's ends
    /// `expansion`, for a split moves one way at a time. A mark left set held
    /// every later stack and the inspector back (`show`, `inspect`).
    private var collapsing = false
    /// Whether UIKit is collapsing or expanding the columns, from its question until its report.
    var moving: Bool { expansion || collapsing }
    /// Whether UIKit lays the columns out itself, so nothing here may: it has said they will move and has yet to open
    /// its animation (`columnsAboutToMove`), or it is collapsing or expanding them, moving the navigation items
    /// between bars, where a bar laid out meanwhile fails UIKit's assertion ("Layout requested for visible navigation
    /// bar … when the top item belongs to a different navigation bar"; iOS 27.1, collapsing for the app switcher's
    /// snapshot as the app left the screen). The report that ends the move syncs again (`changed`).
    var laysOutItself: Bool { columnsAboutToMove || moving }
    /// Whether the split is expanded and no longer moving between its forms: UIKit reads it expanded before it has
    /// said so (`splitViewControllerDidExpand`), and a sync can come between.
    var settledExpanded: Bool { !controller.isCollapsed && !expansion && !collapsing }
    /// Whether the split is collapsed and no longer moving between its forms.
    var settledCollapsed: Bool { controller.isCollapsed && !expansion && !collapsing }
    /// Whether the person sees the detail's routes: collapsed, only while
    /// nested, as a pop of the detail's controller leaves its routes in it.
    private var showsDetail: Bool { (controller.isCollapsed ? nested : true) && detail.viewControllers.contains { $0 is RouteController } }
    /// The controller whose top the person sees.
    var front: UINavigationController { showsDetail ? detail : list }
    /// The routes UIKit shows, root first.
    var shown: [RouteController] {
        list.viewControllers.prefix(1).compactMap { $0 as? RouteController } + (showsDetail ? detail.viewControllers.compactMap { $0 as? RouteController } : [])
    }
    /// Whether a stack is one of the columns'.
    func holds(_ nav: UINavigationController) -> Bool { nav === list || nav === detail }

    /// The stack, root first, in the two columns: what UIKit shows of it is
    /// UIKit's. A push or pop within the detail is animated as a stack's is;
    /// a new detail replaces the last at once, as a hand-built split's does.
    func show(_ stack: [RouteController], animated: Bool, revealsDetail: Bool = true) {
        guard let root = stack.first, !moving else { return }
        let moved = !self.stack.elementsEqual(stack, by: ===)
        self.stack = stack
        writing = true
        defer { writing = false }
        let routes = Array(stack.dropFirst())
        var showsPrimary = routes.isEmpty
        #if os(iOS)
        if paired {
            if revealsDetail && !routes.isEmpty { searchState.collapseToPrimary = false }
            showsPrimary = showsPrimary || searchState.collapseToPrimary
        }
        #endif
        if list.viewControllers.first !== root || (!controller.isCollapsed && list.viewControllers.count != 1) {
            list.setViewControllers([root], animated: false)
        }
        if showsPrimary, nested {
            controller.show(.primary)
            if paired && (list.transitionCoordinator != nil || controller.transitionCoordinator != nil) { return }
        }
        installDetail(routes, animated: animated && (!controller.isCollapsed || nested))
        if routes.isEmpty {
            if paired && moved && !controller.isCollapsed { controller.show(.primary) }
        } else if controller.isCollapsed {
            if !nested && (!paired || revealsDetail) { controller.show(.secondary) }
        } else if overlaysDetail && revealsDetail && (paired || moved) {
            // UIKit may keep its temporary overlay in expanded width (LLP 1127 D6).
            controller.show(.secondary)
        }
    }

    private func installDetail(_ routes: [RouteController], animated: Bool) {
        let next: [UIViewController] = routes.isEmpty ? [empty] : routes
        guard !same(next) else { return }
        let previous = detail.viewControllers
        let within = previous.first !== empty && !routes.isEmpty && NavigationRules.isPushOrPop(
            from: previous.map(ObjectIdentifier.init), to: routes.map(ObjectIdentifier.init))
        for case let route as RouteController in previous where !routes.contains(route) { route.held = false }
        detail.setViewControllers(next, animated: animated && within)
    }

    #if os(iOS)
    func setSearchOwner(_ owner: RouteController, children: [UInt32]) {
        guard searchOwner !== owner else { return }
        if paired { searchOwner?.detachSearch() }
        FrameClock.shared.drop(searchState)
        searchState.showInstalledDetail()
        searchState = SplitSearchState()
        searchOwner = owner
        searchState.children = children
    }

    /// UIKit reads N1 on its first expansion frame. While it still owns a pop,
    /// cover a stale N1 until the committed contents can be installed.
    func stageExpansion(_ stack: [RouteController], awaitingCommit: Bool = false) {
        let routes = Array(stack.dropFirst())
        let next: [UIViewController] = routes.isEmpty ? [empty] : routes
        if awaitingCommit {
            searchState.concealDetail(in: detail.view)
            return
        }
        guard !same(next) else { return }
        if writing || list.transitionCoordinator != nil || detail.transitionCoordinator != nil {
            searchState.concealDetail(in: detail.view)
        } else {
            writing = true
            defer { writing = false }
            installDetail(routes, animated: false)
        }
    }

    func reconcileMoveAfterLayout() {
        // A reversal can finish in UIKit's layout without a matching delegate completion.
        if laidOutSinceMove, controller.transitionCoordinator == nil, list.transitionCoordinator == nil, detail.transitionCoordinator == nil {
            laidOutSinceMove = false
            expansion = false
            collapsing = false
        }
    }
    #endif

    /// The route the inspector's column shows, while the split is expanded.
    var inspecting: RouteController? {
        guard !controller.isCollapsed, let inspector else { return nil }
        return inspector.viewControllers.first as? RouteController
    }

    /// The routes the columns show beside the stack's top, live: the list
    /// beside its detail, and the detail beside its inspector. A
    /// presentation over the split covers them first
    /// (`NavigationHost.splitShown`).
    var beside: [RouteController] {
        let list = showsList ? list.viewControllers.prefix(1).compactMap { $0 as? RouteController } : []
        let detail = inspecting != nil ? (self.detail.topViewController as? RouteController).map { [$0] } ?? [] : []
        return list + detail
    }

    /// The routes shown under a pane over them, not live: the detail under
    /// the list that overlays it.
    var under: [RouteController] {
        overlaysDetail ? (detail.topViewController as? RouteController).map { [$0] } ?? [] : []
    }

    /// Whether this split can show an inspector's column (UIKit's, iOS 26).
    var inspects: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// The sheet route that says `navigationInspector` in the inspector's
    /// column, or none there (LLP 1127 D14). Collapsed, the column empties at
    /// once, for the route to go to its sheet; closed while expanded, the
    /// route stays until the column's transition is over. `animated` false
    /// puts the column in place at once (a route that leaves its sheet as
    /// the split expands, as UIKit's own inspector is there from the
    /// expansion's first frame).
    func inspect(_ route: RouteController?, in made: UINavigationController?, animated: Bool = true) {
        // tvOS has no inspector's column.
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return }
        // A split that collapsed, or is collapsing, since its route was
        // chosen (a fold during the sync) has no column to show it in: its
        // route goes to its sheet.
        if let route, let nav = made, !controller.isCollapsed, !collapsing {
            // A close still in its transition is superseded: its end must not empty the column.
            closing = nil
            endSlide()
            inspector = nav
            // The column is the split's again after a collapse took it (`topColumnForCollapsing`).
            if controller.viewController(for: .inspector) !== nav { controller.setViewController(nav, for: .inspector) }
            if nav.viewControllers.first !== route { nav.setViewControllers([route], animated: false) }
            if !animated, !controller.isShowing(.inspector) {
                UIView.performWithoutAnimation {
                    controller.show(.inspector)
                    controller.view.layoutIfNeeded()
                }
            } else if !controller.isShowing(.inspector) {
                // UIKit lays its own inspector out where it ends and then
                // slides the column in: the route, which no frame has shown,
                // is told its place still (`NavigationHost.tellStill`).
                controller.show(.inspector)
                moveAlong()
            }
            return
        }
        guard let nav = inspector, !nav.viewControllers.isEmpty else { return endSlide() }
        // Collapsing, the column goes with the split (`topColumnForCollapsing`).
        if controller.isCollapsed || collapsing || controller.viewController(for: .inspector) !== nav {
            empty(nav)
            return endSlide()
        }
        // A close in its transition keeps its route until it ends.
        guard closing == nil else { return }
        if !controller.isShowing(.inspector) {
            empty(nav)
            return endSlide()
        }
        closes += 1
        let close = closes
        closing = close
        controller.hide(.inspector)
        moveAlong()
        if let coordinator = controller.transitionCoordinator {
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self, weak nav] context in
                guard let self, let nav else { return }
                finishInspectorClose(close, in: nav, cancelled: context.isCancelled)
            }
            if paired { changed(); return }
            if queued { return }
        }
        finishInspectorClose(close, in: nav, cancelled: false)
        #endif
    }

    private func finishInspectorClose(_ close: Int, in nav: UINavigationController, cancelled: Bool) {
        guard closing == close else { return }
        closing = nil
        guard !cancelled else { return }
        empty(nav)
        endSlide()
    }

    #if os(iOS)
    /// The split's coordinator can finish without running the inspector's completion.
    func reconcileInspectorClose() {
        guard #available(iOS 26.0, *), let closing, let inspector,
              controller.transitionCoordinator == nil else { return }
        finishInspectorClose(closing, in: inspector, cancelled: controller.isShowing(.inspector))
    }
    #endif

    /// UIKit pops the route the inspector's route is above, which takes the
    /// inspector's route too (`NavigationRules.poppedTop`): the column closes
    /// as the pop begins. UIKit's Back slides it away on the split's own
    /// clock. A swipe's pop carries the column's transition (iOS 27.1): the
    /// column follows the finger, leaves with the page when the swipe goes
    /// back, and comes back with the page when it is let go. Closed only as
    /// the finger lifts or as the pop ends, it would stay until the page had
    /// gone, as UIKit holds a split's change while a swipe's pop finishes.
    /// Let go, UIKit still lays the split out as last asked, without the
    /// column, so the column is shown again at once as the pop ends; asked
    /// for later, it would vanish and slide in again. `inspect(nil)` keeps the
    /// route in the column until the column has gone.
    func closeInspector(along pop: UIViewControllerTransitionCoordinator) {
        if pop.isInteractive, let nav = inspector, let route = nav.viewControllers.first as? RouteController {
            pop.animate(alongsideTransition: nil) { [weak self, weak nav, weak route] context in
                // A batch that took the route while the finger was down left it sliding out: the deferred sync decides
                guard context.isCancelled, let self, let nav, let route, sliding == nil, nav.viewControllers.first === route else { return }
                inspect(route, in: nav, animated: false)
            }
        }
        inspect(nil, in: nil)
    }

    /// UIKit animates the columns into place from a show or hide: what the
    /// routes beside them clear is told inside that animation
    /// (`columnsMove`), so their content moves with the columns, as a
    /// hand-built detail's does.
    private func moveAlong() {
        // One move per transition: a sync before UIKit lays the columns out shows the column again
        guard let coordinator = controller.transitionCoordinator, coordinator !== along else { return }
        along = coordinator
        holdLayout(until: coordinator) { [weak self] in self?.columnsMove() }
    }

    /// Nothing here lays the columns out until `coordinator` opens its animation (`columnsAboutToMove`), which then
    /// runs `alongside`. Only this transition's start or end lets go of its own hold: a later one that took over keeps its own.
    private func holdLayout(until coordinator: UIViewControllerTransitionCoordinator, alongside: (() -> Void)? = nil) {
        aboutToMove = coordinator
        let letGo = { [weak self, weak coordinator] in
            guard let self, let coordinator, aboutToMove === coordinator else { return }
            aboutToMove = nil
        }
        let taken = coordinator.animate(alongsideTransition: { _ in
            letGo()
            alongside?()
        }, completion: { _ in letGo() })
        if !taken { letGo() }
    }
    /// The transition `moveAlong` moves the routes' content in
    private weak var along: UIViewControllerTransitionCoordinator?

    /// Exact's close of the inspector's column, until its transition ends:
    /// UIKit's report of it is not the person's. Each close has its number,
    /// so that an opening or a later close supersedes it.
    private var closing: Int?
    private var closes = 0

    /// The views of the inspector's route a batch destroyed, live while its
    /// column slides out (`NavigationHost.slideOutInspector`).
    var sliding: Leaving?
    /// The sliding route's views go: its column let it go.
    func endSlide() {
        guard let ended = sliding else { return }
        sliding = nil
        for member in ended.members { member.forget() }
        ended.view.removeFromSuperview()
    }

    /// Empty the inspector's column. Its route is Exact's to move (to its
    /// sheet, folded) or to let go, not one UIKit popped: no stack holds it
    /// until Exact writes it again (`RouteController.held`).
    private func empty(_ nav: UINavigationController) {
        let routes = nav.viewControllers.compactMap { $0 as? RouteController }
        nav.setViewControllers([], animated: false)
        for route in routes { route.held = false }
    }

    private func same(_ next: [UIViewController]) -> Bool {
        detail.viewControllers.count == next.count && zip(detail.viewControllers, next).allSatisfy { $0 === $1 }
    }

    // Collapsed, the detail is on top while it holds a route (LLP 1127 D3's answer).
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        expansion = false
        collapsing = true
        laidOutSinceMove = false
        #if os(iOS)
        searchState.beginOwnerMove()
        #endif
        // Collapsing with its inspector shown, UIKit presents the inspector's
        // column as a sheet of its own: the route goes to the sheet it says
        // instead (LLP 1127 D14), and the column, emptied for it, would be a
        // blank sheet over it. Out of the split, the column is not presented.
        #if os(iOS)
        if #available(iOS 26.0, *), let inspector, svc.viewController(for: .inspector) === inspector { svc.setViewController(nil, for: .inspector) }
        #endif
        let hasDetail = detail.viewControllers.contains { $0 is RouteController }
        #if os(iOS)
        if paired {
            searchState.collapseToPrimary = !hasDetail || searchState.primaryForeground
            changed()
            return searchState.collapseToPrimary ? .primary : .secondary
        }
        #endif
        if hasDetail { listWillBeCovered() }
        return hasDetail ? .secondary : .primary
    }

    func splitViewController(_ svc: UISplitViewController,
                             displayModeForExpandingToProposedDisplayMode proposedDisplayMode: UISplitViewController.DisplayMode) -> UISplitViewController.DisplayMode {
        collapsing = false
        expansion = true
        laidOutSinceMove = false
        #if os(iOS)
        if paired {
            searchState.collapseToPrimary = false
            searchState.beginOwnerMove()
            stageForExpansion()
            changed()
            if searchState.primaryForeground && proposedDisplayMode == .secondaryOnly { return .oneOverSecondary }
        }
        #endif
        return proposedDisplayMode
    }

    func splitViewController(_ svc: UISplitViewController, didHide column: UISplitViewController.Column) {
        #if os(iOS)
        guard #available(iOS 26.0, *), column == .inspector, closing == nil, !svc.isCollapsed else { return }
        // A report for a column shown again by then (a swipe let go put it back) is no close of the person's
        DispatchQueue.main.async { if !svc.isShowing(.inspector) { self.inspectorClosed() } }
        #endif
    }

    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        expansion = false
        collapsing = false
        if !paired && !projectionOwed() { show(stack, animated: false) }
        DispatchQueue.main.async { [weak self] in self?.changed() }
    }

    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        collapsing = false
        expansion = false
        let replay = !paired && !projectionOwed()
        if replay { show(stack, animated: false) }
        let pages = left
        if replay && !pages.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, noPageAboveList(), !controller.isCollapsed else { return }
                returnTo(pages)
            }
        }
        DispatchQueue.main.async { self.changed() }
    }
    func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        #if os(iOS)
        searchState.beginOwnerMove()
        #endif
        if let coordinator = svc.transitionCoordinator { holdLayout(until: coordinator) }
        DispatchQueue.main.async { self.changed() }
    }
}

extension NavigationHost {
    /// Whether the stack whose first route is `root` shows as UIKit's split:
    /// its list's rows push, by the runner's rule, under the platform's chrome.
    /// An installed split keeps its list while that list has no row to act on.
    func wantsSplit(_ root: RouteController?) -> Bool {
        // tvOS takes it once a hand-built split is measured with the focus engine (LLP 1127 §4).
        #if os(tvOS)
        return false
        #else
        guard !ExactEnv.authoredChrome, let root, let session = presenter.session else { return false }
        return splitRule(root.node, retaining: split?.listNode, runtime: session.runtime) != nil
        #endif
    }

    /// The split's two columns, each a navigation controller of its own, as
    /// the primary owner.
    func installSplit(_ p: Projection, first: [RouteController], in parent: UIViewController) {
        let list = makeNavigation(first: first.first?.node)
        let detail = makeNavigation(first: nil)
        let split = SplitIOS(list: list, detail: detail)
        #if os(iOS)
        if let root = first.first { split.setSearchOwner(root, children: searchChildIDs(of: root.node)) }
        split.searchState.primaryForeground = first.count == 1
        split.stageForExpansion = { [weak self, weak split] in
            guard let self, let split, self.split === split else { return }
            let awaitingCommit = presenter.applying || Owner.shared.isServingMain || presenter.session?.hasStagedBatches == true
            split.stageExpansion(committedSplitRoutes, awaitingCommit: awaitingCommit)
        }
        #endif
        split.listNode = first.first.flatMap { root in
            presenter.session.flatMap { splitRule(root.node, retaining: nil, runtime: $0.runtime)?.list }
        }
        split.changed = { [weak self, weak split] in
            guard let self, let split, self.split === split else { return }
            splitChanged()
        }
        split.projectionOwed = { [weak self] in self.map { $0.pendingSync || $0.tabsHeld } ?? false }
        split.returnTo = { [weak self] locations in self?.go(to: locations) }
        split.inspectorClosed = { [weak self] in self?.inspectorClosed() }
        split.listWillBeCovered = { [weak split] in (split?.list.viewControllers.first as? RouteController)?.search?.resign() }
        split.noPageAboveList = { [weak self] in self?.shownKeys.count == 1 }
        split.columnsMove = { [weak self] in self?.reportCovers(); self?.presenter.owners.publish() }
        self.split = split
        primaryNavigation = list
        prepareRoutes(Array(first.prefix(1)), in: list)
        prepareRoutes(Array(first.dropFirst()), in: detail)
        detail.setNavigationBarHidden(false, animated: false)
        split.show(first, animated: false)
        noteDetail(split, first)
        for nav in [list, detail] { watchPops(nav) }
        parent.addChild(split.controller)
        let mount = ownerMount(p.root)
        split.controller.view.frame = ownerFrame(split.controller, in: mount)
        split.controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mount.addSubview(split.controller.view)
        split.controller.view.setPaintForeground(aboveAuthored: false)
        fitOwner()
        split.controller.didMove(toParent: parent)
    }

    /// The stack in the split's columns, its routes projected into each.
    func syncSplit(_ split: SplitIOS, _ stack: [RouteController], animated: Bool, reveal: Bool? = nil) {
        let shown = split.shown
        prepareRoutes(Array(stack.prefix(1)), in: split.list)
        prepareRoutes(Array(stack.dropFirst()), in: split.detail)
        split.show(stack, animated: animated, revealsDetail: reveal ?? !stack.elementsEqual(shown, by: ===))
        noteDetail(split, stack)
        if split.shown != shown, split.showsList, let root = stack.first, let runtime = presenter.session?.runtime,
           let list = splitRule(root.node, retaining: nil, runtime: runtime)?.list {
            presenter.groupedLists?.sync(changed: [list])
        }
    }

    func splitRule(_ root: NodeView, retaining list: UInt32?, runtime: Runtime) -> StackSplit? {
        #if os(iOS)
        let field = HeaderShape.bar(of: root)?.search
        let results = searchResult(named: field?.props["accessibilityControls"], in: root)
        return runtime.stackSplit(root.id, retaining: list, excluding: results?.id)
        #else
        return runtime.stackSplit(root.id, retaining: list)
        #endif
    }

    private func noteDetail(_ split: SplitIOS, _ stack: [RouteController]) {
        if split.paired { split.left = []; return }
        let pages = stack.dropFirst()
        guard let root = stack.first, !pages.isEmpty else {
            if split.settledExpanded { split.left = [] }
            return
        }
        let locations = presenter.session?.runtime.stackSplit(root.node.id, retaining: nil)?.locations
        let left = pages.compactMap { locations?[$0.node.id] }
        if left.count == pages.count { split.left = left }
    }

    private func go(to locations: [String]) {
        guard let session = presenter.session, presenter.modals.routes.isEmpty else { return }
        for location in locations {
            unanimated = true
            if let root = container, root.handlers.contains("navigate") { session.navigate(location, at: root) } else { session.hostGo(location) }
        }
        if !inTransition { unanimated = false }
    }

    /// UIKit changed what the split shows: the bars' insets, which columns'
    /// routes are live, and the list's appearance follow.
    func splitChanged() {
        #if os(iOS)
        if split?.paired == true { scheduleSplitProjection(); return }
        #endif
        if let split, !split.moving, split.projectionOwed() { runHeldSync() }
        // Beside the detail, the list and its route are on UIKit's sidebar.
        if let root = split?.list.viewControllers.first as? RouteController { repaintGrounds(root) }
        coversChanged()
        presenter.owners.publish()
        presenter.groupedLists?.sync(changed: nil)
        if selectedRoute?.props["navigationInspector"] == "true", split?.moving != true { resync() }
        settleSearches()
    }

    /// The sheet an expanded split shows as its inspector (`navigationInspector`,
    /// LLP 1127 D14): the stack's one sheet, of one route.
    func inspectorRoute(_ parts: [Range<Int>], _ wanted: [RouteController]) -> RouteController? {
        guard let split, split.inspects, !split.controller.isCollapsed, parts.count == 2, parts[1].count == 1 else { return nil }
        let route = wanted[parts[1].lowerBound]
        return route.node.props["navigationInspector"] == "true" ? route : nil
    }

    /// The route the split's inspector column shows, or none
    /// (`SplitIOS.inspect`); whether the column holds `inspecting` now.
    @discardableResult
    func placeInspector(_ inspecting: RouteController?, animated: Bool = true) -> Bool {
        guard let split else { return false }
        let nav = inspecting.map { split.inspector ?? makeNavigation(first: $0.node) }
        if let nav, let inspecting { prepareRoutes([inspecting], in: nav) }
        let was = split.inspecting
        split.inspect(inspecting, in: nav, animated: animated)
        for route in [was, inspecting].compactMap({ $0 }) where was !== inspecting { repaintGrounds(route) }
        return inspecting != nil && split.inspecting === inspecting
    }

    /// Tells `tell` what is to be told of the routes' boxes, keyed by node.
    /// Inside an animation UIKit has open, the part about routes no frame has
    /// shown (a route a selection shows as the split's columns move, the
    /// inspector's as its column comes in) is told first and still, and
    /// their controllers' views laid out with it: UIKit lays a view out where
    /// it ends before it animates it in, and a new route told inside the
    /// animation moved from where it was laid out before, unseen. The rest,
    /// in a last call that may be empty, moves with the animation.
    func tellStill<A, B>(_ a: [(UInt32, A)], _ b: [(UInt32, B)], _ tell: ([(UInt32, A)], [(UInt32, B)]) -> Void) {
        guard UIView.inheritedAnimationDuration > 0 else { return tell(a, b) }
        var unshown: [UInt32: RouteController] = [:]
        for id in a.map(\.0) + b.map(\.0) {
            guard let node = presenter.views[id],
                  let route = ViewPresentation.controllers(for: node).lazy.compactMap({ $0 as? RouteController }).first,
                  !presenter.showed(route.node) else { continue }
            unshown[id] = route
        }
        guard !unshown.isEmpty else { return tell(a, b) }
        UIView.performWithoutAnimation {
            tell(a.filter { unshown[$0.0] != nil }, b.filter { unshown[$0.0] != nil })
            var laidOut = Set<ObjectIdentifier>()
            for route in unshown.values where laidOut.insert(ObjectIdentifier(route)).inserted { route.viewIfLoaded?.layoutIfNeeded() }
        }
        tell(a.filter { unshown[$0.0] == nil }, b.filter { unshown[$0.0] == nil })
    }

    /// A batch destroys the route the inspector's column shows: its views
    /// stay live while the column slides out, as UIKit keeps a hidden
    /// column's, retired from the presenter as an exit retires a view
    /// (`retire`). They go once the column has let the route go
    /// (`SplitIOS.endSlide`): closed, emptied, or showing another route. A
    /// snapshot of them lacked what UIKit draws live: the segmented
    /// control's glass and the grouped rows' cards.
    func slideOutInspector(_ batch: Batch) {
        guard let split, let route = split.inspector?.topViewController as? RouteController,
              batch.ops.contains(where: { $0.op == .destroy && $0.id == route.node.id }) else { return }
        split.endSlide()
        split.sliding = presenter.retire(route.node.id)
    }

    /// The selected route's key while it is the inspector's (LLP 1127 D14):
    /// a sheet that says `navigationInspector`, which an expanded split shows
    /// in its column above the detail's top. The app's stack says so, not the
    /// column, which a pop under it may already be sliding away
    /// (`SplitIOS.closeInspector`).
    var inspectorKey: String? {
        guard let split, split.inspects, !split.controller.isCollapsed, selectedRoute?.props["navigationInspector"] == "true" else { return nil }
        return selectedKey
    }

    /// The person closed the inspector's column: Back from its route, as a
    /// swipe down that closes its sheet is.
    func inspectorClosed() {
        guard let route = split?.inspector?.viewControllers.first as? RouteController, route.key == selectedKey else { return }
        goBack()
    }

    /// How the split's routes show against the stack's top (LLP 1127 D8),
    /// which the host's checks read and the runner is told: as the columns
    /// show them while nothing is presented over the split, the inspector's
    /// column being the split's own (D14). A presentation covers what is
    /// under it first: under sheets the routes the columns show are shown
    /// and not live; a full-screen one hides them.
    var splitShown: (beside: [RouteController], under: [RouteController]) {
        guard let split else { return ([], []) }
        #if os(iOS)
        if split.paired && !presenter.modals.routes.contains(where: { $0.kind == "fullscreen" }) {
            let list = split.searchOwner
            let detail = split.detail.topViewController as? RouteController
            let state = split.searchState
            let live = (state.primaryExposed ? [list] : []) + (state.detailExposed ? [detail] : [])
            let under = (state.primaryExposed ? [] : [list]) + (state.detailExposed ? [] : [detail])
            return (live.compactMap { $0 }, under.compactMap { $0 })
        }
        #endif
        let over = presenter.modals.routes
        if over.isEmpty { return (split.beside, split.under) }
        return ([], over.allSatisfy { $0.kind == "modal" } ? split.beside + split.under : [])
    }

    /// Whether `id`'s view is the inspector's route's, or in it, live while its column slides out.
    func slidesOut(_ id: UInt32) -> Bool { split?.sliding?.members.contains { $0.id == id } == true }

    /// Whether `view` is in the split's list column while the split is
    /// expanded: UIKit's sidebar, which keeps its look as it slides away (an
    /// inspector coming in on the iPhone Duo hides it) and while hidden.
    func showsAsSidebar(_ view: UIView) -> Bool {
        guard let split, !split.controller.isCollapsed, let list = split.list.viewControllers.first?.viewIfLoaded else { return false }
        return view.isDescendant(of: list)
    }

    /// Whether `view` is in a split's column whose ground is UIKit's: the
    /// list beside its detail (the sidebar), or the inspector, sliding out too.
    func onColumnGround(_ view: UIView) -> Bool {
        if showsAsSidebar(view) { return true }
        if let sliding = split?.sliding?.view, view.isDescendant(of: sliding) { return true }
        guard let route = split?.inspecting?.viewIfLoaded else { return false }
        return view.isDescendant(of: route)
    }

    /// A route's grounds, its grouped lists' and its boxes on the page's
    /// ground follow the column it is in.
    func repaintGrounds(_ route: RouteController) {
        route.paintBackdrop()
        route.node.applyBoxLayer()
        for box in presenter.views.values where box !== route.node && box.paintsPageGround && box.isDescendant(of: route.node) { box.applyBoxLayer() }
        let lists = presenter.carrying("listStyle").filter { $0.kind == "list" && $0.isDescendant(of: route.node) }
        for list in lists { list.applyBoxLayer() }
        if !lists.isEmpty { presenter.groupedLists?.sync(changed: Set(lists.map(\.id))) }
    }

    /// The row of the split's list whose detail shows: the detail's highest
    /// route that is a row's (`StackSplit.rows`), a page beneath what it pushed.
    func sidebarSelection(_ view: UIView) -> UInt32? {
        guard showsAsSidebar(view), let split, let root = split.list.viewControllers.first as? RouteController,
              let runtime = presenter.session?.runtime, let rule = splitRule(root.node, retaining: nil, runtime: runtime) else { return nil }
        return split.detail.viewControllers.reversed().lazy.compactMap { ($0 as? RouteController).flatMap { rule.rows[$0.node.id] } }.first
    }

    /// The split goes. `releasing`, its routes leave its columns first, for
    /// the containers that take them next (`reshape`).
    func retireSplit(releasing: Bool = false) {
        guard let split else { return }
        #if os(iOS)
        if split.paired { split.searchOwner?.detachSearch() }
        FrameClock.shared.drop(split.searchState)
        #endif
        split.endSlide()
        for nav in [split.list, split.detail] + [split.inspector].compactMap({ $0 }) {
            retireStack(nav)
            if releasing { nav.delegate = nil; nav.setViewControllers([], animated: false) }
        }
        split.detail.delegate = nil
        split.controller.willMove(toParent: nil)
        split.controller.view.removeFromSuperview()
        split.controller.removeFromParent()
        self.split = nil
    }
}
#endif
