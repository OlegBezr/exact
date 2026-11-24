#if os(iOS) || os(tvOS)
import UIKit
import ExactKit

/// Item appearances keep an authored title colour and font local to its route.
final class NavigationTitleInk {
    /// The fonts a heading's authored typography gives the bar's inline and
    /// large titles; nil where it gives that title none (`fonts(of:level:traits:)`).
    struct Fonts: Equatable {
        var title: UIFont?, large: UIFont?
    }

    private var saved: [UINavigationBarAppearance?]?
    private var projected: [UINavigationBarAppearance?]?
    private var ink: UIColor?
    private var fonts: Fonts?
    private var transparent = false

    #if os(iOS)
    /// UIKit's own title fonts, which a row the author left unsaid keeps: the
    /// inline title's `headline` (17-point semibold at the default size) and
    /// the large title's bold `largeTitle` (34 points), each in `traits`
    /// (Dynamic Type, Bold Text).
    static func platformFonts(_ traits: UITraitCollection) -> (title: UIFont, large: UIFont) {
        let large = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits)
        let bold = large.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? large
        return (UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits), bold)
    }

    /// What `heading`'s authored typography gives the bar's titles. Its size
    /// is the title's it is shown as: the large title's for a level-1 heading
    /// (its collapsed inline title keeps UIKit's size), else the inline one's.
    /// Nil when its author wrote none of it, which leaves UIKit's fonts.
    static func fonts(of heading: NodeView?, level: Int, traits: UITraitCollection) -> Fonts? {
        // Read on every projection: most headings write none, and are answered before UIKit's fonts are made.
        guard let heading, ["font_family", "font_weight", "font_style", "font_size"].contains(where: heading.wrote) else { return nil }
        let platform = platformFonts(traits)
        let fonts = Fonts(title: heading.authoredTitleFont(over: platform.title, sized: level != 1),
                          large: heading.authoredTitleFont(over: platform.large, sized: level == 1))
        return fonts.title == nil && fonts.large == nil ? nil : fonts
    }
    #endif

    private(set) var hasHeaderFamily = false

    func update(_ color: UIColor?, fonts: Fonts? = nil, item: UINavigationItem, bar: UINavigationBar?, transparent: Bool,
                family: HeaderFamily? = nil) {
        let current = [item.standardAppearance, item.compactAppearance, item.scrollEdgeAppearance, item.compactScrollEdgeAppearance]
        if family == nil, !hasHeaderFamily, color == ink, fonts == self.fonts, transparent == self.transparent, current == projected { return }
        let styled = color != nil || fonts != nil
        if saved == nil, styled || transparent || family != nil { saved = current }
        guard var saved else { return }
        let standard = bar?.standardAppearance ?? UINavigationBarAppearance()
        let defaults = [standard, bar?.compactAppearance, bar?.scrollEdgeAppearance, bar?.compactScrollEdgeAppearance]
        #if os(iOS)
        if (hasHeaderFamily || family != nil), let projected {
            for i in current.indices where current[i] != projected[i] {
                let inherited = defaults[i] ?? (i == 3 ? saved[2] ?? defaults[2] ?? saved[1] ?? defaults[1] : nil) ?? saved[0] ?? standard
                saved[i] = HeaderFamily.nativeEdit(current[i], after: projected[i], base: saved[i] ?? inherited)
            }
        }
        #endif
        self.saved = saved
        self.ink = color
        self.fonts = fonts
        self.transparent = transparent
        let wasBranded = hasHeaderFamily
        hasHeaderFamily = family != nil
        func painted(_ appearance: UINavigationBarAppearance?) -> UINavigationBarAppearance? {
            guard styled else { return appearance }
            let copy = (appearance ?? standard).copy() as! UINavigationBarAppearance
            if let color { copy.titleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.title { copy.titleTextAttributes[.font] = font }
            #if !os(tvOS)
            if let color { copy.largeTitleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.large { copy.largeTitleTextAttributes[.font] = font }
            #endif
            return copy
        }
        var next = [
            painted(saved[0]),
            painted(styled ? saved[1] ?? defaults[1] : saved[1]),
            painted(transparent ? NavigationHost.clearScrollEdge : styled ? saved[2] ?? defaults[2] : saved[2]),
            painted(transparent ? NavigationHost.clearScrollEdge : styled ? saved[3] ?? defaults[3] : saved[3])
        ]
        #if os(iOS)
        if let family, let bar {
            for i in next.indices {
                guard let base = next[i] ?? defaults[i] else { continue }
                next[i] = family.appearance(over: base, native: saved[i], traits: bar.traitCollection)
            }
        }
        #endif
        if family != nil || wasBranded, next == current { projected = next }
        else {
            item.standardAppearance = next[0]
            item.compactAppearance = next[1]
            item.scrollEdgeAppearance = next[2]
            item.compactScrollEdgeAppearance = next[3]
            projected = next
        }
        if !styled, !transparent, family == nil { self.saved = nil }
    }
}

struct HeaderFamily {
    #if os(iOS)
    let id: Int
    let shape: HeaderShape
    let engine: TextEngine
    init?(_ shape: HeaderShape) {
        guard let id = shape.family, let engine = shape.header.text else { return nil }
        self.id = id
        self.shape = shape
        self.engine = engine
    }
    typealias Appearance = UINavigationBarAppearance
    private typealias Attributes = ReferenceWritableKeyPath<Appearance, [NSAttributedString.Key: Any]>
    private static let itemAttributes: [Attributes] = [
        \.buttonAppearance.normal.titleTextAttributes, \.buttonAppearance.highlighted.titleTextAttributes,
        \.buttonAppearance.disabled.titleTextAttributes, \.buttonAppearance.focused.titleTextAttributes,
        \.doneButtonAppearance.normal.titleTextAttributes, \.doneButtonAppearance.highlighted.titleTextAttributes,
        \.doneButtonAppearance.disabled.titleTextAttributes, \.doneButtonAppearance.focused.titleTextAttributes,
        \.backButtonAppearance.normal.titleTextAttributes, \.backButtonAppearance.highlighted.titleTextAttributes,
        \.backButtonAppearance.disabled.titleTextAttributes, \.backButtonAppearance.focused.titleTextAttributes
    ]
    private static let titleAttributes: [Attributes] = [\.titleTextAttributes, \.largeTitleTextAttributes]
    private static let stock = Appearance()


    func appearance(over base: Appearance, native: Appearance?, traits: UITraitCollection) -> Appearance {
        let copy = base.copy() as! Appearance
        let inline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits.inlineBarTraits).pointSize
        let large = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits).pointSize
        for path in Self.titleAttributes + Self.itemAttributes {
            let stock = Self.stock[keyPath: path][.font] as? UIFont
            if let explicit = native?[keyPath: path][.font] as? UIFont, explicit != stock {
                copy[keyPath: path][.font] = explicit
                continue
            }
            let title = Self.titleAttributes.contains(path)
            let isLarge = path == \Appearance.largeTitleTextAttributes
            let size = isLarge ? large : inline
            guard var source = base[keyPath: path][.font] as? UIFont ?? stock else { continue }
            if title, let heading = shape.heading, heading.authoredFontFamily != nil { continue }
            if title, let heading = shape.heading, !heading.wrote("font_size"), heading.wrote("font_weight") || heading.wrote("font_style") {
                source = source.withSize(size)
            } else if source == stock {
                source = source.withSize(size)
                if traits.legibilityWeight == .bold {
                    let weight: UIFont.Weight
                    if title { weight = isLarge ? .black : .heavy }
                    else if path == \Appearance.doneButtonAppearance.normal.titleTextAttributes { weight = .heavy }
                    else { weight = LinkedDesign.liquidGlass ? .bold : .semibold }
                    source = .systemFont(ofSize: size, weight: weight)
                }
            }
            copy[keyPath: path][.font] = engine.headerFont(source, family: id)
        }
        return copy
    }

    /// An app can change one field on a copy of the item appearance. Import just
    /// its edits into the native slot, including removal of an attribute.
    static func nativeEdit(_ edit: Appearance?, after last: Appearance?, base: Appearance) -> Appearance? {
        guard let edit, let last else { return edit }
        let result = base.copy() as! Appearance
        func field<T: Equatable>(_ path: ReferenceWritableKeyPath<Appearance, T>) {
            if edit[keyPath: path] != last[keyPath: path] { result[keyPath: path] = edit[keyPath: path] }
        }
        func attributes(_ path: Attributes) {
            let before = last[keyPath: path] as NSDictionary, after = edit[keyPath: path] as NSDictionary
            guard !before.isEqual(after) else { return }
            var values = result[keyPath: path]
            for key in Set(last[keyPath: path].keys).union(edit[keyPath: path].keys) {
                if let old = before[key] as? NSObject, old.isEqual(after[key]) { continue }
                values[key] = after[key]
            }
            result[keyPath: path] = values
        }
        field(\.backgroundEffect)
        field(\.backgroundColor)
        field(\.backgroundImage)
        field(\.backgroundImageContentMode)
        field(\.shadowImage)
        field(\.shadowColor)
        field(\.titlePositionAdjustment)
        if #available(iOS 27, *) { field(\.overrideUserInterfaceStyle) }
        if edit.backIndicatorImage != last.backIndicatorImage || edit.backIndicatorTransitionMaskImage != last.backIndicatorTransitionMaskImage {
            result.setBackIndicatorImage(edit.backIndicatorImage, transitionMaskImage: edit.backIndicatorTransitionMaskImage)
        }
        for path in titleAttributes { attributes(path) }
        if #available(iOS 26, *) { attributes(\.subtitleTextAttributes); attributes(\.largeSubtitleTextAttributes) }
        let buttons: [ReferenceWritableKeyPath<Appearance, UIBarButtonItemAppearance>] = [\.buttonAppearance, \.doneButtonAppearance, \.backButtonAppearance]
        let states: [KeyPath<UIBarButtonItemAppearance, UIBarButtonItemStateAppearance>] = [\.normal, \.highlighted, \.disabled, \.focused]
        for button in buttons {
            for state in states {
                let path = button.appending(path: state)
                attributes(path.appending(path: \.titleTextAttributes))
                field(path.appending(path: \.titlePositionAdjustment))
                field(path.appending(path: \.backgroundImage))
                field(path.appending(path: \.backgroundImagePositionAdjustment))
            }
        }
        return result
    }
    #endif
}

