import Foundation

enum L10n {
    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("AIusage_AIusage.bundle", isDirectory: true),
           let packagedBundle = Bundle(url: resourceURL) {
            return packagedBundle
        }
        return Bundle.module
    }()

    private static let bundle: Bundle = {
        let supportedLanguages = ["ca", "es", "en"]

        for preferredLanguage in Locale.preferredLanguages {
            let languageCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? preferredLanguage
            guard supportedLanguages.contains(languageCode),
                  let path = resourceBundle.path(forResource: languageCode, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            return localizedBundle
        }

        let fallbackPath = resourceBundle.path(forResource: "es", ofType: "lproj")
        return fallbackPath.flatMap(Bundle.init(path:)) ?? resourceBundle
    }()

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: bundle, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
