import Foundation

extension SettingsStore {
    struct NemotronLanguage: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable {
        let rawValue: String

        var id: String { self.rawValue }

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.rawValue)
        }

        static let english = Self(rawValue: "en")

        static let allCases: [Self] = [
            "auto", "en", "es", "fr", "it", "pt", "ru", "nl", "de-DE", "pl",
            "cs", "da", "el", "fi", "hu", "ro", "sv", "bg", "et", "hr",
            "lt", "lv", "mt-MT", "sk", "sl", "uk", "ar", "hi", "zh-CN", "ja-JP",
            "ko", "vi-VN", "he-IL", "tr", "nb-NO", "th-TH",
        ].map(Self.init(rawValue:))

        static func supportedLanguage(rawValue: String) -> Self? {
            self.allCases.first { $0.rawValue == rawValue }
        }

        var displayName: String {
            if let name = Self.displayNames[self.rawValue] {
                return name
            }

            let normalized = Self.normalizedIdentifier(self.rawValue)
            let localized = Locale.current.localizedString(forIdentifier: normalized)
                ?? Locale(identifier: "en_US").localizedString(forIdentifier: normalized)
            if let localized, localized.isEmpty == false {
                return "\(localized) (\(self.rawValue))"
            }
            return self.rawValue
        }

        private static let displayNames: [String: String] = [
            "auto": "Auto Detect",
            "en": "English (en)",
            "es": "Spanish (es)",
            "fr": "French (fr)",
            "it": "Italian (it)",
            "pt": "Portuguese (pt)",
            "ru": "Russian (ru)",
            "nl": "Dutch (nl)",
            "de-DE": "German (de-DE)",
            "pl": "Polish (pl)",
            "cs": "Czech (cs)",
            "da": "Danish (da)",
            "el": "Greek (el)",
            "fi": "Finnish (fi)",
            "hu": "Hungarian (hu)",
            "ro": "Romanian (ro)",
            "sv": "Swedish (sv)",
            "bg": "Bulgarian (bg)",
            "et": "Estonian (et)",
            "hr": "Croatian (hr)",
            "lt": "Lithuanian (lt)",
            "lv": "Latvian (lv)",
            "mt-MT": "Maltese (mt)",
            "sk": "Slovak (sk)",
            "sl": "Slovenian (sl)",
            "uk": "Ukrainian (uk)",
            "ar": "Arabic (ar)",
            "hi": "Hindi (hi)",
            "zh-CN": "Chinese (zh-CN)",
            "ja-JP": "Japanese (ja)",
            "ko": "Korean (ko)",
            "vi-VN": "Vietnamese (vi)",
            "he-IL": "Hebrew (he)",
            "tr": "Turkish (tr)",
            "nb-NO": "Norwegian (nb_no)",
            "th-TH": "Thai (th)",
        ]

        private static func normalizedIdentifier(_ identifier: String) -> String {
            switch identifier {
            case "enGB": return "en-GB"
            case "esES": return "es-ES"
            default: return identifier
            }
        }
    }
}
