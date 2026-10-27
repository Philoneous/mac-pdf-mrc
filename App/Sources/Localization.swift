// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Übersetzt einen Text der App. Schlüssel ist der deutsche Text; en.lproj/Localizable.strings enthält die englische
/// Fassung (Systemsprache nicht Deutsch → Englisch). Mit Argumenten wird der Text als Format (%@, %lld) verwendet.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Meldung aus der maschinenlesbaren Ergebniszeile von paperless-mrc ("paperless-mrc-result: {…}").
func describeResult(_ result: [String: Any]) -> String {
    func n(_ key: String) -> Int { (result[key] as? NSNumber)?.intValue ?? 0 }
    switch result["reason"] as? String ?? "" {
    case "compressed":
        var parts = [L("%lld KB → %lld KB, %lld Seite(n)", n("size_before") / 1024, n("size_after") / 1024, n("pages"))]
        if n("blank_removed") > 0 { parts.append(L("%lld leere entfernt", n("blank_removed"))) }
        if n("photos") > 0 { parts.append(L("%lld Foto(s) unverändert", n("photos"))) }
        if n("vectorised") > 0 { parts.append(L("%lld vektorisierte gerastert", n("vectorised"))) }
        if n("digital") > 0 { parts.append(L("%lld digitale unverändert", n("digital"))) }
        switch result["text_layer"] as? String {
        case "kept": parts.append(L("Textebene übernommen"))
        case "mixed": parts.append(L("Textebene teils übernommen, teils per Tesseract"))
        default: parts.append(L("Textebene per Tesseract"))
        }
        return parts.joined(separator: ", ")
    case "not_pdf": return L("keine PDF – unverändert")
    case "signed": return L("digital signiert – unverändert, damit die Signatur gültig bleibt")
    case "no_scanned_pages": return L("keine gescannten Seiten – unverändert")
    case "mixed_disabled": return L("enthält nicht gescannte Seiten – unverändert")
    case "nothing_to_compress":
        return L("keine Seite zu komprimieren (%lld Foto, %lld leer) – unverändert", n("photos"), n("blank"))
    case "not_smaller": return L("Ergebnis nicht kleiner (%lld KB) – unverändert", n("size_after") / 1024)
    case "error": return L("Fehler, Datei bleibt unverändert: %@", result["message"] as? String ?? "")
    default: return result["reason"] as? String ?? L("Keine Rückmeldung von paperless-mrc")
    }
}
