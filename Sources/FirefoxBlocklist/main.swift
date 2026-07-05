import SwiftUI
import Darwin   // mkdir, rmdir, open, write, close, rename, chmod, errno, EPERM, EACCES

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

    // Errori di apply(): la distinzione EPERM/EACCES è letta direttamente da errno
    // delle syscall POSIX, non dedotta da NSError (che collassa in Cocoa 513).
    enum ApplyError: Error {
        case appManagementDenied(path: String)   // EPERM  → TCC "Gestione app"
        case ownershipDenied(path: String)        // EACCES → permessi POSIX
        case needsManualCleanup(path: String)     // dir residua root-owned non svuotabile come utente
        case posix(path: String, code: Int32)     // altro errno
    }

    // Path FISSI, hardcoded. Nessun input utente entra mai qui.
    private static let firefoxResources = "/Applications/Firefox.app/Contents/Resources"
    private static let distributionDir  = firefoxResources + "/distribution"
    private static let policiesFile     = distributionDir + "/policies.json"
    private static let staleFile        = "/Library/Mozilla/Firefox/policies/policies.json"

    func apply() {
        isApplying = true
        statusMessage = "Applico le modifiche…"
        defer { isApplying = false }

        // Solo i domini abilitati finiscono nella policy. I domini (input utente)
        // restano confinati nel JSON generato con JSONSerialization: nessuna shell,
        // nessun osascript, nessuna elevazione admin.
        let patterns = sites.filter { $0.enabled }.flatMap { site in
            ["*://\(site.domain)/*", "*://*.\(site.domain)/*"]
        }
        let policy: [String: Any] = [
            "policies": ["WebsiteFilter": ["Block": patterns, "Exceptions": []]]
        ]
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: policy, options: [.prettyPrinted, .sortedKeys]
        ) else {
            statusMessage = "Errore nella generazione del file."
            return
        }

        // Scrittura DIRETTA come processo dell'app (niente osascript/admin): è ciò che
        // fa attribuire l'operazione a FirefoxBlocklist e la registra in "Gestione app"
        // (con osascript+admin l'operazione è del trampolino root → l'app non compare
        // mai in lista). Su macOS Firefox legge le policy SOLO da qui, nel bundle.
        do {
            try writePoliciesDirectly(jsonData)
            cleanupStaleBestEffort()
            statusMessage = "✅ Applicato. Riavvia Firefox per attivare i cambiamenti."
        } catch ApplyError.appManagementDenied {
            // EPERM: App Management blocca la scrittura nel bundle. Questo primo tentativo
            // ha però registrato l'app in "Gestione app": ora è abilitabile.
            statusMessage = "macOS blocca la scrittura in Firefox.app. Abilita \"FirefoxBlocklist\" in Impostazioni → Privacy e sicurezza → Gestione app (le apro ora), poi ripremi Applica."
            openAppManagementSettings()
        } catch ApplyError.ownershipDenied(let path) {
            // EACCES: permessi POSIX, NON risolvibile da Gestione app → nessun pannello.
            statusMessage = "Permessi filesystem insufficienti su \(path). Non è un problema di Gestione app."
        } catch ApplyError.needsManualCleanup(let path) {
            // Vecchia dir root-owned e non vuota: come utente non è svuotabile → serve
            // una rimozione manuale una-tantum col Terminale.
            statusMessage = "C'è una vecchia cartella protetta da rimuovere una volta sola. Apri il Terminale ed esegui:  sudo rm -rf \"\(path)\"  poi ripremi Applica."
        } catch ApplyError.posix(let path, let code) {
            statusMessage = "Errore POSIX \(code) su \(path)."
        } catch {
            statusMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }

    // Scrive policies.json DIRETTAMENTE via syscall POSIX (per leggere errno in modo
    // deterministico: EPERM = App Management, EACCES = POSIX). Contents/Resources è
    // sotto App Management: la PRIMA operazione di scrittura (di norma il mkdir di
    // distribution/) prende EPERM finché l'utente non concede il permesso.
    private func writePoliciesDirectly(_ data: Data) throws {
        var isDir: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: Self.distributionDir, isDirectory: &isDir)

        if existed && !isDir.boolValue {
            try unlinkChecked(Self.distributionDir)   // 'distribution' è un file: rimpiazza
            try mkdirChecked(Self.distributionDir)
        } else if !existed {
            try mkdirChecked(Self.distributionDir)
        }

        do {
            try atomicWrite(data, to: Self.policiesFile, in: Self.distributionDir)
        } catch ApplyError.ownershipDenied {
            // La dir esiste ma non è nostra (residuo root-owned da vecchi sudo):
            // proviamo a bonificarla, poi riproviamo la scrittura.
            try reclaimDistributionDir()
            try atomicWrite(data, to: Self.policiesFile, in: Self.distributionDir)
        }
        chmodBestEffort(Self.policiesFile, 0o644)
    }

    // Bonifica una `distribution/` residua non nostra (root-owned da vecchi sudo).
    // Rimuovere una VOCE dalla dir padre `Resources` (nostra) è permesso, ma `rmdir`
    // richiede la dir VUOTA: proviamo prima a togliere un policies.json residuo
    // (riesce solo se la dir è già nostra). Se la dir è root-owned e non svuotabile
    // come utente, `rmdir` dà ENOTEMPTY/EACCES → serve una rimozione manuale.
    private func reclaimDistributionDir() throws {
        _ = Self.policiesFile.withCString { unlink($0) }   // best-effort
        if Self.distributionDir.withCString({ rmdir($0) }) != 0 {
            let e = errno
            switch e {
            case EPERM:             throw ApplyError.appManagementDenied(path: Self.distributionDir)
            case EACCES, ENOTEMPTY: throw ApplyError.needsManualCleanup(path: Self.distributionDir)
            default:                throw ApplyError.posix(path: Self.distributionDir, code: e)
            }
        }
        try mkdirChecked(Self.distributionDir)
    }

    // Scrittura atomica: file temporaneo nella STESSA dir + rename(2).
    private func atomicWrite(_ data: Data, to finalPath: String, in dir: String) throws {
        let tmpPath = dir + "/.policies-\(UUID().uuidString).tmp"
        let fd = tmpPath.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        if fd < 0 { throw mapErrno(errno, path: tmpPath) }

        var writeErr: Int32 = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let total = raw.count
            while off < total {
                let n = write(fd, base + off, total - off)
                if n <= 0 { writeErr = errno; break }
                off += n
            }
        }
        if writeErr != 0 {
            close(fd)
            _ = tmpPath.withCString { unlink($0) }
            throw mapErrno(writeErr, path: tmpPath)
        }
        if close(fd) != 0 {
            let e = errno
            _ = tmpPath.withCString { unlink($0) }
            throw mapErrno(e, path: tmpPath)
        }

        let renamed = tmpPath.withCString { src in
            finalPath.withCString { dst in rename(src, dst) }
        }
        if renamed != 0 {
            let e = errno
            _ = tmpPath.withCString { unlink($0) }
            throw mapErrno(e, path: finalPath)
        }
    }

    private func mkdirChecked(_ path: String) throws {
        if path.withCString({ mkdir($0, 0o755) }) != 0 { throw mapErrno(errno, path: path) }
    }
    private func unlinkChecked(_ path: String) throws {
        if path.withCString({ unlink($0) }) != 0 { throw mapErrno(errno, path: path) }
    }
    private func chmodBestEffort(_ path: String, _ mode: mode_t) {
        _ = path.withCString { chmod($0, mode) }
    }

    // UNICA fonte di verità EPERM vs EACCES: legge errno grezzo dalla syscall.
    private func mapErrno(_ code: Int32, path: String) -> ApplyError {
        switch code {
        case EPERM:  return .appManagementDenied(path: path)   // 1  → TCC App Management
        case EACCES: return .ownershipDenied(path: path)        // 13 → POSIX
        default:     return .posix(path: path, code: code)
        }
    }

    // Rimuove il file stale scritto in passato FUORI dal bundle (/Library/Mozilla),
    // che Firefox su macOS non legge. Best-effort, silenzioso.
    private func cleanupStaleBestEffort() {
        _ = Self.staleFile.withCString { unlink($0) }
    }

    // Apre Impostazioni di Sistema → Privacy e sicurezza → Gestione app, dove l'utente
    // abilita FirefoxBlocklist (necessario per scrivere dentro Firefox.app).
    func openAppManagementSettings() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"]
        try? p.run()
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
