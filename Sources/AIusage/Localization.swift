import Foundation

enum L10n {
    private static let bundle: Bundle = {
        let supportedLanguages = ["ca", "es", "en"]

        for preferredLanguage in Locale.preferredLanguages {
            let languageCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? preferredLanguage
            guard supportedLanguages.contains(languageCode),
                  let path = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            return localizedBundle
        }

        let fallbackPath = Bundle.module.path(forResource: "es", ofType: "lproj")
        return fallbackPath.flatMap(Bundle.init(path:)) ?? Bundle.module
    }()

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: bundle, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
