# Testanleitung: NuGet Pruning mit Visual Studio 2026

## 1. Voraussetzungen und erster Build

- Visual Studio 2026, empfohlen ab Version 18.9, mit der Workload **.NET-Desktopentwicklung**. Laut Microsoft ist net10.0 ab VS 18.0 möglich; zur SDK-Featureband 10.0.4xx gehört VS 18.9. Ein aktuellerer installierter VS-2026-Stand ist ebenfalls geeignet.
- **.NET SDK 10.0.402** zusätzlich prüfen. Die Versionsbindung in `global.json` erlaubt keinen automatischen Wechsel auf einen anderen Patchstand. Download: <https://dotnet.microsoft.com/en-us/download/dotnet/10.0>.
- Internetzugang für Microsoft-NuGet-Pakete und Auditdaten. Das eigene Bridge-Paket liegt bereits im ZIP.
- Für die Skripte zusätzlich **PowerShell 7.2+** (`pwsh`). Für das reine Öffnen, Erstellen und Starten in Visual Studio ist PowerShell nicht nötig.

ZIP komplett entpacken. In einem Terminal im Hauptordner zuerst `dotnet --version` aufrufen: erwartet ist `10.0.402`. Dann `NuGetPruning.slnx` öffnen. Das Kontextmenü der Projektmappe bietet **NuGet-Pakete wiederherstellen**; anschließend **Projektmappe erstellen** wählen. Falls der automatische Restore bereits erfolgreich war, reicht der Build.

Die Warnung **NU1510** gehört zu `Consumer.Direct` und ist hier beabsichtigt. Nicht entfernen oder unterdrücken, bevor dieser Fall geprüft ist. `Bridge` und `MultiTarget` sind Bibliotheken; die drei `Consumer.*`-Projekte sind die ausführbaren Szenarien.

## 2. Drei Anwendungen starten und vergleichen

Nacheinander `Consumer.Off`, `Consumer.On` und `Consumer.Direct` im Projektmappen-Explorer mit **Als Startprojekt festlegen** auswählen. Jeweils mit **Strg+F5** starten. Alle drei müssen dieselbe erste Zeile ausgeben:

```text
{"message":"Pruning funktioniert"}
```

Die zweite Zeile zeigt die geladene JSON-Assemblyversion, im geprüften Stand `JSON assembly: 10.0.0.0`. Das ist nicht die Runtime-Patchversion. Der zentrale Befund ist: Die JSON-Funktion bleibt in allen Varianten erhalten.

| Projekt | Pruning | Direkte Referenzen | Erwarteter Restore-Graph |
| --- | --- | --- | --- |
| Consumer.Off | aus | Bridge | Bridge 1.0.0 + System.Text.Json 8.0.5: **2 Pakete** |
| Consumer.On | an | Bridge | nur Bridge 1.0.0: **1 Paket** |
| Consumer.Direct | an | Bridge + System.Text.Json | beide Pakete bleiben: **2 Pakete**, zusätzlich **NU1510** |

Die Einstellungen stehen sichtbar in den jeweiligen `.csproj`-Dateien. Debug und Release verwenden denselben Pruning-Wert. Es ist kein Umschalten per Kommandozeilen-Property nötig, das ein anschließender automatischer VS-Restore wieder verlieren könnte.

## 3. Graph und Paketdownload nachweisen

Im Hauptordner diese drei Befehle ausführen. Durch `--no-restore` lesen sie den vorhandenen Graph, statt ihn neu aufzubauen:

```powershell
dotnet package list --project ./src/Consumer.Off/Consumer.Off.csproj --include-transitive --no-restore
dotnet package list --project ./src/Consumer.On/Consumer.On.csproj --include-transitive --no-restore
dotnet package list --project ./src/Consumer.Direct/Consumer.Direct.csproj --include-transitive --no-restore
```

Bei Off erscheint System.Text.Json unter den transitiven Paketen, bei On fehlt es, bei Direct gehört es zu den direkten Paketen. Zusätzlich lassen sich die JSON-Dateien `src/<Projektname>/obj/project.assets.json` vergleichen. Maßgeblich sind dort `libraries` und `targets`. Eine bloße Volltextsuche nach dem Paketnamen reicht nicht: Die Datei enthält auch Pruning-Metadaten.

Unter `.packages/Consumer.Off/system.text.json/8.0.5` und `.packages/Consumer.Direct/system.text.json/8.0.5` liegt das heruntergeladene Paket. Unter `.packages/Consumer.On` fehlt es bei unverändertem Versuchsaufbau. `packages.lock.json` liegt jeweils direkt neben der Projektdatei und hält den aufgelösten Graph fest. Das Framework zählt nicht als NuGet-Paket in der obigen Tabelle.

Im Direct-Projekt unter `targets` den Eintrag `System.Text.Json/8.0.5` ansehen: Compile- und Runtime-Assets enthalten nur `_._`-Platzhalter. NuGet behält die direkte Referenz im Graph, nimmt ihr aber die Assets und verhindert ihre Weitergabe als Paketabhängigkeit. Das automatische Skript prüft diesen letzten Punkt zusätzlich durch `dotnet pack` und Kontrolle der erzeugten `.nuspec`.

## 4. Multitargeting und automatischer Gesamttest

`MultiTarget` ist eine Bibliothek mit einer direkten System.Text.Json-Referenz und den Zielen `net10.0;netstandard2.0`. Der Solution-Build kompiliert beide Ziele bereits. Für net10.0 bleiben die Paketassets ausgeschlossen; netstandard2.0 benötigt sie weiterhin. Deshalb darf NU1510 hier nicht zum vollständigen Entfernen der Referenz auffordern. Eine eigenständige Anwendung für .NET Standard lässt sich nicht starten.

