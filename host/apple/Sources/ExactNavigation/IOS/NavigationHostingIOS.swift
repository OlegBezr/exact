// Navigation as the core reaches it (`NavigationLink.swift`): the hosts'
// conformances, and the queries core code asks of routes, which live here
// because they read the family's own types.
#if os(iOS) || os(tvOS)
import UIKit
import ExactKit

extension RouteController: RouteSurface {
    var headerSearchEditor: UIView? {
        #if os(iOS)
        search?.field?.headerField
        #else
        nil
        #endif
    }
    var searchBarEditing: Bool {
        #if os(iOS)
        search?.controller.searchBar.searchTextField.isEditing == true
        #else
        false
        #endif
    }
    var hosting: (any NavigationHosting)? { host }
    #if os(iOS)
    func bandEdges(top: UIScrollView?, bottom: UIScrollView?) {
        if bandedTop !== top { bandedTop = top; projectContentScrollView(automaticTopScroll, for: .top) }
        if bandedBottom !== bottom { bandedBottom = bottom; projectContentScrollView(automaticBottomScroll, for: .bottom) }
    }
    #endif
}

extension PlainTab: BootHolding {
    var routeSurface: (any RouteSurface)? { route }
}

extension ModalHost: ModalHosting {}

extension Presenter {
    /// The family's own hosts, for its code: the slots made them.
    var navigationHost: NavigationHost { navigation as! NavigationHost }
    var modalHost: ModalHost { modals as! ModalHost }
}

extension NavigationHost: NavigationHosting {
    package var lifted: (any LiftedNodes)? { siblings }
    var routeSurfaces: [UInt32: any RouteSurface] { controllers }
    var primaryRouteSurfaces: [any RouteSurface] { primaryRoutes }
    var activeRouteSurface: (any RouteSurface)? { activeRoute }
    var bootHolder: (any BootHolding)? { bootOwner }

    func contentScrollView(of route: any RouteSurface) -> UIScrollView? {
        (route as? RouteController).flatMap { contentScrollView(of: $0) }
    }
    func automaticContentScroller(of route: any RouteSurface) -> NodeView? {
        (route as? RouteController).flatMap { automaticContentScroller(of: $0) }
    }
    func padsTop(_ route: any RouteSurface) -> Bool {
        (route as? RouteController).map { padsTop($0) } ?? false
    }

    func searchResultsParent(of view: UIView) -> NodeView? {
        #if os(iOS)
        if let results = pairedSearch?.results, results.root === view { return results.owner?.node }
        #endif
        return nil
    }

    func measureSearchResults() -> (root: NodeView, view: UIView, block: CGRect, shown: Bool)? {
        #if os(iOS)
        let results = pairedSearch?.results
        results?.refit()
        return results?.block
        #else
        return nil
        #endif
    }

    var searchResultsSurface: UIView? {
        #if os(iOS)
        guard let results = pairedSearch?.results, results.visible else { return nil }
        return results.viewIfLoaded
        #else
        return nil
        #endif
    }

    var searchCoveredNodes: [UInt32] {
        #if os(iOS)
        pairedSearch?.results?.covered.map(\.id) ?? []
        #else
        []
        #endif
    }

    func searchCovers(_ view: UIView) -> Bool {
        #if os(iOS)
        guard let results = pairedSearch?.results else { return false }
        return results.covered.contains { view === $0 || view.isDescendant(of: $0) }
        #else
        return false
        #endif
    }

    func beginSearchActivation(from node: NodeView) -> (() -> Void)? {
        #if os(iOS)
        startPairedActivation(from: node)
        #else
        nil
        #endif
    }

    func beginSearchNavigation() -> (() -> Void)? {
        #if os(iOS)
        guard let split, split.paired else { return nil }
        return startPairedActivation(.incoming, in: split)
        #else
        return nil
        #endif
    }

    var holdsAgentTargets: Bool {
        #if os(iOS)
        guard let split, split.paired else { return false }
        return split.searchState.pending || split.searchState.pop != nil || splitSearchTransition || presenter.modalHost.inTransition
        #else
        return false
        #endif
    }

