using System.Text.Json;

namespace PruningDemo;

public static class JsonBridge
{
    public static string CreateMessage() =>
        JsonSerializer.Serialize(new { message = "Pruning funktioniert" });
}