Den kompletten Vergleich mit frischen Caches ausführen:

```powershell
pwsh -NoProfile -File ./Test-Solution.ps1 -AuditReport
```

Das Skript kopiert die Eingaben in `artifacts/test-<Kennung>/work`, prüft alle fünf Projekte und legt die Belege daneben ab. Die interaktiven Projektdateien und deren `obj`-Verzeichnisse bleiben unberührt. Es setzt seine temporären Umgebungsvariablen zurück und löscht keinen globalen NuGet-Cache. Jeder fehlgeschlagene dotnet-Aufruf oder eine verletzte Ergebnisprüfung beendet den Test mit Fehler. Die seriellen Restore-/Build-Aufrufe mit `-m:1` vermeiden Parallelisierungsprobleme eingeschränkter Testumgebungen; sie ändern die Paketauflösung nicht.

Erfolgsmeldung: **Alle Solution-Pruefungen erfolgreich.** `summary.json` muss Debug- und Release-Build als `passed` sowie `identicalOutput: true` zeigen. Die Szenarien müssen Paketzahlen **2, 1, 2**, NU1510 nur bei Direct und bei MultiTarget `net10JsonAssets: none` / `netstandardJsonAssets: retained` enthalten. In den Szenarioordnern liegen Paketlisten, Assets, Locks, Run-Logs und Locked-Restore-Logs. `-AuditReport` ergänzt `audit.json`. Ein Exitcode 0 dieses Listenbefehls bedeutet allein nicht, dass keine Schwachstellen existieren.

## 5. Bridge-Paket neu bauen und ursprüngliche Demo starten

Das mitgelieferte Paket reicht für den normalen Start. Nach Änderungen am Bridge-Quelltext Visual Studio schließen und im Hauptordner aufrufen:

```powershell
pwsh -NoProfile -File ./Prepare-Demo.ps1 -RebuildPackage
```

Das Skript erstellt Bridge in Release, packt es mit der vorgegebenen nuspec, ersetzt das Paket im lokalen Feed und entfernt ausschließlich die drei zugehörigen Bridge-Einträge in den eigenen Demo-Caches. Anschließend regeneriert es den Restore-Graph und die Lockdateien. Hier dient die gleichbleibende Paketversion 1.0.0 dem lokalen Experiment; bei regulärer Paketveröffentlichung gehören veränderte Inhalte in eine neue Version. Danach die Solution erneut öffnen.

Ohne `-RebuildPackage` führt `Prepare-Demo.ps1` einen erneuten Restore aus; fehlt das lokale Paket, baut es das Skript ebenfalls. Für diesen zweiten Weg ist ein CLI-Build Voraussetzung, nicht nur das Packen per VS-Kontextmenü.

Die ursprüngliche Artikel-Demo liegt separat und unverändert in `OriginalDemo`. Ihr bisheriger Befehl lautet, aus dem Hauptordner ausgeführt:

```powershell
pwsh -NoProfile -File ./OriginalDemo/Test-Pruning.ps1 -IncludeMultiTarget -AuditReport
```

Sie erstellt ihre Belege unter `OriginalDemo/artifacts`. Ihr Consumer-Projekt ist nicht Teil der Visual-Studio-Solution.

## 6. Fehler gezielt einordnen

| Beobachtung | Prüfung / Abhilfe |
| --- | --- |
| SDK nicht gefunden | `dotnet --list-sdks` kontrollieren und exakt SDK 10.0.402 installieren; anschließend VS neu starten. Nur eine Runtime genügt nicht. |
| `pwsh` nicht gefunden | PowerShell 7 installieren oder zunächst ausschließlich die Visual-Studio-Schritte ausführen. |
| Bridge-Paket nicht gefunden | Vollständig entpacktes `feed/PruningDemo.Bridge.1.0.0.nupkg` und `NuGet.Config` prüfen; nötigenfalls Prepare-Demo.ps1 starten. |
| NU1301 / Quelle nicht erreichbar | Zugriff auf nuget.org, Unternehmensproxy und die NuGet-Ausgabe prüfen. |
| NU1510 | Bei Consumer.Direct erwartet; Projektspalte der Fehlerliste beachten. |
| Anwendung lässt sich nicht starten | Eines der drei Consumer-Projekte als Startprojekt auswählen, nicht Bridge oder MultiTarget. |
| Graph nach Experimenten unerwartet | Originalwerte in den csproj-Dateien wiederherstellen und Test-Solution.ps1 mit seiner frischen Arbeitskopie ausführen. |

## Grenzen und Referenzen zur Einrichtung

Der mitgelieferte Prüfstand stammt aus einer Linux-CLI-Umgebung mit .NET SDK 10.0.402. Einen nativen Visual-Studio-2026-Lauf unter Windows konnte diese Umgebung nicht durchführen. Lösungseinlesen, beide Buildkonfigurationen, Programme und Skriptprüfungen sind tatsächlich geprüft; der IDE-Durchlauf ist anhand der obigen Schritte lokal zu bestätigen. Es gibt keine Messung der Performance, keine SBOM-Auswertung und keinen Nachweis einer sicheren Runtime. Paketberichte und Deployment-Inventar bleiben unterschiedliche Prüfgegenstände.

- Microsoft: SDK-, MSBuild- und Visual-Studio-Versionen: <https://learn.microsoft.com/en-us/dotnet/core/porting/versioning-sdk-msbuild-vs>
- Microsoft: Solution-Formate in Visual Studio 2026: <https://learn.microsoft.com/en-us/visualstudio/ide/projects-and-solutions-options-dialog-box?view=vs-2022>
- Microsoft: C#-Workload und Start ohne Debugger: <https://learn.microsoft.com/en-us/visualstudio/get-started/csharp/visual-studio-ide?view=visualstudio>
