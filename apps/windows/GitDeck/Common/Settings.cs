using System.Text.Json;
using System.Text.Json.Nodes;

namespace GitDeck.Common;

/// 应用设置：保存在数据目录下的 settings.json，相当于 mac 端的 UserDefaults。
/// 只在界面线程读写；每次修改立即写回磁盘。
public static class Settings
{
    private static readonly string FilePath = Path.Combine(AppInfo.DataDirectory, "settings.json");
    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };
    private static JsonObject? _root;

    private static JsonObject Root => _root ??= Load();

    public static string? GetString(string key) =>
        Root[key] is JsonValue value && value.TryGetValue(out string? text) ? text : null;

    public static bool GetBool(string key, bool fallback = false) =>
        Root[key] is JsonValue value && value.TryGetValue(out bool flag) ? flag : fallback;

    public static double GetDouble(string key, double fallback = 0) =>
        Root[key] is JsonValue value && value.TryGetValue(out double number) ? number : fallback;

    public static List<string> GetStringList(string key) =>
        Root[key] is JsonArray array
            ? array.Select(item => item?.GetValue<string>()).OfType<string>().ToList()
            : [];

    public static bool Contains(string key) => Root.ContainsKey(key);

    public static void Set(string key, string? value) => Store(key, value is null ? null : JsonValue.Create(value));

    public static void Set(string key, bool value) => Store(key, JsonValue.Create(value));

    public static void Set(string key, double value) => Store(key, JsonValue.Create(value));

    public static void Set(string key, IEnumerable<string> values) =>
        Store(key, new JsonArray(values.Select(v => (JsonNode?)JsonValue.Create(v)).ToArray()));

    public static void Remove(string key) => Store(key, null);

    private static void Store(string key, JsonNode? node)
    {
        if (node is null) Root.Remove(key);
        else Root[key] = node;
        Save();
    }

    private static JsonObject Load()
    {
        try
        {
            if (File.Exists(FilePath) && JsonNode.Parse(File.ReadAllText(FilePath)) is JsonObject root) return root;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // 设置文件损坏时从空设置开始，不阻止启动。
        }
        return [];
    }

    private static void Save()
    {
        try
        {
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, Root.ToJsonString(WriteOptions));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // 写入失败（例如磁盘满）时保留内存中的值。
        }
    }
}