#if os(iOS)
extension TextEngine {
    /// UIKit resolves a text-style descriptor back to its system face even after withFamily.
    /// Carry the resolved weight, width and slant into the requested family instead.
    func headerFont(_ base: UIFont, family: Int) -> UIFont {
        let generic = family < 8 ? family : catalog[family]?.first?.generic
        guard generic != nil || catalog[family]?.isEmpty == false else { return base }
        let selected = font(size: base.pointSize, weight: Self.controlWeight(base), family: family,
                            italic: base.fontDescriptor.symbolicTraits.contains(.traitItalic))
        var attributes = base.fontDescriptor.fontAttributes
        attributes.removeValue(forKey: .textStyle)
        attributes.removeValue(forKey: .name)
        attributes.removeValue(forKey: .family)
        var traits = (base.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:])
            .filter { [.weight, .width, .slant].contains($0.key) }
        traits[.symbolic] = base.fontDescriptor.symbolicTraits.intersection([.traitBold, .traitItalic, .traitCondensed, .traitExpanded, .traitVertical]).rawValue
        attributes[.traits] = traits
        let descriptor = generic == nil ? UIFontDescriptor(fontAttributes: attributes).withFamily(selected.familyName)
            : selected.fontDescriptor.addingAttributes(attributes)
        let cascade = selected.fontDescriptor.fontAttributes[.cascadeList]
        let result = cascade.map { descriptor.addingAttributes([.cascadeList: $0]) } ?? descriptor
        return UIFont(descriptor: result, size: base.pointSize)
    }
}
#endif
#endif
