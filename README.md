# NuGet Package Pruning in Visual Studio 2026

Drei direkt startbare Konsolenprojekte zeigen denselben JSON-Aufruf mit unterschiedlichen NuGet-Graphen. `Consumer.Off` enthält zwei Pakete, `Consumer.On` nur eines; `Consumer.Direct` zeigt zusätzlich den Sonderfall einer direkten Referenz. Der Bridge-Quelltext und ein Multitargeting-Beispiel liegen in derselben Solution.

## Schnellstart

1. ZIP vollständig entpacken, beispielsweise nach `C:\Demos\NuGetPruning`.
2. Visual Studio 2026 mit der Workload **.NET-Desktopentwicklung** verwenden; empfohlen ist **18.9 oder neuer**. Zusätzlich muss das **.NET SDK 10.0.402** installiert sein. `global.json` verlangt diese Version exakt. Mit `dotnet --list-sdks` prüfen; im Demo-Ordner muss `dotnet --version` den Wert `10.0.402` liefern.
3. `NuGetPruning.slnx` öffnen, NuGet-Restore abwarten oder über das Kontextmenü der Projektmappe **NuGet-Pakete wiederherstellen** starten. Danach die Projektmappe erstellen.
4. `Consumer.Off` per Rechtsklick **Als Startprojekt festlegen** auswählen und mit **Strg+F5** starten. Anschließend mit `Consumer.On` und `Consumer.Direct` wiederholen.

Das lokale Paket `feed/PruningDemo.Bridge.1.0.0.nupkg` liegt bereits bei. Ein vorbereitender Skriptlauf ist für diesen Einstieg nicht nötig. Für die Microsoft-Pakete und NuGet Audit benötigt der Restore Internetzugang zu nuget.org. `NU1510` beim Projekt `Consumer.Direct` ist das erwartete Ergebnis, kein Defekt der Demo. Beim Erstellen der ganzen Solution kann diese Warnung auch erscheinen, wenn gerade `Consumer.Off` als Startprojekt ausgewählt ist.

Die genaue Anleitung mit Prüfschritten, erwarteten Ergebnissen und Fehlerhilfe steht in **Testanleitung.md**. **TESTSTATUS.md** dokumentiert den tatsächlich geprüften Stand.

## Projekte und Dateien

| Pfad | Zweck |
| --- | --- |
| `NuGetPruning.slnx` | Native XML-Solution für Visual Studio 2026 und die .NET CLI |
| `src/Consumer.Off` | `RestoreEnablePackagePruning=false`, nur Bridge direkt referenziert |
| `src/Consumer.On` | `RestoreEnablePackagePruning=true`, nur Bridge direkt referenziert |
| `src/Consumer.Direct` | Pruning aktiv, Bridge und System.Text.Json direkt referenziert |
| `src/MultiTarget` | Zusatztest für `net10.0;netstandard2.0`, Bibliothek ohne Startprogramm |
| `src/Bridge` | Quelltext des lokalen NuGet-Pakets, keine ProjectReference der Consumer |
| `feed` | Mitgeliefertes lokales Bridge-Paket |
| `Prepare-Demo.ps1` | Optionaler Restore; mit `-RebuildPackage` lokales Bridge-Paket neu erzeugen |
| `Test-Solution.ps1` | Automatischer Vergleich in einer frischen temporären Arbeitskopie |
| `Evidence` | Kompakte Belege des mitgelieferten Prüfstands |
| `OriginalDemo` | Bisherige Artikel-Demo mit unverändertem Test-Pruning.ps1 |

Jedes Projekt besitzt ein eigenes `obj` und `bin`. `Directory.Build.props` legt zusätzlich getrennte Paketverzeichnisse unter `.packages/<Projektname>` fest. So lässt sich der unterlassene System.Text.Json-Download im On-Szenario nachvollziehen, obwohl Off und Direct das Paket benötigen. `NuGet.Config` bindet `PruningDemo.*` an den lokalen Feed. Die übrigen Pakete stammen von nuget.org.

## Automatischer Test

PowerShell **7.2 oder neuer** installieren (`pwsh`); Windows PowerShell 5.1 reicht nicht. Im entpackten Hauptordner:

```powershell
pwsh -NoProfile -File ./Test-Solution.ps1 -AuditReport
```

Das Skript prüft Restore, Debug- und Release-Build, Programmausgabe, Paketzahl, getrennte Paket-Caches, Lockdateien, NU1510, Paketassets, die beim Packen weitergegebenen Abhängigkeiten und beide Multitargeting-Ziele. `-AuditReport` ergänzt zeitabhängige Schwachstellenberichte; deren Inhalt ist kein festes Soll-Ergebnis. Der Durchlauf liegt unter `artifacts/test-<Kennung>`, die Zusammenfassung in `summary.json`.

## Hintergrund

Bridge serialisiert tatsächlich JSON; alle Consumer lesen es erneut ein. Die eigene `Bridge.nuspec` hält absichtlich eine für net10.0 redundante Paketabhängigkeit auf System.Text.Json mit Mindestversion 8.0.5 fest. Damit bleibt die interessante transitive NuGet-Kante erhalten. Ein ProjectReference würde diesen Paketvertrag umgehen. Eine normale Paketproduktion könnte die redundante Referenz schon auf Produzentenseite entfernen. Die spezielle nuspec gehört deshalb zum Versuchsaufbau, nicht zu einer Empfehlung für neue Bibliotheken.

`Version="8.0.5"` ist eine Mindestversion, keine exakte Sperre `[8.0.5]`. Der Bereich erlaubt die Plattformsubstitution. Der kleinere Graph misst weder Laufzeit-Performance noch Sicherheit. Die Assemblyversion in der Konsolenausgabe ist keine Runtime-Patchversion; diese steht in `dotnet --info`.
