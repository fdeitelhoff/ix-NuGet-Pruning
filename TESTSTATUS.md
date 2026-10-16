# Tatsächlich geprüfter Stand

Geprüft mit **.NET SDK 10.0.402**, **PowerShell 7.5.4**, **Ubuntu 24.04.3 LTS** und **.NET Runtime 10.0.13**. Der rohe UTC-Zeitstempel der Testumgebung steht unverändert in `Evidence/summary.json`: `2026-10-15T21:17:32.4751995Z`.

## Ausgeführte Prüfungen

```powershell
pwsh -NoProfile -File ./Prepare-Demo.ps1 -RebuildPackage
pwsh -NoProfile -File ./Test-Solution.ps1 -AuditReport
```

| Prüfung | Ergebnis |
| --- | --- |
| `.slnx` einlesen und fünf Projekte auflisten | erfolgreich |
| Solution-Restore | erfolgreich, erwartete NU1510 bei Consumer.Direct |
| Gesamte Solution in Debug und Release bauen | erfolgreich, auch beide MultiTarget-Ziele |
| Consumer.Off | zwei Pakete, System.Text.Json 8.0.5 transitiv und im eigenen Cache |
| Consumer.On | ein Paket, kein System.Text.Json-Knoten und kein JSON-Download im eigenen Cache |
| Consumer.Direct | zwei Pakete, NU1510, JSON-Compile-/Runtime-Assets nur als Platzhalter |
| Drei Konsolenprogramme | identische Ausgabe: JSON-Nachricht und JSON assembly 10.0.0.0 |
| Locked Restore | alle drei erfolgreich; jeweilige Lockdatei unverändert |
| Direct-Projekt packen | Bridge bleibt als Paketabhängigkeit, System.Text.Json fehlt in der nuspec |
| MultiTarget | JSON-Paketassets bei net10.0 ausgeschlossen, bei netstandard2.0 vorhanden, keine NU1510 |
| Optionale Auditberichte | im Prüfstand kein Befund bei den drei Consumer-Projekten; kein festes Soll für spätere Abfragen |
| Bridge aus Quelltext neu bauen und packen | erfolgreich; danach vollständiger Test erneut ausgeführt |
| Mitgeliefertes Paket und Locks | SHA-512-ContentHash in allen drei Locks entspricht exakt der ausgelieferten nupkg |
| OriginalDemo-Skripte | Test-Pruning.ps1 und CI-Pruefung.ps1 byteidentisch zur vorherigen Artikeldemo |

Die Belege liegen unter `Evidence/`: Summary, Umgebung, Solution-Liste, Restore-/Build-Logs, pro Consumer Paketliste, Assets, Locks, Run-/Locked-Restore-Logs und Auditbericht sowie die Direct-nuspec. Für MultiTarget liegen Assets und Lockdatei bei. `prepare-rebuild.log` dokumentiert die Paketneuerstellung. Absolute Pfade in diesen Originalbelegen gehören zur Testumgebung und sind keine Anweisungen für einen neuen Lauf.

Die Testskripte verwenden serielle Solution-Builds mit `-m:1`. Ein erster paralleler Solution-Restore endete in dieser eingeschränkten Linux-Umgebung ohne NuGet-Fehlerdiagnose mit Exitcode 1; der serielle Aufruf ist erfolgreich. Beim optionalen Neuerstellen des lokalen Testpakets unter derselben Version konnten persistente Build-Server alte Paketmetadaten liefern. Die fertigen Skripte umgehen diese Server deshalb für ihre Restore-Aufrufe mit `--disable-build-servers`; sie stoppen keine globalen Server. Prepare-Demo.ps1 prüft anschließend die Paket-ContentHashes in allen drei Lockdateien. Dieser korrigierte Ablauf ist erfolgreich getestet.

**Nicht durchgeführt:** nativer Windows-/Visual-Studio-2026-UI-Test, Deployment, Laufzeit-Sicherheitsprüfung, Performance-Messung, SBOM-Erzeugung. Die `.slnx`-Datei und alle enthaltenen Projekte sind per .NET CLI geprüft. Die Anleitung beschreibt zusätzlich den lokalen IDE-Durchlauf.

SHA-256 des mitgelieferten Bridge-Pakets: `ccbed6e7128d85313eca1024bc45f317a4871cf7ced3293e74ea40dce986f703`.
