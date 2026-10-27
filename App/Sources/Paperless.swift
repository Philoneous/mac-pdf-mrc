// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Security

enum PaperlessError: LocalizedError {
    case notConfigured
    case invalidAddress(String)
    case keychain(OSStatus)
    case http(Int, String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("Paperless ist nicht eingerichtet (Adresse und API-Token in der App unter „Paperless“).")
        case .invalidAddress(let address):
            return L("Ungültige Server-Adresse „%@“ (erwartet z. B. https://paperless.example.de).", address)
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return L("Schlüsselbund-Fehler %lld: %@", Int(status), text)
        case .http(let code, _) where code == 401 || code == 403:
            return L("Zugriff verweigert (HTTP %lld) – API-Token prüfen.", code)
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .unexpected(let text):
            return text
        }
    }
}

/// API-Token im macOS-Schlüsselbund (nicht in settings.json).
enum PaperlessToken {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.philoneous.mac-pdf-mrc.paperless",
        kSecAttrAccount as String: "api-token",
    ]

    static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        SecItemDelete(base as CFDictionary)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw PaperlessError.keychain(status) }
    }
}

/// Paperless-ngx-REST-API (geprüft am Quellcode von 3.3.0; ältere Antwortformate werden ebenfalls verstanden).
struct PaperlessClient {
    let base: URL
    let token: String

    enum TaskState {
        case running
        case created(Int?)    // Dokument-ID
        case duplicate(Int?)  // ID des vorhandenen Dokuments
        case failed(String)
    }

    init(address: String, token: String) throws {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { throw PaperlessError.invalidAddress(address) }
        base = url
        self.token = token
    }

    /// Mit Adresse aus den Einstellungen und Token aus dem Schlüsselbund.
    static func configured(_ settings: AppSettings) throws -> PaperlessClient {
        guard !settings.paperlessURL.trimmingCharacters(in: .whitespaces).isEmpty,
              let token = PaperlessToken.load(), !token.isEmpty else { throw PaperlessError.notConfigured }
        return try PaperlessClient(address: settings.paperlessURL, token: token)
    }

    /// Prüft Erreichbarkeit und Token.
    func check() async throws {
        _ = try await send(request("/api/documents/?page_size=1"))
    }

    /// Lädt eine Datei hoch (POST /api/documents/post_document/); Rückgabe: ID der Verarbeitungsaufgabe.
    func upload(_ file: URL, filename: String) async throws -> String {
        let boundary = "mac-pdf-mrc-\(UUID().uuidString)"
        // macOS liefert Umlaute in Pfaden zerlegt (NFD); Browser und Paperless erwarten zusammengesetzte (NFC)
        let safeName = filename.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
        var body = Data()
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"document\"; "
                          + "filename=\"\(safeName)\"\r\nContent-Type: application/pdf\r\n\r\n").utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = request("/api/documents/post_document/")
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let data = try await send(req, body: body)  // URLSession setzt Content-Length (von Paperless verlangt)
        guard let taskID = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
        else { throw PaperlessError.unexpected(L("Unerwartete Antwort von Paperless: %@", String(String(decoding: data, as: UTF8.self).prefix(200)))) }
        return taskID
    }

    /// Stand der Verarbeitung (GET /api/tasks/?task_id=…).
    func state(of taskID: String) async throws -> TaskState {
        let id = taskID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? taskID
        let json = try JSONSerialization.jsonObject(with: try await send(request("/api/tasks/?task_id=\(id)")))
        // ab API-Version 10 (Paperless 3.x) seitenweise ({"results": […]}), davor eine einfache Liste
        let tasks = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        guard let task = tasks.first else { return .running }  // Aufgabe noch nicht angelegt
        let result = task["result_data"] as? [String: Any] ?? [:]
        func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap { Int($0) } }
        if let original = int(result["duplicate_of"]) {
            return .duplicate(original)
        }
        switch (task["status"] as? String ?? "").lowercased() {  // 3.x: "success", davor "SUCCESS"
        case "success":
            return .created(int(result["document_id"]) ?? int(task["related_document"])
                            ?? (task["related_document_ids"] as? [Int])?.first)
        case "failure", "revoked":
            let message = result["error_message"] as? String ?? task["result"] as? String ?? L("unbekannter Fehler")
            return .failed(message)
        default:
            return .running
        }
    }

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: base.absoluteString + path)!)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60
        return req
    }

    private func send(_ req: URLRequest, body: Data? = nil) async throws -> Data {
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await URLSession.shared.upload(for: req, from: body)
        } else {
            (data, response) = try await URLSession.shared.data(for: req)
        }
        guard let http = response as? HTTPURLResponse else { throw PaperlessError.unexpected(L("Keine HTTP-Antwort")) }
        guard (200..<300).contains(http.statusCode) else {
            throw PaperlessError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