    func floatingSearchKeyboard(in view: UIView) -> CGRect? {
        #if os(iOS)
        guard presenter.keyboardPolicy != "overlays-content", let occupancy = searchOccupancy(in: view),
              !occupancy.docked, !occupancy.keyboard.isEmpty else { return nil }
        return occupancy.keyboard
        #else
        return nil
        #endif
    }
    func searchContentBlock(in view: UIView) -> CGRect? {
        #if os(iOS)
        guard let split, presenter.keyboardPolicy == "resizes-content",
              let route = ViewPresentation.controller(for: view) as? RouteController, route.surface === view,
              let nav = route.navigationController, split.holds(nav), let occupancy = searchOccupancy(in: view) else { return nil }
        return occupancy.contentBlock(view.bounds, policy: presenter.keyboardPolicy, ignoringKeyboard: SearchClearance.ignoresKeyboard(route.node))
        #else
        return nil
        #endif
    }
    func resignSearch() -> Bool {
        guard let search = searchInUseRoute?.search else { return false }
        search.resign()
        return true
    }
    var splitShownSurfaces: (beside: [any RouteSurface], under: [any RouteSurface]) {
        let shown = splitShown
        return (shown.beside, shown.under)
    }
    func routeShowsBar(_ route: any RouteSurface, in nav: UINavigationController) -> Bool {
        (route as? RouteController).map { routeShowsBar($0, in: nav) } ?? false
    }
    func arrangementPeers(in route: any RouteSurface) -> [NodeView] {
        (route as? RouteController).map { arrangementPeers(in: $0) } ?? []
    }
    func arrangementInsets(_ scroll: UIScrollView, in route: any RouteSurface) -> Bool {
        (route as? RouteController).map { arrangementInsets(scroll, in: $0) } ?? false
    }

    #if EXACT_AGENT
    func searchScopeTabs(of segments: UISegmentedControl) -> [UInt32]? {
        #if os(iOS)
        controllers.values.compactMap(\.search).first(where: { $0.scopeControl === segments })?.scopeTabs
        #else
        nil
        #endif
    }
    #endif

    #if EXACT_AGENT
    func drawnByBar(_ v: NodeView, shown: String) -> String? {
        if tabController != nil, !tablistAppearanceNone, let list = adoptedTablist.flatMap({ presenter.views[$0] }), v === list || v.isDescendant(of: list) {
            return "is in the authored tablist \(shown) UIKit's tab bar"
        }
        for routes in barStackRoutes {
            for case let route as RouteController in routes {
                guard let shape = HeaderShape.bar(of: route.node) else { continue }
                let replaced = shape.authored.isEmpty ? [shape.header] : shape.placed
                if replaced.contains(where: { v === $0 || v.isDescendant(of: $0) }) {
                    return "is in the authored header \(shown) UIKit's navigation bar"
                }
            }
        }
        return nil
    }
    #endif

    /// An authored scroller holds the native container alongside the root's children.
    func ownerMount(_ root: NodeView) -> UIView { root.scroll ?? root }

    /// The primary controller keeps its allocation while route content avoids the keyboard.
    func ownerFrame(_ owner: UIViewController, in root: UIView) -> CGRect {
        let viewport = presenter.viewport
        var frame: CGRect
        if let node = container, node.scroll != nil {
            // Content coordinates stay fixed when the authored scroller moves.
            frame = CGRect(origin: .zero, size: node.bounds.size)
        } else {
            frame = !ExactEnv.authoredChrome && presenter.inDocument(root) ? viewport.convert(viewport.pageBounds, to: root) : root.bounds
        }
        frame.size.height += ownerKeyboardExtension(owner)
        // The authored tablist the agent paints takes its own place in the
        // root, as on the web; the routes end at its edge, not under it.
        if owner === tabOwner, ExactEnv.authoredChrome, let list = adoptedTablist.flatMap({ presenter.views[$0] }),
           list.style["display"]?.string != "none", list.isDescendant(of: root) {
            let rect = list.convert(list.boxBounds, to: root)
            if rect.height > 0, rect.minY >= frame.midY {
                frame.size.height = max(0, min(frame.maxY, rect.minY) - frame.minY)
            } else if rect.height > 0, rect.maxY <= frame.midY {
                let cut = max(0, rect.maxY - frame.minY)
                frame.origin.y += cut
                frame.size.height = max(0, frame.height - cut)
            }
        }
        return frame
    }

    func ownerKeyboardExtension(_ owner: UIViewController) -> CGFloat {
        #if os(iOS)
        if ExactEnv.authoredChrome, owner === primaryOwner, presenter.keyboardPolicy == "resizes-content" { return presenter.keyboardAccessoryHeight }
        #endif
        return 0
    }

