# firefox-blocklist

Mini-app macOS nativa (SwiftUI, nessuna dipendenza) per gestire la lista di siti
bloccati in Firefox tramite il meccanismo enterprise `WebsiteFilter` delle
[policy di Firefox](https://mozilla.github.io/policy-templates/#websitefilter).

Nessuna estensione installata nel browser: la app scrive direttamente
`policies.json` dentro `Firefox.app`.

## Perché

Firefox non ha un pulsante "blocca questo sito" nelle impostazioni. L'unico
modo nativo è editare a mano `policies.json` con `sudo` da terminale. Questa
app dà un'interfaccia per farlo senza reinventare quel passaggio ogni volta.

## Come funziona

1. La lista dei domini bloccati vive in
   `~/Library/Application Support/FirefoxBlocklist/sites.json` (nessun
   privilegio richiesto).
2. Premendo **Applica modifiche**, l'app genera un `policies.json` valido e lo
   copia in `Firefox.app/Contents/Resources/distribution/` tramite
   `osascript ... with administrator privileges` — il prompt di autenticazione
   è quello nativo di macOS (Touch ID/password), la app non vede né salva la
   password. Su macOS questa è l'**unica** posizione da cui Firefox legge le
   policy.
3. **Permesso "Gestione app" (una tantum):** scrivere dentro `Firefox.app` è
   protetto da macOS (*App Management*). Alla prima applicazione, se compare
   l'errore, l'app apre Impostazioni → Privacy e sicurezza → **Gestione app**:
   abilita lì FirefoxBlocklist e ripremi *Applica modifiche*.
4. Dopo l'applicazione, **riavvia Firefox** (le policy si leggono all'avvio) e
   verifica su `about:policies`.
5. Nessun input utente viene mai interpolato in una stringa di shell: il
   comando privilegiato contiene solo percorsi fissi hardcoded.

## Build

Richiede macOS 26+ e i Command Line Tools con SDK macOS 26 (niente Xcode.app).

```bash
./scripts/bundle.sh          # build + assembla FirefoxBlocklist.app
open .build/FirefoxBlocklist.app
```

Serve un vero bundle `.app` (con `Info.plist`) perché macOS lanci l'app come
finestra: un eseguibile SwiftPM "nudo" esce senza mostrare interfaccia. Per la
sola compilazione del binario basta `swift build -c release`.

## Icona

L'icona dell'app è generata in modo riproducibile da uno script locale:

```bash
./scripts/make-icon.sh
```

Lo script costruisce `FirefoxBlocklist.iconset/` e aggiorna
`Resources/AppIcon.icns`, che viene copiato nel bundle da `scripts/bundle.sh`.

## Installazione

Per installare l'app in `/Applications` (visibile in Launchpad/Spotlight):

```bash
./scripts/install.sh
```

Lo script fa il build e copia il bundle in `/Applications`. Non richiede
`sudo`: `/Applications` è scrivibile dagli utenti admin. Ri-eseguirlo aggiorna
l'app installata.

## Verifica

Dopo aver applicato le modifiche e riavviato Firefox, apri `about:policies`
nella barra indirizzi per confermare che `WebsiteFilter` sia attivo con i
domini corretti.

## Limiti noti

Essendo l'utente stesso ad avere i permessi di amministratore sul proprio
Mac, questo è un freno all'impulso, non un blocco a prova di sé stessi: si
può sempre rimuovere `policies.json` a mano.
