#!/bin/bash
# Costruisce FirefoxBlocklist.app e lo installa in /Applications.
# /Applications è scrivibile dagli utenti admin senza sudo: nessuna elevazione
# privilegi qui (quella serve solo dentro l'app, per scrivere in Firefox.app).
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FirefoxBlocklist"
BUILT_APP=".build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

./scripts/bundle.sh

if [ ! -w /Applications ]; then
    echo "❌ /Applications non è scrivibile dal tuo utente."
    echo "   Trascina manualmente ${BUILT_APP} in Applicazioni, oppure:"
    echo "   sudo cp -R \"${BUILT_APP}\" /Applications/"
    exit 1
fi

echo "→ Installo in ${DEST}"
rm -rf "${DEST}"
cp -R "${BUILT_APP}" "${DEST}"

# Ri-firma ad-hoc con identifier STABILE (= CFBundleIdentifier), sulla copia in
# /Applications (fuori da iCloud, quindi xattr rimovibili in modo deterministico).
# Obbligatorio: il binario SwiftPM è linker-signed con Identifier=FirefoxBlocklist
# e senza _CodeSignature (codesign --verify fallisce). Senza un'identità di firma
# coerente e verificante, il permesso macOS "Gestione app" NON si aggancia all'app
# → l'utente la abilita ma la scrittura continua a fallire. La firma completa
# sigilla le risorse e allinea l'identità al bundle id.
BUNDLE_ID="com.mattialicciardi.firefoxblocklist"
echo "→ ri-firmo (ad-hoc, identifier ${BUNDLE_ID})"
/usr/bin/xattr -cr "${DEST}"                                    # rimuove FinderInfo/quarantine
codesign --force --sign - --identifier "${BUNDLE_ID}" "${DEST}"
codesign --verify --strict "${DEST}"                            # set -e: fallisce se non verifica

echo "✅ Installato e firmato: ${DEST}"
echo "   Aprilo da Launchpad/Spotlight o con:  open \"${DEST}\""