    /// Native selection wins over `navigationScroll`, then the first vertical scroller
    /// (LLP 1115.000 D11.1). The bar, scroll-to-top actions and route hatch share this rule.
    func contentScroller(of c: RouteController) -> NodeView? {
        c.nativeContentScrollEdges.contains(.top) ? c.nativeContentScroller : automaticContentScroller(of: c)
    }

    /// The content scroller with no native selection: the one `navigationScroll` names (none when
    /// no scrolling element carries the name), else the first vertical scroller.
    func automaticContentScroller(of c: RouteController) -> NodeView? {
        if let name = c.node.props["navigationScroll"], !name.isEmpty {
            return element(named: name, in: c.node).flatMap { $0.scrollView == nil ? nil : $0 }
        }
        return Presenter.firstVerticalScroller(under: c.node)
    }

    /// The native selection, else the automatic content scroller's scroll view, else, with no
    /// `navigationScroll`, the route's own viewport where it has one.
    func contentScrollView(of route: RouteController) -> UIScrollView? {
        if route.nativeContentScrollEdges.contains(.top) { return route.contentScrollView(for: .top) }
        if let node = automaticContentScroller(of: route) { return shownScroll(node) }
        if let name = route.node.props["navigationScroll"], !name.isEmpty { return nil }
        return route.contentViewport
    }

    /// Follow neutral wrappers only while the named scroller remains the first content at their top
    static func topScroller(_ start: NodeView, target: NodeView?) -> NodeView? {
        guard let target else { return nil }
        var node = start
        while node !== target {
            guard node.scrollView == nil, !node.boxBounds.isEmpty, node.transform.isIdentity,
                  CATransform3DIsIdentity(node.layer.transform),
                  !node.overflowClips, node.clipPath == nil,
                  node.contentBox().minY <= 0.5 else { return nil }
            let children = node.container.subviews.compactMap { $0 as? NodeView }.filter(flowingTopContent)
            // Compare laid-out boxes: a child's frame also holds the safe area it reaches into (`SafeReach`)
            guard let first = children.first, abs(first.boxFrame.minY - node.contentBox().minY) < 1,
                  children.allSatisfy({ $0 === first || $0.boxFrame.minY >= first.boxFrame.maxY - 0.5 }) else { return nil }
            node = first
        }
        return target.scrollView == nil ? nil : target
    }

    static func flowingTopContent(_ node: NodeView) -> Bool {
        (!node.isHidden || node.presenter?.menus.isLaidOut(node) == true) && RouteGeometry.inFlow(node)
    }

    func arrangementScrollers(in route: RouteController, top: Bool) -> [NodeView] {
        #if os(iOS)
        if #available(iOS 27.1, *), !RouteGeometry.insetsNoTop(route.node) { return presenter.arrangements.scrollers(in: route.node, top: top) }
        #endif
        return []
    }

    func arrangementInsets(_ scroll: UIScrollView, in route: RouteController) -> Bool {
        arrangementPeers(in: route).contains { $0.scrollView === scroll }
    }

    func arrangementPeers(in route: RouteController) -> [NodeView] {
        arrangementScrollers(in: route, top: true) + arrangementScrollers(in: route, top: false)
    }

    /// The navigation bar item a shown route's bar draws for `node`, and
    /// the route it is in; nil when no shown bar stands for it, or something
    /// is presented over its route.
    func tipItem(_ node: NodeView) -> (UIBarButtonItem, UIViewController)? {
        for c in controllers.values {
            guard let nav = c.navigationController, nav.topViewController === c, barShows(nav), c.viewIfLoaded?.window != nil,
                  c.isTopForTips, let item = c.barItemsMade[node.id]?.bar else { continue }
            let shown = (c.navigationItem.leftBarButtonItems ?? []) + (c.navigationItem.rightBarButtonItems ?? [])
            if shown.contains(where: { $0 === item }) { return (item, c) }
        }
        return nil
    }

    #if os(iOS)
    /// The bar button item made for an authored header node, in the bar of the route that shows it.
    func barButtonItem(_ node: NodeView) -> (bar: UINavigationBar, item: UIBarButtonItem, of: UINavigationItem)? {
        guard !ExactEnv.authoredChrome else { return nil }
        let testId = node.props["testId"]
        for route in controllers.values {
            guard let controller = route.navigationController, controller.topViewController === route, barShows(controller),
                  route.viewIfLoaded?.window != nil else { continue }
            let items = (route.navigationItem.leftBarButtonItems ?? []) + (route.navigationItem.rightBarButtonItems ?? [])
            guard let item = items.first(where: { ($0.target as? BarPress)?.id == node.id })
                    ?? items.first(where: { $0.target == nil && testId != nil && $0.accessibilityIdentifier == testId }) else { continue }
            return (controller.navigationBar, item, route.navigationItem)
        }
        return nil
    }
    #elseif EXACT_AGENT
    func barButtonItem(_ node: NodeView) -> (bar: UINavigationBar, item: UIBarButtonItem, of: UINavigationItem)? { nil }
    #endif

