# CLAUDE.md

Vedi [AGENTS.md](AGENTS.md) per stack, comandi e pattern approvati — questo
file aggiunge come ragionare nel progetto, non lo ripete.

## Come lavorare qui

- Progetto personale a singolo utente: niente sovra-ingegnerizzazione.
  Prima di aggiungere astrazioni (config file, plugin system, ecc.)
  chiediti se serve davvero per un tool con una manciata di domini in una
  lista.
- Ogni cambiamento di comportamento parte da una issue Linear (team
  Mattlicc) con ID tipo `MAT-XX`, un branch `feat/MAT-XX-...`, e una PR
  che referenzia l'issue nel titolo/corpo.
- Una issue = una PR = un cambiamento semantico. Se durante il lavoro
  emerge dell'altro (es. un bug a parte), apri una nuova issue Linear
  invece di infilarlo nella stessa PR.

## Limiti di sicurezza da rispettare sempre

`SiteStore.apply()` scrive `policies.json` in
`Firefox.app/Contents/Resources/distribution/` — su macOS è l'unica posizione
letta da Firefox. La scrittura avviene **direttamente dal processo dell'app**
via syscall POSIX (`mkdir`/`open`/`write`/`rename`), come utente, **senza
`osascript` e senza `administrator privileges`**: è ciò che fa attribuire
l'operazione a FirefoxBlocklist e la rende concedibile in Impostazioni →
Privacy e sicurezza → "Gestione app" (App Management), il gate che autorizza la
scrittura nel bundle. La ri-firma ad-hoc con identifier stabile (in
`scripts/install.sh`, sulla copia in /Applications perché `.build/` sotto
~/Desktop è iCloud-synced e `codesign` fallirebbe) è **obbligatoria** perché
il grant App Management si agganci.

Invarianti da preservare in qualsiasi modifica ad `apply()`:
- **Nessuna scrittura passa da `osascript`/`administrator privileges` o da una
  shell.** (Con quel meccanismo l'operazione è del trampolino root → l'app non
  compare mai in "Gestione app" → stallo.)
- **I domini (input utente) restano confinati nel JSON** generato con
  `JSONSerialization`; non entrano mai in path, comandi o stringhe eseguite.
- La distinzione EPERM (App Management) vs EACCES (POSIX) va letta da `errno`
  delle syscall, non da `NSError` (che collassa in Cocoa 513).

Se una PR tocca `apply()` o `scripts/bundle.sh` (firma), evidenzialo nella
sezione "Risks" del template PR.

## Flusso con altri agenti (Codex)

Se una PR generata da Claude Code viene revisionata da Codex (o
viceversa), chi implementa non si auto-approva: il secondo agente fa
review avversariale prima del merge umano.
