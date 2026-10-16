using PruningDemo;
using System.Text.Json;

string json = JsonBridge.CreateMessage();
using JsonDocument document = JsonDocument.Parse(json);
if (document.RootElement.GetProperty("message").GetString() != "Pruning funktioniert")
    throw new InvalidOperationException("Unexpected JSON result.");
Console.WriteLine(json);
Console.WriteLine($"JSON assembly: {typeof(JsonSerializer).Assembly.GetName().Version}");
