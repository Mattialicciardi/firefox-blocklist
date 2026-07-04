# Contribuire

Progetto personale — queste regole valgono anche per me stesso e per
qualsiasi agente AI (Claude Code, Codex) che lavora sul repo.

1. **Ogni feature/bug parte da una issue Linear** (team Mattlicc), non da
   un task vago. Vedi `.github/ISSUE_TEMPLATE` per il formato.
2. **Naming**: branch `feat/MAT-XX-descrizione-breve`, commit/PR che
   citano `MAT-XX` nel titolo per l'auto-link Linear↔GitHub.
3. **Niente push diretti su `main`**: sempre branch + PR, anche per
   modifiche minime.
4. **CI deve essere verde** (build) prima del merge.
5. **Una PR = un cambiamento semantico.** Se scopri altro lavoro da fare,
   apri una nuova issue invece di espandere la PR corrente.
6. **Mai eseguire script di install/postinstall non letti** prima di
   aggiungerli al progetto (vale soprattutto per eventuali dipendenze SPM
   future).
