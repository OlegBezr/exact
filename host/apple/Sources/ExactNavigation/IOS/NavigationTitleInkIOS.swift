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
    private struct FamilyStyle: Equatable {
        let family: Int
        let heading: NodeStyle?
        let level: Int
        let ink: UIColor?
        let traits: UITraitCollection
        let transparent: Bool
    }
    private var familyStyle: FamilyStyle?
    private var familyAppearances: [FamilyAppearance]?
    var hasHeaderFamily: Bool { familyAppearances != nil }

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

    func update(_ color: UIColor?, fonts: Fonts? = nil, item: UINavigationItem, bar: UINavigationBar?, transparent: Bool) {
        let current = [item.standardAppearance, item.compactAppearance, item.scrollEdgeAppearance, item.compactScrollEdgeAppearance]
        if color == ink, fonts == self.fonts, transparent == self.transparent, current == projected { return }
        ink = color
        self.fonts = fonts
        self.transparent = transparent
        let styled = color != nil || fonts != nil
        if saved == nil, styled || transparent { saved = current }
        guard let saved else { return }
        let base = bar?.standardAppearance ?? UINavigationBarAppearance()
        func painted(_ appearance: UINavigationBarAppearance?) -> UINavigationBarAppearance? {
            guard styled else { return appearance }
            let copy = (appearance ?? base).copy() as! UINavigationBarAppearance
            if let color { copy.titleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.title { copy.titleTextAttributes[.font] = font }
            #if !os(tvOS)
            if let color { copy.largeTitleTextAttributes[.foregroundColor] = color }
            if let font = fonts?.large { copy.largeTitleTextAttributes[.font] = font }
            #endif
            return copy
        }
        let next = [
            painted(saved[0]),
            painted(styled ? saved[1] ?? bar?.compactAppearance : saved[1]),
            painted(transparent ? NavigationHost.clearScrollEdge : styled ? saved[2] ?? bar?.scrollEdgeAppearance : saved[2]),
            painted(transparent ? NavigationHost.clearScrollEdge : styled ? saved[3] ?? bar?.compactScrollEdgeAppearance : saved[3])
        ]
        item.standardAppearance = next[0]
        item.compactAppearance = next[1]
        item.scrollEdgeAppearance = next[2]
        item.compactScrollEdgeAppearance = next[3]
        projected = next
        if !styled, !transparent { self.saved = nil }
    }

    #if os(iOS)
    private typealias Appearance = UINavigationBarAppearance
    private typealias Attributes = ReferenceWritableKeyPath<Appearance, [NSAttributedString.Key: Any]>
    private static let slots: [ReferenceWritableKeyPath<UINavigationItem, Appearance?>] = [
        \.standardAppearance, \.compactAppearance, \.scrollEdgeAppearance, \.compactScrollEdgeAppearance
    ]
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

    /// UIKit copies an item's appearance. Keep the underlying slot (including nil for
    /// inheritance) and the two sides of our edit so a hatch can change that copy.
    private struct FamilyAppearance {
        var original: Appearance?
        var base: Appearance?
        var installed: Appearance?
        var hatchFonts: Set<Attributes> = []
        var clear = false

        mutating func read(_ current: Appearance?) {
            guard current != installed else { return }
            guard let current, let base, let installed else {
                original = current
                hatchFonts.removeAll()
                return
            }
            let copy = current.copy() as! Appearance
            for path in titleAttributes + itemAttributes {
                let drawn = installed[keyPath: path][.font] as? UIFont
                if current[keyPath: path][.font] as? UIFont != drawn {
                    if current[keyPath: path][.font] != nil { hatchFonts.insert(path) }
                    else { hatchFonts.remove(path) }
                } else if base[keyPath: path][.font] as? UIFont != drawn {
                    copy[keyPath: path][.font] = base[keyPath: path][.font]
                }
            }
            for path in titleAttributes {
                let drawn = installed[keyPath: path][.foregroundColor] as? UIColor
                if current[keyPath: path][.foregroundColor] as? UIColor == drawn,
                   base[keyPath: path][.foregroundColor] as? UIColor != drawn {
                    copy[keyPath: path][.foregroundColor] = base[keyPath: path][.foregroundColor]
                }
            }
            if clear { background(of: copy, from: base, replacing: installed) }
            original = copy
        }
    }

    private static func background(of copy: Appearance, from source: Appearance, replacing previous: Appearance? = nil) {
        func take<T: Equatable>(_ path: ReferenceWritableKeyPath<Appearance, T>) {
            if previous == nil || copy[keyPath: path] == previous?[keyPath: path] { copy[keyPath: path] = source[keyPath: path] }
        }
        take(\.backgroundEffect)
        take(\.backgroundColor)
        take(\.backgroundImage)
        take(\.backgroundImageContentMode)
        take(\.shadowImage)
        take(\.shadowColor)
    }

    /// Under Liquid Glass a kept item's label can keep the old appearance font after
    /// a trait change. Setting and releasing just its font makes UIKit resolve the
    /// current appearance again, including its choice of compact or scroll-edge slot.
    private func refreshInheritedItemFonts(_ item: UINavigationItem, in bar: UINavigationBar) {
        guard #available(iOS 26, *), LinkedDesign.liquidGlass, bar.topItem === item else { return }
        let standard = item.standardAppearance ?? bar.standardAppearance
        for button in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) {
            guard button.customView == nil, button.image == nil, button.title?.isEmpty == false else { continue }
            let saved = button.titleTextAttributes(for: .normal)
            guard saved?[.font] == nil else { continue }
            let appearance = button.style == .prominent || button.style == .done ? standard.doneButtonAppearance : standard.buttonAppearance
            guard let font = appearance.normal.titleTextAttributes[.font] else { continue }
            var attrs = saved ?? [:]
            attrs[.font] = font
            button.setTitleTextAttributes(attrs, for: .normal)
            button.setTitleTextAttributes(saved, for: .normal)
        }
    }

    func removeFamily(from item: UINavigationItem, in bar: UINavigationBar?) {
        guard var appearances = familyAppearances else { return }
        for (i, slot) in Self.slots.enumerated() {
            appearances[i].read(item[keyPath: slot])
            if item[keyPath: slot] != appearances[i].original { item[keyPath: slot] = appearances[i].original }
        }
        familyAppearances = nil
        familyStyle = nil
        if let bar { refreshInheritedItemFonts(item, in: bar) }
    }

    func updateFamily(_ family: Int, shape: HeaderShape, item: UINavigationItem, bar: UINavigationBar, transparent: Bool) {
        guard let engine = shape.header.text else { return }
        if familyAppearances == nil {
            if let saved, let projected {
                let defaults = [bar.standardAppearance, bar.compactAppearance, bar.scrollEdgeAppearance, bar.compactScrollEdgeAppearance]
                familyAppearances = saved.indices.map { i in
                    FamilyAppearance(original: saved[i], base: saved[i] ?? defaults[i] ?? bar.standardAppearance,
                                     installed: projected[i], clear: self.transparent && i >= 2)
                }
                self.saved = nil
                self.projected = nil
                self.ink = nil
                fonts = nil
                self.transparent = false
            } else {
                familyAppearances = Self.slots.map { FamilyAppearance(original: item[keyPath: $0]) }
            }
        }
        var appearances = familyAppearances!
        let current = Self.slots.map { item[keyPath: $0] }
        let edited = current != appearances.map(\.installed)
        if edited {
            for i in current.indices { appearances[i].read(current[i]) }
        }
        let sources = [appearances[0].original ?? bar.standardAppearance,
                       appearances[1].original ?? bar.compactAppearance,
                       appearances[2].original ?? bar.scrollEdgeAppearance,
                       appearances[3].original ?? bar.compactScrollEdgeAppearance]
        let heading = shape.heading, ink = heading?.ownUIColor("text_color")
        let traits = bar.traitCollection
        let style = FamilyStyle(family: family, heading: heading?.style, level: shape.level, ink: ink, traits: traits, transparent: transparent)
        var bases = sources
        if transparent {
            bases[2] = sources[2] ?? sources[0]
            bases[3] = sources[3] ?? sources[2] ?? sources[1] ?? sources[0]
        }
        if !edited && style == familyStyle && bases == appearances.map(\.base) { return }
        familyStyle = style
        let inline = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits.inlineBarTraits).pointSize
        let large = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits).pointSize
        let known = family < 8 || engine.catalog[family]?.isEmpty == false
        var changed = false
        for (i, slot) in Self.slots.enumerated() {
            let edge = transparent && i >= 2
            // A nil edge normally derives its background and typography from the standard slot.
            // When transparency requires an explicit edge, start with the same inherited attributes.
            let source = bases[i]
            let copy = source?.copy() as? Appearance
            if let copy {
                if edge { Self.background(of: copy, from: NavigationHost.clearScrollEdge) }
                for path in Self.titleAttributes + Self.itemAttributes {
                    let title = Self.titleAttributes.contains(path)
                    if title, let ink { copy[keyPath: path][.foregroundColor] = ink }
                    guard !appearances[i].hatchFonts.contains(path) else { continue }
                    guard let original = copy[keyPath: path][.font] as? UIFont ?? Self.stock[keyPath: path][.font] as? UIFont else { continue }
                    if let stock = Self.stock[keyPath: path][.font] as? UIFont, original.familyName != stock.familyName { continue }
                    let isLarge = path == \Appearance.largeTitleTextAttributes
                    let stock = Self.stock[keyPath: path][.font] as? UIFont
                    // The appearance stores the default point size. UIKit resolves its stock
                    // fonts in the title's traits, capping the inline title and bar items alike.
                    let base = original == stock ? original.withSize(isLarge ? large : inline) : original
                    let own = title ? heading?.authoredTitleFont(over: base, sized: isLarge == (shape.level == 1)) : nil
                    if title && heading?.authoredFontFamily != nil { copy[keyPath: path][.font] = own }
                    else if known { copy[keyPath: path][.font] = engine.headerFont(own ?? base, family: family) }
                    else if let own { copy[keyPath: path][.font] = own }
                }
            }
            appearances[i].base = source?.copy() as? Appearance
            appearances[i].clear = edge
            appearances[i].installed = copy
            if item[keyPath: slot] != copy {
                item[keyPath: slot] = copy
                changed = true
            }
        }
        familyAppearances = appearances
        if changed { refreshInheritedItemFonts(item, in: bar) }
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
