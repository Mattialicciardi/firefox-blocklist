import SwiftUI

struct BlockedSite: Identifiable, Codable, Equatable {
    let id: UUID
    var domain: String
    // Se false, il sito resta in lista ma NON viene scritto in policies.json
    // (quindi non bloccato). apply() filtra su questo campo.
    var enabled: Bool

    init(id: UUID = UUID(), domain: String, enabled: Bool = true) {
        self.id = id
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
        let sanitized = Self.sanitized(decoded)
        sites = sanitized
        if sanitized != decoded {
            persist()
        }
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(sites) else { return }
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            statusMessage = "Impossibile salvare la lista locale."
        }
    }

    static func defaultSites() -> [BlockedSite] {
        ["facebook.com", "instagram.com", "youtube.com", "tiktok.com", "twitter.com", "x.com"].map { BlockedSite(domain: $0) }
    }

    private static func sanitized(_ decoded: [BlockedSite]) -> [BlockedSite] {
        var seen = Set<String>()
        return decoded.compactMap { site in
            let domain = normalize(site.domain)
            guard !domain.isEmpty, seen.insert(domain).inserted else { return nil }
            return BlockedSite(id: site.id, domain: domain, enabled: site.enabled)
        }
        .sorted { $0.domain < $1.domain }
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
        if let separatorIndex = s.firstIndex(where: { "/?#".contains($0) }) {
            s = String(s[s.startIndex..<separatorIndex])
        }
        if let colonIndex = s.firstIndex(of: ":") {
            let port = s[s.index(after: colonIndex)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return "" }
            s = String(s[s.startIndex..<colonIndex])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !s.isEmpty,
              s.count <= 253,
              s.contains("."),
              s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }

        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return "" }
        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-" else { return "" }
        }
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
        let shellCommand = "/bin/rm -f \(shellQuote(legacyFile)) 2>/dev/null; /bin/mkdir -p \(shellQuote(destDir)) && /bin/cp \(shellQuote(tmpURL.path)) \(shellQuote(destFile)) && /bin/chmod 644 \(shellQuote(destFile))"
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
            Text("\(activeSitesCount) di \(store.sites.count) bloccati")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var activeSitesCount: Int {
        store.sites.filter { $0.enabled }.count
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
        let rowOpacity = site.enabled ? 1.0 : 0.58
        let foregroundStyle: HierarchicalShapeStyle = site.enabled ? .primary : .secondary

        return HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.body)
                .foregroundStyle(site.enabled ? .cyan.opacity(0.72) : .secondary)
                .frame(width: 24)
                .opacity(rowOpacity)

            Text(site.domain)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .textSelection(.enabled)
                .opacity(rowOpacity)

            Spacer()

            Toggle("Blocca \(site.domain)", isOn: Binding(
                get: { site.enabled },
                set: { newValue in
                    store.setEnabled(newValue, for: site)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(site.enabled ? "Disabilita \(site.domain)" : "Abilita \(site.domain)")

            Button {
                remove(site)
            } label: {
                Label("Rimuovi", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .help("Rimuovi \(site.domain)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .opacity(site.enabled ? 1 : 0.82)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let status = statusPresentation {
                statusBanner(status)
            }

            HStack(alignment: .center, spacing: 12) {
                Spacer()

                if isAppliedStatus {
                    applyButton
                        .buttonStyle(.glass)
                    restartButton
                        .buttonStyle(.glassProminent)
                } else {
                    restartButton
                        .buttonStyle(.glass)
                    applyButton
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(statusPresentation?.tint.opacity(0.08)).interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var statusPresentation: StatusPresentation? {
        let message = store.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }

        if store.isApplying {
            return StatusPresentation(
                icon: "progress.indicator",
                title: "Scrittura policy in corso",
                detail: "macOS potrebbe chiedere l'autenticazione.",
                tint: .cyan
            )
        }

        if message.contains("Applicato") {
            return StatusPresentation(
                icon: "checkmark.circle",
                title: "Modifiche applicate",
                detail: "Riavvia Firefox per renderle attive.",
                tint: .cyan
            )
        }

        if message == "Annullato." {
            return StatusPresentation(
                icon: "xmark.circle",
                title: "Operazione annullata",
                detail: "Nessuna modifica alla policy.",
                tint: .secondary
            )
        }

        let detail = message.replacingOccurrences(of: "Errore: ", with: "")
        return StatusPresentation(
            icon: "exclamationmark.triangle",
            title: "Modifiche non applicate",
            detail: detail,
            tint: .orange
        )
    }

    private var isAppliedStatus: Bool {
        store.statusMessage.contains("Applicato") && !store.isApplying
    }

    private func statusBanner(_ status: StatusPresentation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.icon)
                .symbolEffect(.pulse, isActive: store.isApplying)
                .foregroundStyle(status.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.callout.weight(.medium))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var restartButton: some View {
        Button {
            store.quitAndRelaunchFirefox()
        } label: {
            Label("Riavvia Firefox", systemImage: "arrow.clockwise")
        }
    }

    private var applyButton: some View {
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
        .keyboardShortcut(.defaultAction)
        .disabled(store.isApplying)
    }

    private func addCurrent() {
        store.addSite(newSite)
        newSite = ""
    }

    private func remove(_ site: BlockedSite) {
        guard let index = store.sites.firstIndex(of: site) else { return }
        store.removeSite(at: IndexSet(integer: index))
    }

    private struct StatusPresentation {
        let icon: String
        let title: String
        let detail: String
        let tint: Color
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
