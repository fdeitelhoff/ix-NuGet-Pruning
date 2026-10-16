# NuGet Package Pruning: reproduzierbare Demo

Diese Demo gehört zum Fachartikel „Weniger Rauschen im Dependency-Graph: Was NuGet Package Pruning in .NET 10 bringt“.

## Voraussetzungen und Start

- .NET SDK **10.0.402**, exakt durch `global.json` festgelegt. Download: <https://dotnet.microsoft.com/en-us/download/dotnet/10.0>.
- PowerShell 7.2 oder neuer (`pwsh`), kein Windows PowerShell 5.1.
- Zugriff auf `https://api.nuget.org/v3/index.json` und dessen Paket-/Auditendpunkte.

Im entpackten Demo-Verzeichnis:

```powershell
dotnet --version
pwsh -NoProfile -File ./Test-Pruning.ps1 -IncludeMultiTarget -AuditReport
```

`-IncludeMultiTarget` ergänzt den Build für `net10.0;netstandard2.0`. `-AuditReport` speichert zusätzlich die zum Ausführungszeitpunkt aktuellen Vulnerability Reports. Beide Schalter sind optional. Die normalen Restore-Läufe lassen NuGet Audit eingeschaltet.

Das Skript erstellt pro Start ein neues Verzeichnis `artifacts/<Zeit>-<Zufallskennung>`. Es verändert keine bestehenden Projektdateien, entfernt keine fremden Caches und setzt seine Umgebungsvariablen am Ende zurück. Jede Variante erhält ein eigenes Projektverzeichnis, einen eigenen globalen Paketcache sowie einen eigenen HTTP-Cache. Ein nicht erfolgreicher CLI-Aufruf oder eine verletzte Ergebnisprüfung beendet das Skript mit Fehler.

## Bewusst konstruierter Paketgraph

`Bridge/Bridge.csproj` erstellt eine kleine Bibliothek, deren Methode `JsonBridge.CreateMessage()` tatsächlich `System.Text.Json.JsonSerializer` aufruft. `Bridge.nuspec` deklariert zusätzlich die für `net10.0` redundante Paketabhängigkeit `System.Text.Json` mit Mindestversion **8.0.5**. Die eigene `.nuspec` hält diese Abhängigkeit beim Packen absichtlich fest: Ein regulärer Producer-Build mit Pruning könnte eine entsprechende direkte Referenz bereits beim Packen aus den veröffentlichten Abhängigkeiten entfernen. Das Lehrbeispiel simuliert damit einen vorhandenen Paketvertrag; es empfiehlt diese überflüssige Abhängigkeit nicht für neue Bibliotheken.

`PruningDemo.Bridge` Version **1.0.0** entsteht lokal aus dem mitgelieferten Quelltext. Ein Mapping bindet `PruningDemo.*` an den lokalen Feed. Die Demo veröffentlicht kein Paket. `Consumer` referenziert Bridge, ruft dessen Methode auf und liest das erzeugte JSON nochmals mit `JsonDocument` ein. Der Test entfernt also keine unbenutzte Anwendungsfunktion.

Die NuGet-Notation `Version="8.0.5"` bezeichnet eine Mindestversion, keine exakte Versionssperre. NuGet bevorzugt dabei die niedrigste passende verfügbare Version. Die Ergebnisprüfung verlangt für die nicht geprunte Variante ausdrücklich die aufgelöste Version 8.0.5. Die erzeugten `packages.lock.json` halten den tatsächlich aufgelösten Graph fest. Das Skript prüft anschließend einen unverändernden Restore mit `--locked-mode`.

## Erwartete Ergebnisse

| Variante | Konfiguration | System.Text.Json im Restore-Graph | Laufzeitfunktion |
| --- | --- | --- | --- |
| `off` | Pruning aus, nur Bridge direkt | 8.0.5 transitiv vorhanden | JSON serialisieren und lesen |
| `on` | Pruning an, nur Bridge direkt | entfernt, auch kein Download im eigenen Paketcache | dieselbe JSON-Funktion |
| `direct-on` | Pruning an, zusätzliche direkte JSON-Referenz | vorhanden; `IncludeAssets=none`, `PrivateAssets=all`; NU1510 | dieselbe JSON-Funktion |
| `multi-target` | direkte JSON-Referenz; `net10.0;netstandard2.0` | direkte Referenz bleibt; Assets nur unter `net10.0` ausgeschlossen | Bibliothek für beide TFMs kompilieren |

Für `net10.0` enthält das Paket System.Text.Json 8.0.5 selbst keine weiteren transitiven Paketabhängigkeiten. Der beabsichtigte Vergleich lautet daher **zwei Pakete gegen ein Paket**, nicht eine künstlich aufgeblähte Paketliste. Die Zahl stammt aus den `libraries` in `project.assets.json`, gefiltert nach `type=package`. Das Shared Framework zählt hier nicht als NuGet-Paket.

