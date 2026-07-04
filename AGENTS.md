# AGENTS.md

## Stack

- Swift 6.3+, SwiftUI (`@main App`), macOS 26+
- Nessuna dipendenza esterna (no SPM packages di terze parti)
- Build via Swift Package Manager, non Xcode project

## Comandi

```bash
swift build -c release   # build
swift run                 # esegui in dev (finestra SwiftUI)
```

Non ci sono test automatici al momento: la superficie di codice è piccola e
la verifica passa per build + verifica manuale su `about:policies` in
Firefox (vedi README).

## Architettura

- `Sources/FirefoxBlocklist/main.swift`: unico file sorgente.
  - `BlockedSite` / `SiteStore`: modello + persistenza in
    `~/Library/Application Support/FirefoxBlocklist/sites.json`
  - `SiteStore.apply()`: genera `policies.json` e lo scrive in
    `Firefox.app` tramite `osascript ... with administrator privileges`
  - `ContentView`: unica schermata (lista + form aggiungi + pulsanti azione)

## Cosa non toccare / pattern approvati

- **Mai interpolare input utente in una stringa di shell.** Il comando
  privilegiato (`shellCommand` in `apply()`) deve contenere solo percorsi
  fissi hardcoded. Il contenuto variabile (domini) va sempre scritto su
  disco tramite `JSONSerialization`/`JSONEncoder`, mai passato come
  argomento di shell.
- **Mai salvare o gestire la password admin nell'app.** L'unico
  meccanismo di elevazione privilegi ammesso è
  `do shell script ... with administrator privileges` (prompt nativo
  macOS). Niente helper tool privilegiati custom, niente SMJobBless.
- `SiteStore.normalize()` è l'unico punto che valida input utente prima
  che diventi un dominio: non rimuovere la whitelist di caratteri.
- Non introdurre dipendenze esterne senza discuterne prima: l'app deve
  restare auditabile leggendo un solo file.

## Fuori scope (vedi MAT-62 "Out of scope")

Sync multi-dispositivo, Windows/Linux, whitelist a fasce orarie, altri
browser oltre Firefox.
