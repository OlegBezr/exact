#if os(iOS) || os(tvOS)
import UIKit
import ExactKit

/// Item appearances keep an authored title colour and font local to its route.
final class NavigationTitleInk {
    /// The fonts this route supplies to UIKit's item appearances.
    struct Fonts: Equatable {
        var title: UIFont?, large: UIFont?, back: UIFont?
        var family: Int?
    }

    private var saved: [UINavigationBarAppearance?]?
    private var projected: [UINavigationBarAppearance?]?
    private var ink: UIColor?
    private var fonts: Fonts?
    private var transparent = false

    var hasHeaderFamily: Bool { fonts?.back != nil }

    #if os(iOS)
    /// UIKit's own title fonts, which a row the author left unsaid keeps: the
    /// inline title's `headline` (17-point semibold at the default size) and
    /// the large title's bold `largeTitle` (34 points), each in `traits`
    /// (Dynamic Type, Bold Text).
    static func platformFonts(_ traits: UITraitCollection, family: Int? = nil) -> (title: UIFont, large: UIFont) {
        let large = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits)
        let bold = large.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? large
        return (.preferredFont(forTextStyle: .headline, compatibleWith: family == nil ? traits : traits.inlineBarTraits), bold)
    }

    /// What `heading`'s authored typography gives the bar's titles. Its size
    /// is the title's it is shown as: the large title's for a level-1 heading
    /// (its collapsed inline title keeps UIKit's size), else the inline one's.
    /// Nil when its author wrote none of it, which leaves UIKit's fonts.
    static func fonts(of shape: HeaderShape?, traits: UITraitCollection) -> Fonts? {
        guard let shape else { return nil }
        let heading = shape.heading, family = shape.family
        // Read on every projection: most headings write none, and are answered before UIKit's fonts are made.
        let styledHeading = heading.map { ["font_family", "font_weight", "font_style", "font_size"].contains(where: $0.wrote) } ?? false
        guard family != nil || styledHeading else { return nil }
        let back: UIFont?
        if let family, let engine = shape.header.text {
            back = HeaderShape.Item.familyFont(family, engine: engine, traits: traits)
        } else { back = nil }
        let platform = platformFonts(traits, family: styledHeading ? nil : family)
        let title = heading?.authoredTitleFont(over: platform.title, sized: shape.level != 1, fallbackFamily: family)
        let large = heading?.authoredTitleFont(over: platform.large, sized: shape.level == 1, fallbackFamily: family)
        return title == nil && large == nil && back == nil ? nil : Fonts(title: title, large: large, back: back, family: family)
    }
    #endif

    private static let slots: [ReferenceWritableKeyPath<UINavigationItem, UINavigationBarAppearance?>] = [
        \.standardAppearance, \.compactAppearance, \.scrollEdgeAppearance, \.compactScrollEdgeAppearance
    ]
    #if os(iOS)
    private static let backStates: [KeyPath<UIBarButtonItemAppearance, UIBarButtonItemStateAppearance>] = [
        \.normal, \.highlighted, \.disabled, \.focused
    ]
    private static let stock = UINavigationBarAppearance()
    #endif

    /// A transparent route owns the edge background while it is visible. Keep other changes a hatch makes there.
    private func background(of view: UINavigationBarAppearance, from source: UINavigationBarAppearance, replacing previous: UINavigationBarAppearance? = nil) {
        func copy<T: Equatable>(_ key: ReferenceWritableKeyPath<UINavigationBarAppearance, T>) {
            if previous == nil || view[keyPath: key] == previous?[keyPath: key] { view[keyPath: key] = source[keyPath: key] }
        }
        copy(\.backgroundEffect)
        copy(\.backgroundColor)
        copy(\.backgroundImage)
        copy(\.backgroundImageContentMode)
        copy(\.shadowColor)
        copy(\.shadowImage)
    }

    /// When a hatch edits our projection, keep its edits in the appearance restored on opt-out.
    private func original(_ current: UINavigationBarAppearance?, last: UINavigationBarAppearance?, saved: UINavigationBarAppearance?,
                          base: UINavigationBarAppearance?, clearEdge: Bool) -> UINavigationBarAppearance? {
        if current == last { return saved }
        guard let current, let last else { return current }
        let result = current.copy() as! UINavigationBarAppearance
        if clearEdge { background(of: result, from: base ?? UINavigationBarAppearance(), replacing: last) }
        func restore(_ attributes: inout [NSAttributedString.Key: Any], _ previous: [NSAttributedString.Key: Any],
                     _ before: [NSAttributedString.Key: Any]?, _ key: NSAttributedString.Key) {
            if let value = attributes[key] as? NSObject, value.isEqual(previous[key]) { attributes[key] = before?[key] }
        }
        if ink != nil { restore(&result.titleTextAttributes, last.titleTextAttributes, base?.titleTextAttributes, .foregroundColor) }
        if fonts?.title != nil { restore(&result.titleTextAttributes, last.titleTextAttributes, base?.titleTextAttributes, .font) }
        #if os(iOS)
        if ink != nil { restore(&result.largeTitleTextAttributes, last.largeTitleTextAttributes, base?.largeTitleTextAttributes, .foregroundColor) }
        if fonts?.large != nil { restore(&result.largeTitleTextAttributes, last.largeTitleTextAttributes, base?.largeTitleTextAttributes, .font) }
        if fonts?.back != nil {
            for state in Self.backStates {
                restore(&result.backButtonAppearance[keyPath: state].titleTextAttributes,
                        last.backButtonAppearance[keyPath: state].titleTextAttributes,
                        base?.backButtonAppearance[keyPath: state].titleTextAttributes, .font)
            }
        }
        #endif
        return result
    }

    func update(_ color: UIColor?, fonts: Fonts? = nil, shape: HeaderShape? = nil, item: UINavigationItem, bar: UINavigationBar?, transparent: Bool) {
        let styled = color != nil || fonts != nil
        guard saved != nil || styled || transparent else { return }
        let current = Self.slots.map { item[keyPath: $0] }
        if color == ink, fonts == self.fonts, transparent == self.transparent, current == projected { return }
        let defaults = [bar?.standardAppearance ?? UINavigationBarAppearance(), bar?.compactAppearance, bar?.scrollEdgeAppearance, bar?.compactScrollEdgeAppearance]
        var originals = saved ?? current
        if let projected, hasHeaderFamily || fonts?.family != nil {
            for i in current.indices {
                originals[i] = original(current[i], last: projected[i], saved: originals[i], base: originals[i] ?? defaults[i],
                                        clearEdge: self.transparent && i >= 2)
            }
        }
        ink = color
        self.fonts = fonts
        self.transparent = transparent
        saved = styled || transparent ? originals : nil
        for (i, slot) in Self.slots.enumerated() {
            let edge = transparent && i >= 2
            let base = originals[i] ?? defaults[i]
            let source: UINavigationBarAppearance?
            if edge { source = hasHeaderFamily ? base ?? NavigationHost.clearScrollEdge : NavigationHost.clearScrollEdge }
            else if !styled { source = originals[i] }
            // A family alone leaves UIKit to derive an unset compact or scroll-edge appearance.
            else { source = hasHeaderFamily ? base : base ?? defaults[0] }
            guard styled, let source else { item[keyPath: slot] = source; continue }
            let copy = source.copy() as! UINavigationBarAppearance
            if edge && hasHeaderFamily { background(of: copy, from: NavigationHost.clearScrollEdge) }
            if let color { copy.titleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.title { copy.titleTextAttributes[.font] = font }
            #if os(iOS)
            if let color { copy.largeTitleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.large { copy.largeTitleTextAttributes[.font] = font }
            if let family = fonts?.family, let heading = shape?.heading {
                if let base = source.titleTextAttributes[.font] as? UIFont, base != Self.stock.titleTextAttributes[.font] as? UIFont {
                    copy.titleTextAttributes[.font] = heading.authoredTitleFont(over: base, sized: shape?.level != 1, fallbackFamily: family)
                }
                if let base = source.largeTitleTextAttributes[.font] as? UIFont, base != Self.stock.largeTitleTextAttributes[.font] as? UIFont {
                    copy.largeTitleTextAttributes[.font] = heading.authoredTitleFont(over: base, sized: shape?.level == 1, fallbackFamily: family)
                }
            }
            if let back = fonts?.back {
                for key in Self.backStates {
                    let state = copy.backButtonAppearance[keyPath: key]
                    let base = state.titleTextAttributes[.font] as? UIFont ?? source.backButtonAppearance.normal.titleTextAttributes[.font] as? UIFont
                    var font = back
                    if let base, base != Self.stock.backButtonAppearance[keyPath: key].titleTextAttributes[.font] as? UIFont,
                       let family = fonts?.family, let engine = shape?.header.text {
                        font = engine.font(size: base.pointSize, weight: TextEngine.controlWeight(base), family: family,
                                           italic: base.fontDescriptor.symbolicTraits.contains(.traitItalic))
                    }
                    state.titleTextAttributes[.font] = font
                }
            }
            #endif
            item[keyPath: slot] = copy
        }
        projected = saved == nil ? nil : Self.slots.map { item[keyPath: $0]?.copy() as? UINavigationBarAppearance }
    }
}
#endif
