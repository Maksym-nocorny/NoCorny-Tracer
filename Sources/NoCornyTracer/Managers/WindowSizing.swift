import SwiftUI
import AppKit

/// WHO OWNS A WINDOW'S SIZE — us, or SwiftUI. In this app the answer is always
/// "us", and this is the one place that says so.
///
/// ROUND 13 — БОЙОВЕ ПАДІННЯ 4.5.0 («застосунок вилітає, якщо увімкнути запис
/// З КАМЕРОЮ», два звіти 27.08 о 16:49). Обидва падіння — той самий
/// НЕПЕРЕХОПЛЕНИЙ ObjC-виняток, кинутий усередині display cycle; у першому звіті
/// він вилетів через `+[NSApplication _crashOnException:]` (SIGTRAP), у другому
/// через `objc_exception_rethrow` → `abort()` (SIGABRT). Текст винятку знято на
/// стенді r13 дослівно:
///
///     NSGenericException
///     The window has been marked as needing another Update Constraints in
///     Window pass, but it has already had more Update Constraints in Window
///     passes than there are views in the window.
///     <CameraOverlayWindow: 0x…> {{120, 114}, {206, 206}}
///
/// Це не одноразова реентерабельність, а ЗАЦИКЛЕННЯ, яке ловить власний
/// запобіжник AppKit: він рахує проходи «update constraints» за один display
/// cycle і кидає виняток, коли їх стало більше, ніж вʼю у вікні. Механізм:
/// `NSHostingController` створюється з ДЕФОЛТНИМИ `sizingOptions`
/// (`.standardBounds`, rawValue 7) — тобто SwiftUI сам ставить рамку вікна під
/// розмір контенту. Це відбувається З СЕРЕДИНИ фази layout
/// (`NSHostingView.windowDidLayout()` → `updateAnimatedWindowSize(_:)`, і
/// дзеркально `NSHostingView.layout()` → `invalidateSizeConstraintsIfNecessary()`),
/// а кожен запис рамки перебудовує `NSNextStepFrame`, будить KVO хостинг-вʼю
/// (`didChangeValue(forKey:)` → `invalidateSafeAreaCornerInsets`) і знову бруднить
/// констрейнти вікна — «ще один прохід». Коло замикається.
///
/// ЧОМУ САМЕ БУЛЬБАШКА КАМЕРИ, А НЕ БАР. Поріг запобіжника — КІЛЬКІСТЬ ВʼЮ У
/// ВІКНІ. У бульбашки їх одиниці (хостинг + прев'ю-шар + рамкове вʼю), тож
/// стелю пробиває вже на третьому-четвертому проході; у бара їх десятки, і та
/// сама метушня в ньому проходить непоміченою. Плюс бар свій розмір SwiftUI
/// ніколи не віддавав — `CommandBarHostingController` пінить `[]` з першого дня.
///
/// ЩО ПЕРЕВІРЕНО НА СТЕНДІ (r13, macOS 26.5.2), щоб не лікувати симптом:
/// - `sizingOptions = []` на хостингу бульбашки — падіння зникає (exit 0);
/// - винесення мутації `styleMask`/`level`/`sharingType` з layout-проходу
///   (`DispatchQueue.main.async`) — НЕ допомагає, падіння лишається (exit 133).
///   Отже «риси вікна» до цієї аварії стосунку не мають і round 12 не винен.
enum WindowSizing {

    /// SwiftUI не рухає вікно і НЕ повідомляє свій розмір: `fittingSize` стає
    /// (0, 0), `intrinsicContentSize` — (-1, -1). Для вікон із ЖОРСТКО заданим
    /// розміром (бар — його рахує `MorphGeometry`; бульбашка камери — сталі
    /// 200×200).
    static let ownedByUs: NSHostingSizingOptions = []

    /// SwiftUI ПУБЛІКУЄ ідеальний розмір контенту (`fittingSize` працює), але
    /// вікна не торкається. Для поверхонь, які ми самі підганяємо під вміст
    /// ОДИН раз при показі — тост і онбординг.
    static let measuredByUsOnly: NSHostingSizingOptions = .intrinsicContentSize

    /// ЧИ МОЖЕ такий набір опцій зрушити ВІКНО. Чиста функція, і регресійний
    /// тест перевіряє саме її, а не обіцянку в коментарі: усі три опції нижче
    /// закінчуються записом у рамку вікна (`.minSize`/`.maxSize` — через
    /// `updateWindowContentSizeExtremaIfNecessary`, `.preferredContentSize` —
    /// через `updateAnimatedWindowSize`), і саме цей запис із середини layout
    /// поклав 4.5.0. `.intrinsicContentSize` лишається безпечним: він тільки
    /// повідомляє розмір вʼю.
    static func mayResizeWindow(_ options: NSHostingSizingOptions) -> Bool {
        !options.intersection([.minSize, .maxSize, .preferredContentSize]).isEmpty
    }

    /// Забирає в SwiftUI кермо від розміру вікна. Пінить І контролер, І його
    /// вʼю: значення контролера не гарантовано доїжджає до вʼю, яку він не
    /// створював (`CommandBarHostingController` підмінює свою у `loadView`), а
    /// відповідає AppKit саме вʼю.
    @discardableResult
    static func pin<Content: View>(
        _ controller: NSHostingController<Content>,
        to options: NSHostingSizingOptions = []
    ) -> NSHostingController<Content> {
        controller.sizingOptions = options
        if let hosting = controller.view as? NSHostingView<Content> {
            hosting.sizingOptions = options
        }
        return controller
    }

    /// Те саме для голої `NSHostingView` (шлях `loadView`, де контролера ще
    /// фактично немає).
    @discardableResult
    static func pin<Content: View>(
        _ hosting: NSHostingView<Content>,
        to options: NSHostingSizingOptions = []
    ) -> NSHostingView<Content> {
        hosting.sizingOptions = options
        return hosting
    }
}
