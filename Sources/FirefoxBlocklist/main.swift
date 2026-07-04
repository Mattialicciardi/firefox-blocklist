import SwiftUI

struct BlockedSite: Identifiable, Codable, Equatable {
    let id: UUID
    var domain: String

    init(domain: String) {
        self.id = UUID()
        self.domain = domain
    }
}

final class SiteStore: ObservableObject {
    @Published var sites: [BlockedSite] = []
    @Published var statusMessage: String = ""
    @Published var isApplying: Bool = false

    private let storeURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("FirefoxBlocklist")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("sites.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([BlockedSite].self, from: data) else {
            sites = Self.defaultSites()
            return
        }
        sites = decoded
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        try? data.write(to: storeURL)
    }

    static func defaultSites() -> [BlockedSite] {
        ["facebook.com", "instagram.com", "youtube.com", "tiktok.com", "twitter.com", "x.com"].map(BlockedSite.init)
    }

    func addSite(_ raw: String) {
        let cleaned = Self.normalize(raw)
        guard !cleaned.isEmpty else { return }
        guard !sites.contains(where: { $0.domain == cleaned }) else { return }
        sites.append(BlockedSite(domain: cleaned))
        sites.sort { $0.domain < $1.domain }
        persist()
    }

    func removeSite(at offsets: IndexSet) {
        sites.remove(atOffsets: offsets)
        persist()
    }

    // Strips scheme/www/path and allows only characters valid in a hostname.
    // This value ends up inside a JSON file we write ourselves, never inside a shell string.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://", "www."] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        if let slashIndex = s.firstIndex(of: "/") {
            s = String(s[s.startIndex..<slashIndex])
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !s.isEmpty, s.contains("."), s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return s
    }

    func apply() {
        isApplying = true
        statusMessage = "Applico le modifiche…"

        let patterns = sites.flatMap { site in
            ["*://\(site.domain)/*", "*://*.\(site.domain)/*"]
        }

        let policy: [String: Any] = [
            "policies": [
                "WebsiteFilter": [
                    "Block": patterns,
                    "Exceptions": []
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys]) else {
            statusMessage = "Errore nella generazione del file."
            isApplying = false
            return
        }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("policies-\(UUID().uuidString).json")
        do {
            try jsonData.write(to: tmpURL)
        } catch {
            statusMessage = "Errore scrivendo il file temporaneo."
            isApplying = false
            return
        }

        let destDir = "/Applications/Firefox.app/Contents/Resources/distribution"
        let destFile = destDir + "/policies.json"

        // Only fixed, hardcoded paths are interpolated here — never user-entered text.
        let shellCommand = "mkdir -p \(shellQuote(destDir)) && cp \(shellQuote(tmpURL.path)) \(shellQuote(destFile)) && chmod 644 \(shellQuote(destFile))"
        let appleScript = "do shell script \(appleScriptQuote(shellCommand)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: tmpURL)

            if process.terminationStatus == 0 {
                statusMessage = "✅ Applicato. Riavvia Firefox per attivare i cambiamenti."
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "errore sconosciuto"
                statusMessage = errStr.contains("User canceled") ? "Annullato." : "Errore: \(errStr)"
            }
        } catch {
            statusMessage = "Errore eseguendo il comando privilegiato."
        }

        isApplying = false
    }

    func quitAndRelaunchFirefox() {
        let quit = Process()
        quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        quit.arguments = ["-e", "quit app \"Firefox\""]
        try? quit.run()
        quit.waitUntilExit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-a", "Firefox"]
            try? relaunch.run()
        }
    }
}

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

struct ContentView: View {
    @ObservedObject var store: SiteStore
    @State private var newSite: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Siti bloccati in Firefox")
                    .font(.title2).bold()
                Spacer()
            }
            .padding([.top, .horizontal])

            HStack {
                TextField("es. instagram.com", text: $newSite)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addCurrent)
                Button("Aggiungi", action: addCurrent)
                    .disabled(SiteStore.normalize(newSite).isEmpty)
            }
            .padding()

            List {
                ForEach(store.sites) { site in
                    Text(site.domain)
                }
                .onDelete(perform: store.removeSite)
            }
            .listStyle(.inset)
            .frame(minHeight: 200)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if !store.statusMessage.isEmpty {
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack {
                    Spacer()
                    Button {
                        store.quitAndRelaunchFirefox()
                    } label: {
                        Label("Riavvia Firefox", systemImage: "arrow.clockwise")
                    }
                    Button {
                        store.apply()
                    } label: {
                        if store.isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Applica modifiche", systemImage: "checkmark.shield")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isApplying)
                }
            }
            .padding()
        }
        .frame(width: 420, height: 480)
    }

    private func addCurrent() {
        store.addSite(newSite)
        newSite = ""
    }
}

@main
struct FirefoxBlocklistApp: App {
    @StateObject private var store = SiteStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .windowResizability(.contentSize)
    }
}