Bei Multitargeting benötigt `netstandard2.0` die JSON-Paketassets weiterhin. Deshalb darf NU1510 in diesem Projekt nicht zum vollständigen Entfernen der Referenz auffordern. Die Demo baut die Bibliothek für beide Ziele; sie startet keine .NET-Standard-Anwendung, denn .NET Standard ist keine ausführbare Runtime.

## Belege eines Durchlaufs

- `summary.json`: maschinenlesbare Prüfergebnisse und SDK-/PowerShell-Version.
- `dotnet-info.txt`: tatsächlich eingesetzte SDKs und Runtimes.
- `off/`, `on/`, `direct-on/`: `project.assets.json`, `packages.lock.json`, Paketliste als Text und JSON, Restore-/Build-/Run-Logs sowie Locked-Restore-Log.
- `package-diff.txt`: Vergleich der Paketidentitäten; `<=` bedeutet nur in `off`.
- `lock-line-diff.txt`: einfacher zeilenweiser Vergleich beider Lockdateien. Die vollständigen Dateien liegen daneben für einen strukturierten Editorvergleich.
- Optional `audit-report.json`: aktueller NuGet-Vulnerability-Report; kein erwarteter fester Befund und kein Laufzeit-Sicherheitsnachweis.
- Optional `multi-target/`: Assets und Buildbelege für beide TFMs.

`dotnet package list --no-restore` liest jeweils den zuvor erzeugten Graph, ohne den Vergleich durch einen impliziten Restore zu verändern. Alle Builds und Programmstarts verwenden ebenfalls `--no-restore`, der Programmstart außerdem `--no-build`.

## Aussagegrenzen

Die Demo misst keine Performance und verspricht keine bestimmte Downloadzeit oder Artefaktgröße. Der beobachtete Paketunterschied belegt nur Restore-Pruning. Die dynamische JSON-Assemblyausgabe zeigt die geladene Assemblyversion; sie ersetzt weder die konkrete Runtime-Patchversion aus `dotnet --info` noch einen Schwachstellenscan des Deployments. Ein kleinerer NuGet-Bericht entbindet nicht vom Aktualisieren der Runtime, selbstenthaltener Anwendungen und Container-Basisimages.

Die gewählte ältere Paketversion dient ausschließlich dem Versionsvergleich. Aussagen über aktuell gemeldete CVEs oder deren Abwesenheit stehen nicht als feste Testbedingung im Skript. NuGet Audit bleibt aktiv. Ein Vulnerability-Listenbefehl mit Exitcode 0 allein bedeutet nicht, dass keine Schwachstellen existieren.

## Quellen

- NuGet-Pruning und direkte Referenzen: <https://learn.microsoft.com/en-us/nuget/consume-packages/package-references-in-project-files#prunepackagereference>
- Lockdateien und Pruning: <https://learn.microsoft.com/en-us/nuget/consume-packages/package-references-in-project-files#lock-files-and-prunepackagereference>
- NU1510: <https://learn.microsoft.com/en-us/nuget/reference/errors-and-warnings/nu1510>
- Paketliste und `--no-restore`: <https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-package-list>
- NuGet-Versionen und Bereiche: <https://learn.microsoft.com/en-us/nuget/concepts/package-versioning#version-ranges>
- SDK-Auswahl: <https://learn.microsoft.com/en-us/dotnet/core/tools/global-json>

Der tatsächliche Prüfstand steht separat in `TESTSTATUS.md`.

## CI-Prüfung für ein vorhandenes Projekt

`CI-Pruefung.ps1` erwartet ein bestehendes Projekt mit bereits geprüfter `packages.lock.json`. Einmalig außerhalb der CI zum Beispiel `dotnet restore MyApp.csproj --use-lock-file` ausführen, Änderungen prüfen und die Lockdatei einchecken. Danach:

```powershell
pwsh -NoProfile -File ./CI-Pruefung.ps1 -Project ./MyApp.csproj -ReportPath ./audit.json
```

Optional nimmt `-NuGetConfig` eine eigene NuGet-Konfiguration entgegen. Das Skript prüft den Restore im Locked Mode, behandelt die Auditwarnungen NU1903/NU1904 als Fehler, baut ohne erneuten Restore und schreibt einen JSON-Bericht im Ausgabeformat 1. Der URI-Escape `%3B` in der MSBuild-Property ergibt die Liste `NU1903;NU1904`. Bei realen Projekten vorhandene Warnungsrichtlinien zusammenführen: Eine Property auf der Kommandozeile hat Vorrang vor gleichnamigen Projektwerten. Diese Minimalrichtlinie behandelt eine fehlgeschlagene Audit-Datenabfrage (NU1900) nicht automatisch als Fehler.

Der Multitarget-Build nutzt `-m:1` für einen seriellen Build beider Ziele; diese Einstellung verändert die Paketauflösung nicht.
