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

Questa app scrive in `Firefox.app/Contents/Resources/distribution/policies.json`
con privilegi elevati — su macOS è l'unica posizione letta da Firefox, e richiede
il permesso "Gestione app" (App Management). Qualsiasi
modifica a `SiteStore.apply()` o alla costruzione del comando shell deve
mantenere la proprietà: **nessuna stringa proveniente dall'utente entra
mai nel comando eseguito con `administrator privileges`**. Se una PR
tocca quella funzione, evidenzialo esplicitamente nella sezione "Risks"
del template PR.

## Flusso con altri agenti (Codex)

Se una PR generata da Claude Code viene revisionata da Codex (o
viceversa), chi implementa non si auto-approva: il secondo agente fa
review avversariale prima del merge umano.
