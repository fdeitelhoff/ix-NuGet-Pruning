using System.Text.Json;

namespace PruningDemo;

public static class JsonValue
{
    public static string Read(string json)
    {
        using JsonDocument document = JsonDocument.Parse(json);
        return document.RootElement.GetProperty("message").GetString()!;
    }
}
