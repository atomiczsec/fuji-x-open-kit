import Foundation

enum TerminalText {
    static func escaped(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
            {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
    }
}