    /// The navigation bar and, in it, the frame UIKit presents from for an
    /// authored header node's item: the bar's overflow button for an item in
    /// its overflow menu.
    func barItem(_ node: NodeView) -> Result<(bar: UIView, item: CGRect), BarItemMissing>? {
        #if os(iOS)
        guard let (bar, item, _) = barButtonItem(node) else { return nil }
        guard let frame = item.frame(in: bar), frame.width > 0, frame.height > 0 else { return .failure(BarItemMissing()) }
        return .success((bar, frame))
        #else
        return nil
        #endif
    }

    #if EXACT_AGENT
    /// The editor and collapsed button both belong to the top route's search controller.
    #if os(iOS)
    private func searchRoute(for node: NodeView) -> (RouteController, UINavigationController, HeaderSearch)? {
        guard node.headerSearch != nil, !ExactEnv.authoredChrome, !holdsAgentTargets, !isInactiveRoute(containing: node) else { return nil }
        for route in controllers.values {
            guard let nav = route.navigationController, nav.topViewController === route, barShows(nav),
                  route.viewIfLoaded?.window != nil, let search = route.search, search.field === node else { continue }
            return (route, nav, search)
        }
        return nil
    }

    private func hitCenter(of view: UIView) -> UIView? {
        guard let window = view.window, !view.bounds.isEmpty,
              sequence(first: view, next: \.superview).allSatisfy({ !$0.isHidden && $0.alpha > 0.01 }) else { return nil }
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        guard let hit = window.hitTest(point, with: nil), hit.isDescendant(of: view) else { return nil }
        return hit
    }
    #endif

    func drawnSearch(_ node: NodeView) -> UITextField? {
        #if os(iOS)
        guard let (_, _, search) = searchRoute(for: node) else { return nil }
        let field = search.bindEditor()
        return hitCenter(of: field) == nil && !field.isFirstResponder ? nil : field
        #else
        return nil
        #endif
    }

