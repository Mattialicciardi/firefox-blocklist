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

echo "✅ Installato: ${DEST}"
echo "   Aprilo da Launchpad/Spotlight o con:  open \"${DEST}\""
