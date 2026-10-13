using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Drill.Core.Model;

/// <summary>
/// One block of focused time — the only record drill keeps. Rows are never
/// hard-deleted and never edited without bumping <see cref="UpdatedAt"/>, so
/// any two devices can merge their copies by last-writer-wins on id. The
/// JSON is the shape in docs/SYNC.md, the same bytes the mac app sends.
/// </summary>
public sealed record FocusSession
{
    [JsonConverter(typeof(UpperGuid))] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonConverter(typeof(Iso8601))] public DateTimeOffset StartedAt { get; init; }
    [JsonConverter(typeof(Iso8601))] public DateTimeOffset EndedAt { get; init; }
    /// <summary>Time actually spent focusing; excludes pauses.</summary>
    public double FocusSeconds { get; init; }
    public double PlannedSeconds { get; init; }
    /// <summary>False when the block was cut short by skip or reset.</summary>
    public bool Completed { get; init; }
    public string? Tag { get; init; }
    public string DeviceID { get; init; } = "";
    [JsonConverter(typeof(Iso8601))] public DateTimeOffset UpdatedAt { get; init; }
    /// <summary>Tombstone. Non-null rows are hidden locally but still synced.</summary>
    [JsonConverter(typeof(OptionalIso8601))] public DateTimeOffset? DeletedAt { get; init; }

    /// <summary>camelCase, nulls written out, as the servers expect.</summary>
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
}

/// <summary>
/// ISO-8601 in whole UTC seconds ("2026-09-26T13:00:00Z"): what Swift's
/// .iso8601 strategy writes and the only shape it reads. Reading accepts any
/// zone and fractions, since servers may send them.
/// </summary>
public sealed class Iso8601 : JsonConverter<DateTimeOffset>
{
    public static string Format(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset Parse(string text) =>
        DateTimeOffset.Parse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        Parse(reader.GetString() ?? throw new JsonException("missing date"));

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(Format(value));
}

public sealed class OptionalIso8601 : JsonConverter<DateTimeOffset?>
{
    public override bool HandleNull => true;

    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.Null ? null : Iso8601.Parse(reader.GetString()!);

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is { } v) writer.WriteStringValue(Iso8601.Format(v)); else writer.WriteNullValue();
    }
}

/// <summary>UUIDs go out uppercase, like Swift's.</summary>
public sealed class UpperGuid : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
        Guid.Parse(reader.GetString()!);

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}
