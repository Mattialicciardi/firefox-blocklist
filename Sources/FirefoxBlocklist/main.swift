import SwiftUI

struct BlockedSite: Identifiable, Codable, Equatable {
    let id: UUID
    var domain: String
    // Se false, il sito resta in lista ma NON viene scritto in policies.json
    // (quindi non bloccato). apply() filtra su questo campo.
    var enabled: Bool

    init(domain: String, enabled: Bool = true) {
        self.id = UUID()
        self.domain = domain
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, domain, enabled }

    // Migrazione: i sites.json scritti prima di questo campo non hanno `enabled`
    // → li leggiamo come abilitati (comportamento invariato per le liste esistenti).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        domain = try c.decode(String.self, forKey: .domain)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
        ["facebook.com", "instagram.com", "youtube.com", "tiktok.com", "twitter.com", "x.com"].map { BlockedSite(domain: $0) }
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

    // Abilita/disabilita il blocco di un sito senza rimuoverlo dalla lista.
    // Da usare dalla UI (toggle per riga).
    func setEnabled(_ enabled: Bool, for site: BlockedSite) {
        guard let idx = sites.firstIndex(where: { $0.id == site.id }) else { return }
        sites[idx].enabled = enabled
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

        // Solo i domini abilitati finiscono nella policy: i disabilitati restano
        // in lista ma non vengono bloccati.
        let patterns = sites.filter { $0.enabled }.flatMap { site in
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

        // Fuori dal bundle di Firefox.app: posizione ufficiale Mozilla su macOS,
        // scrivibile da root e non soggetta ad App Management (che vieta la scrittura
        // dentro un .app). Sopravvive anche agli aggiornamenti di Firefox.
        let destDir = "/Library/Mozilla/Firefox/policies"
        let destFile = destDir + "/policies.json"
        // Vecchia posizione dentro Firefox.app: rimozione best-effort (App Management
        // può impedirla, ma non deve far fallire la scrittura critica qui sotto).
        let legacyFile = "/Applications/Firefox.app/Contents/Resources/distribution/policies.json"

        // Only fixed, hardcoded paths are interpolated here — never user-entered text.
        // Il cleanup del legacy va PRIMA della catena critica (`;`): così l'exit status
        // finale riflette solo mkdir/cp/chmod e un rm fallito non maschera un errore reale.
        let shellCommand = "rm -f \(shellQuote(legacyFile)) 2>/dev/null; mkdir -p \(shellQuote(destDir)) && cp \(shellQuote(tmpURL.path)) \(shellQuote(destFile)) && chmod 644 \(shellQuote(destFile))"
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
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.55)
                .ignoresSafeArea()

            GlassEffectContainer(spacing: 18) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    addSiteBar
                    domainList
                    footer
                }
                .padding(24)
            }
        }
        .tint(.cyan.opacity(0.55))
        .frame(minWidth: 520, minHeight: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Firefox Blocklist")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("\(store.sites.count) domini bloccati")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var addSiteBar: some View {
        HStack(spacing: 12) {
            Label("Dominio", systemImage: "plus")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)

            TextField("instagram.com", text: $newSite)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit(addCurrent)

            Button("Aggiungi", action: addCurrent)
                .buttonStyle(.glass)
                .disabled(SiteStore.normalize(newSite).isEmpty)
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var domainList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lista")
                .font(.headline)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.sites) { site in
                        domainRow(site)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .glassEffect(.regular.tint(.cyan.opacity(0.08)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func domainRow(_ site: BlockedSite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(site.domain)
                .font(.system(.body, design: .rounded))
                .lineLimit(1)
                .textSelection(.enabled)

            Spacer()

            Button {
                remove(site)
            } label: {
                Label("Rimuovi", systemImage: "minus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .help("Rimuovi \(site.domain)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Spacer()

                Button {
                    store.quitAndRelaunchFirefox()
                } label: {
                    Label("Riavvia Firefox", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)

                Button {
                    store.apply()
                } label: {
                    if store.isApplying {
                        Label {
                            Text("Applica modifiche")
                        } icon: {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Label("Applica modifiche", systemImage: "checkmark.shield")
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isApplying)
            }
        }
        .padding(16)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func addCurrent() {
        store.addSite(newSite)
        newSite = ""
    }

    private func remove(_ site: BlockedSite) {
        guard let index = store.sites.firstIndex(of: site) else { return }
        store.removeSite(at: IndexSet(integer: index))
    }
}

@main
struct FirefoxBlocklistApp: App {
    @StateObject private var store = SiteStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        .defaultSize(width: 560, height: 640)
        .windowResizability(.contentSize)
    }
}