    func searchChrome(_ node: NodeView) -> [String: Any]? {
        #if os(iOS)
        guard let (route, _, search) = searchRoute(for: node) else { return nil }
        let editor = search.bindEditor()
        let placement = route.navigationItem.searchBarPlacement
        let name: String
        switch placement {
        case .automatic: name = "automatic"
        case .inline: name = "inline"
        case .stacked: name = "stacked"
        default:
            if #available(iOS 26.0, *) {
                switch placement {
                case .integrated: name = "integrated"
                case .integratedButton: name = "integratedButton"
                case .integratedCentered: name = "integratedCentered"
                default: name = "unknown"
                }
            } else { name = "unknown" }
        }
        var facts: [String: Any] = ["placement": name, "minimized": node.props["searchStyle"] == "minimized"]
        if editor.window != nil {
            let container = sequence(first: editor as UIView, next: \.superview).lazy.compactMap { view -> String? in
                if view is UINavigationBar { return "navigationBar" }
                if view is UIToolbar { return "toolbar" }
                if view is UITabBar { return "tabBar" }
                return nil
            }.first
            facts["container"] = container ?? "content"
        } else if let button = collapsedSearch(node) {
            facts["container"] = sequence(first: button.view, next: \.superview).contains { $0 is UINavigationBar } ? "navigationBar" : "toolbar"
        }
        return facts
        #else
        return nil
        #endif
    }

    func collapsedSearch(_ node: NodeView) -> (view: UIView, box: CGRect, activate: () -> Bool)? {
        #if os(iOS)
        guard #available(iOS 26.0, *), let (route, nav, search) = searchRoute(for: node), !searching(route),
              let content = route.viewIfLoaded, let window = content.window, let owner = nav.viewIfLoaded else { return nil }
        let editor = search.bindEditor()
        guard !editor.isFirstResponder, hitCenter(of: editor) == nil else { return nil }
        let navigationItem = route.navigationItem
        let item = navigationItem.searchBarPlacementBarButtonItem
        guard item.isEnabled else { return nil }
        let identifier = item.accessibilityIdentifier
        let labels = Set([item.accessibilityLabel, item.title, editor.accessibilityLabel, editor.placeholder, "Search"].compactMap { $0 }.filter { !$0.isEmpty })
        let bars: [UIView] = [nav.navigationBar, nav.toolbar].filter { $0.window === window && !$0.isHidden }
        let spaces = [window as UIView] + bars
        func frames(of item: UIBarButtonItem) -> [CGRect] {
            spaces.compactMap { space in
                guard let frame = item.frame(in: space), !frame.isEmpty, !frame.isInfinite else { return nil }
                return space.convert(frame, to: window)
            }
        }
        let placementFrames = frames(of: item)
        let otherItems = (route.toolbarItems ?? []) + (navigationItem.leftBarButtonItems ?? [])
            + (navigationItem.rightBarButtonItems ?? [])
            + (navigationItem.leadingItemGroups + navigationItem.centerItemGroups + navigationItem.trailingItemGroups).flatMap(\.barButtonItems)
        let otherFrames = otherItems.filter { $0 !== item }.flatMap { frames(of: $0) }
        let canFloat = navigationItem.searchBarPlacementAllowsToolbarIntegration
            && [.integrated, .integratedButton, .integratedCentered].contains(navigationItem.searchBarPlacement)
        var visited = Set<ObjectIdentifier>()
        typealias Target = (view: UIView, box: CGRect, activate: () -> Bool)
        var identified: [ObjectIdentifier: Target] = [:], labelled: [ObjectIdentifier: Target] = [:]

        func add(_ object: NSObject, frame: CGRect, matchesIdentifier: Bool) {
            guard !frame.isEmpty, !frame.isInfinite else { return }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard window.bounds.contains(center), let hit = window.hitTest(center, with: nil),
                  hit !== owner, hit.isDescendant(of: owner), !hit.isDescendant(of: content),
                  !otherFrames.contains(where: { $0.contains(center) }) else { return }
            let ancestors = sequence(first: hit, next: \.superview).prefix { $0 !== owner }
            let matchesItem = matchesIdentifier || placementFrames.contains { $0.contains(center) }
            // UIKit can draw the implicit toolbar outside the two bars the controller exposes.
            // When the placement item has no frame, the unique Search button in this stack's chrome owns the tap.
            guard matchesItem || (placementFrames.isEmpty && (canFloat || ancestors.contains(where: { v in bars.contains { $0 === v } }))) else { return }
            let control = ancestors.first { $0 is UIControl } as? UIControl
            let target = control ?? (object as? UIView) ?? hit
            guard hit.isDescendant(of: target), control?.isEnabled != false else { return }
            let key = ObjectIdentifier(target)
            let action: Target = (target, target.convert(frame, from: window), {
                if object.accessibilityActivate() { return true }
                guard let control, let event = [UIControl.Event.primaryActionTriggered, .touchUpInside].first(where: {
                    control.allControlEvents.contains($0)
                }) else { return false }
                control.sendActions(for: event)
                return true
            })
            if matchesItem { identified[key] = action }
            else { labelled[key] = action }
        }

        func find(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let view = object as? UIView, view !== window,
               view.window !== window || view.isHidden || view.alpha < 0.01 || view.isDescendant(of: content) { return }
            let id = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
            let matchesIdentifier = identifier != nil && id == identifier
            let namedButton = (id?.isEmpty ?? true) && object.accessibilityTraits.contains(.button)
                && !object.accessibilityTraits.contains(.notEnabled) && labels.contains(object.accessibilityLabel ?? "")
            if matchesIdentifier || namedButton {
                let local = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace)
                add(object, frame: local, matchesIdentifier: matchesIdentifier)
            }
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { find(child) }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { find(child) }
                    }
                }
            }
            if let view = object as? UIView {
                for child in view.subviews { find(child) }
            }
        }

        for frame in placementFrames {
            if let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil),
               let control = sequence(first: hit, next: \.superview).prefix(while: { $0 !== owner }).first(where: { $0 is UIControl }) {
                add(control, frame: frame, matchesIdentifier: false)
            }
        }
        find(window)
        let candidates = identified.isEmpty ? labelled : identified
        return candidates.count == 1 ? candidates.values.first : nil
        #else
        return nil
        #endif
    }
    #endif
}

#if os(iOS)
extension RouteController {
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        host?.presenter.elementScrolls.userScrolled(scrollView)
        return true
    }
}
#endif
#endif

