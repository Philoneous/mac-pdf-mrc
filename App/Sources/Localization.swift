// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Übersetzt einen Text der App. Schlüssel ist der englische Text (Grundsprache); de.lproj/Localizable.strings enthält
/// die deutsche Fassung (Systemsprache nicht Deutsch → Englisch). Mit Argumenten wird der Text als Format (%@, %lld)
/// verwendet.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Meldung aus der maschinenlesbaren Ergebniszeile von paperless-mrc ("paperless-mrc-result: {…}").
func describeResult(_ result: [String: Any]) -> String {
    func n(_ key: String) -> Int { (result[key] as? NSNumber)?.intValue ?? 0 }
    switch result["reason"] as? String ?? "" {
    case "compressed":
        var parts = [L("%lld KB → %lld KB, %lld page(s)", n("size_before") / 1024, n("size_after") / 1024, n("pages"))]
        if n("blank_removed") > 0 { parts.append(L("%lld blank page(s) removed", n("blank_removed"))) }
        if n("photos") > 0 { parts.append(L("%lld photo page(s) unchanged", n("photos"))) }
        if n("vectorised") > 0 { parts.append(L("%lld vectorized page(s) rasterized", n("vectorised"))) }
        if n("digital") > 0 { parts.append(L("%lld digital page(s) unchanged", n("digital"))) }
        switch result["text_layer"] as? String {
        case "kept": parts.append(L("text layer kept"))
        case "mixed": parts.append(L("text layer partly kept, partly recognized with Tesseract"))
        default: parts.append(L("text recognized with Tesseract"))
        }
        return parts.joined(separator: ", ")
    case "not_pdf": return L("not a PDF – unchanged")
    case "signed": return L("digitally signed – unchanged so the signature stays valid")
    case "no_scanned_pages": return L("no scanned pages – unchanged")
    case "mixed_disabled": return L("contains digital pages – unchanged (processing PDFs with digital pages is off)")
    case "nothing_to_compress":
        return L("no page to compress (%lld photo, %lld blank) – unchanged", n("photos"), n("blank"))
    case "not_smaller": return L("result not smaller (%lld KB) – unchanged", n("size_after") / 1024)
    case "error": return L("error, file left unchanged: %@", result["message"] as? String ?? "")
    default: return result["reason"] as? String ?? L("No response from paperless-mrc")
    }
}