#if EXACT_INSPECT && os(iOS)
extension NavigationHost {
    /// Where a route's bar shows `node`: its bar button, title segment, search field or title.
    func inspectPlace(of node: NodeView) -> (() -> CGRect?)? {
        let id = node.id
        for c in controllers.values {
            guard let nav = c.navigationController, nav.topViewController === c else { continue }
            let bar = nav.navigationBar
            let items = (c.navigationItem.leftBarButtonItems ?? []) + (c.navigationItem.rightBarButtonItems ?? [])
            if let item = items.first(where: { c.itemNodes[ObjectIdentifier($0)] == id }) {
                return { [weak bar, weak item] in
                    guard let bar, let item, bar.window != nil, let frame = item.frame(in: bar) else { return nil }
                    return bar.convert(frame, to: nil)
                }
            }
            if let segments = c.titleSegments, let index = segments.press.tabs.firstIndex(of: id) {
                return { [weak control = segments.control] in
                    guard let control, control.window != nil else { return nil }
                    let views = control.segmentViews
                    return views.indices.contains(index) ? views[index].convert(views[index].bounds, to: nil) : nil
                }
            }
            if let search = c.search, search.field === node {
                return { [weak searchBar = search.controller.searchBar] in searchBar.flatMap { $0.window != nil ? $0.searchTextField.convert($0.searchTextField.bounds, to: nil) : nil } }
            }
            if let header = c.shownHeader, header === node || Self.heading(in: header) === node || (c.navigationItem.titleView as? HeaderTitleView)?.groupId == id {
                return { [weak bar, weak c] in
                    guard let bar, let c, bar.window != nil else { return nil }
                    if let title = c.navigationItem.titleView, title.window != nil { return title.convert(title.bounds, to: nil) }
                    return bar.titleFrame(c.navigationItem.title).map { bar.convert($0, to: nil) }
                }
            }
        }
        return nil
    }

    /// The plan node behind a navigation bar's item or title at `p` (in the
    /// bar's coordinates), or nil for UIKit's own parts (Back, the bar).
    func inspectNode(in bar: UINavigationBar, at p: CGPoint) -> UInt32? {
        for c in controllers.values where c.navigationController?.navigationBar === bar && c.navigationController?.topViewController === c {
            let items = (c.navigationItem.leftBarButtonItems ?? []) + (c.navigationItem.rightBarButtonItems ?? [])
            for item in items {
                guard let frame = item.frame(in: bar), frame.contains(p) else { continue }
                if let id = c.itemNodes[ObjectIdentifier(item)] ?? (item.target as? BarPress)?.id { return id }
            }
            // The header's tablist as the title's segments: the tab under the point.
            if let segments = c.titleSegments, segments.control.window != nil, segments.control.convert(segments.control.bounds, to: bar).contains(p) {
                let views = segments.control.segmentViews, tabs = segments.press.tabs
                if views.count == tabs.count, let index = views.firstIndex(where: { $0.convert($0.bounds, to: bar).contains(p) }) { return tabs[index] }
            }
            // The header's search input as the bar's search field.
            if let search = c.search, let field = search.field {
                let searchBar = search.controller.searchBar
                if searchBar.window != nil, searchBar.convert(searchBar.bounds, to: bar).contains(p) { return field.id }
            }
            // The title UIKit draws (the label showing this route's title, not
            // Back's): the route header's heading.
            if let header = c.shownHeader, let title = bar.titleFrame(c.navigationItem.title), title.contains(p) { return Self.heading(in: header)?.id ?? header.id }
        }
        return nil
    }

    /// The heading in a route's header, the title the bar shows for it.
    private static func heading(in header: NodeView) -> NodeView? {
        var pending: [NodeView] = [header]
        while !pending.isEmpty {
            let node = pending.removeFirst()
            if node.props["accessibilityRole"] == "heading" { return node }
            pending += node.container.subviews.compactMap { $0 as? NodeView }
        }
        return nil
    }
}
#endif

#if EXACT_INSPECT && os(iOS)
extension NavigationHost {
    func inspectTitle(_ view: UIView) -> UInt32? { (view as? HeaderTitleView)?.groupId }
}
#endif

#if EXACT_AGENT && (os(iOS) || os(tvOS))
extension NavigationHost {
    func submitSearch(_ editor: UITextField) -> Bool {
        #if os(iOS)
        guard let search = editor.delegate as? HeaderSearch else { return false }
        let bar = search.controller.searchBar
        bar.delegate?.searchBarSearchButtonClicked?(bar)
        return true
        #else
        return false
        #endif
    }
}
#endif
