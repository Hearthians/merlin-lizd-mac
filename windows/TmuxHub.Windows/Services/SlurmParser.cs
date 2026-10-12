using System.Globalization;
using System.Text;
using System.Text.Json;
using TmuxHub.Windows.Models;

namespace TmuxHub.Windows.Services;

public enum SlurmParserError
{
    ResponseTooLarge,
    MalformedDocument,
    MalformedRow,
    DuplicateJobId,
}

public sealed class SlurmParserException : Exception
{
    internal SlurmParserException(
        SlurmParserError error,
        int? lineNumber = null,
        SlurmJobId? jobId = null)
        : base(MessageFor(error, lineNumber, jobId))
    {
        Error = error;
        LineNumber = lineNumber;
        JobId = jobId;
    }

    public SlurmParserError Error { get; }

    public int? LineNumber { get; }

    public SlurmJobId? JobId { get; }

    private static string MessageFor(
        SlurmParserError error,
        int? lineNumber,
        SlurmJobId? jobId) => error switch
    {
        SlurmParserError.ResponseTooLarge => "Slurm 返回的数据过大。",
        SlurmParserError.MalformedDocument => "Slurm 返回了无法识别的 JSON 数据。",
        SlurmParserError.MalformedRow => $"Slurm 返回了无法识别的第 {lineNumber} 个任务。",
        SlurmParserError.DuplicateJobId => $"Slurm 返回了重复的作业编号 {jobId}。",
        _ => "Slurm 返回的数据无效。",
    };
}

public sealed record SlurmQueueParseResult(
    IReadOnlyList<SlurmJobSnapshot> Jobs,
    int IgnoredRowCount);

public static class SlurmParser
{
    private const int MaximumResponseBytes = 8 * 1_024 * 1_024;
    private const long MaximumUnixTimeSeconds = 253_402_300_799;

    public static IReadOnlyList<SlurmJobSnapshot> ParseQueue(string output)
    {
        using var document = ParseDocument(output);
        var elements = ReadJobElements(document.RootElement);
        var jobs = new List<SlurmJobSnapshot>(elements.GetArrayLength());
        var seen = new HashSet<SlurmJobId>();
        var index = 0;
        foreach (var element in elements.EnumerateArray())
        {
            var job = ParseJob(element, index);
            if (!seen.Add(job.JobId))
            {
                throw new SlurmParserException(
                    SlurmParserError.DuplicateJobId,
                    jobId: job.JobId);
            }
            jobs.Add(job);
            index++;
        }
        return jobs;
    }

    /// <summary>
    /// Parses structured JSON for display while isolating malformed external
    /// jobs. Conflicting duplicate IDs are removed completely. Mutating and
    /// reconciliation operations continue to use the strict parser above.
    /// </summary>
    public static SlurmQueueParseResult ParseQueueWithDiagnostics(string output)
    {
        using var document = ParseDocument(output);
        var elements = ReadJobElements(document.RootElement);
        var jobsById = new Dictionary<SlurmJobId, SlurmJobSnapshot>();
        var orderedIds = new List<SlurmJobId>();
        var conflictingIds = new HashSet<SlurmJobId>();
        var ignoredRows = 0;
        var index = 0;

        foreach (var element in elements.EnumerateArray())
        {
            SlurmJobSnapshot job;
            try
            {
                job = ParseJob(element, index);
            }
            catch (SlurmParserException error)
                when (error.Error == SlurmParserError.MalformedRow)
            {
                ignoredRows++;
                index++;
                continue;
            }

            if (conflictingIds.Contains(job.JobId))
            {
                ignoredRows++;
                index++;
                continue;
            }
            if (jobsById.Remove(job.JobId))
            {
                conflictingIds.Add(job.JobId);
                ignoredRows += 2;
                index++;
                continue;
            }

            jobsById.Add(job.JobId, job);
            orderedIds.Add(job.JobId);
            index++;
        }

        var jobs = orderedIds
            .Where(jobsById.ContainsKey)
            .Select(id => jobsById[id])
            .ToArray();
        return new SlurmQueueParseResult(jobs, ignoredRows);
    }

    private static JsonDocument ParseDocument(string output)
    {
        ArgumentNullException.ThrowIfNull(output);
        if (Encoding.UTF8.GetByteCount(output) > MaximumResponseBytes)
        {
            throw new SlurmParserException(SlurmParserError.ResponseTooLarge);
        }
        try
        {
            return JsonDocument.Parse(
                output,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64,
                });
        }
        catch (JsonException)
        {
            throw new SlurmParserException(SlurmParserError.MalformedDocument);
        }
    }

    private static JsonElement ReadJobElements(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("jobs", out var jobs)
            || jobs.ValueKind != JsonValueKind.Array)
        {
            throw new SlurmParserException(SlurmParserError.MalformedDocument);
        }
        if (root.TryGetProperty("errors", out var errors)
            && errors.ValueKind is not JsonValueKind.Null
            && (errors.ValueKind != JsonValueKind.Array || errors.GetArrayLength() != 0))
        {
            throw new SlurmParserException(SlurmParserError.MalformedDocument);
        }
        return jobs;
    }

    private static SlurmJobSnapshot ParseJob(JsonElement element, int zeroBasedOffset)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw Malformed(zeroBasedOffset);
        }

        var jobId = ReadJobId(element, zeroBasedOffset);
        var name = ReadDisplayString(element, "name", zeroBasedOffset, required: true)!;
        if (name.Length == 0)
        {
            throw Malformed(zeroBasedOffset);
        }
        var owner = ReadDisplayString(
            element,
            "user_name",
            zeroBasedOffset,
            required: true)!;
        if (!SlurmModelValidation.IsSafeIdentifier(owner))
        {
            throw Malformed(zeroBasedOffset);
        }
        var state = ReadState(element, zeroBasedOffset);
        var nodeList = ReadDisplayString(element, "nodes", zeroBasedOffset);
        var reason = ReadDisplayString(element, "state_reason", zeroBasedOffset) ?? string.Empty;
        var partition = ReadDisplayString(element, "partition", zeroBasedOffset) ?? "—";
        var comment = ReadDisplayString(element, "comment", zeroBasedOffset) ?? string.Empty;

        var nodeCountValue = ReadUnsigned(element, "node_count", zeroBasedOffset);
        if (nodeCountValue.Infinite
            || nodeCountValue.Number is < 0 or > int.MaxValue)
        {
            throw Malformed(zeroBasedOffset);
        }
        var nodeCount = (int)(nodeCountValue.Number ?? 0);

        var start = ReadUnsigned(element, "start_time", zeroBasedOffset);
        var submit = ReadUnsigned(element, "submit_time", zeroBasedOffset);
        var end = ReadUnsigned(element, "end_time", zeroBasedOffset);
        var timeLimit = ReadUnsigned(element, "time_limit", zeroBasedOffset);
        ValidateTimestamp(start, zeroBasedOffset);
        ValidateTimestamp(submit, zeroBasedOffset);
        ValidateTimestamp(end, zeroBasedOffset);
        if (timeLimit.Number is < 0 or > long.MaxValue / 60)
        {
            throw Malformed(zeroBasedOffset);
        }

        return new SlurmJobSnapshot(
            jobId,
            name,
            owner,
            state,
            nodeList ?? reason,
            partition,
            nodeCount,
            FormatElapsed(start.Number, end.Number),
            timeLimit.Infinite
                ? "UNLIMITED"
                : FormatDuration(checked((timeLimit.Number ?? 0) * 60)),
            FormatTimestamp(start.Number),
            FormatTimestamp(submit.Number),
            nodeList,
            comment);
    }

    private static SlurmJobId ReadJobId(JsonElement element, int zeroBasedOffset)
    {
        if (!element.TryGetProperty("job_id", out var rawId))
        {
            throw Malformed(zeroBasedOffset);
        }
        var baseId = ReadIdentifierNumber(rawId, zeroBasedOffset);
        var arrayJobId = ReadUnsigned(element, "array_job_id", zeroBasedOffset);
        var arrayTaskId = ReadUnsigned(element, "array_task_id", zeroBasedOffset);
        var value = arrayTaskId.IsSet && arrayTaskId.Number is { } task
            ? string.Create(
                CultureInfo.InvariantCulture,
                $"{arrayJobId.Number ?? ParseBaseId(baseId, zeroBasedOffset)}_{task}")
            : baseId;
        if (!SlurmJobId.TryParse(value, out var jobId))
        {
            throw Malformed(zeroBasedOffset);
        }
        return jobId!;
    }

    private static long ParseBaseId(string value, int zeroBasedOffset)
    {
        if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
            || parsed < 0)
        {
            throw Malformed(zeroBasedOffset);
        }
        return parsed;
    }

    private static string ReadIdentifierNumber(JsonElement value, int zeroBasedOffset)
    {
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out var number)
            && number >= 0)
        {
            return number.ToString(CultureInfo.InvariantCulture);
        }
        if (value.ValueKind == JsonValueKind.String
            && SlurmModelValidation.IsJobId(value.GetString()))
        {
            return value.GetString()!;
        }
        throw Malformed(zeroBasedOffset);
    }

    private static SlurmJobState ReadState(JsonElement element, int zeroBasedOffset)
    {
        if (!element.TryGetProperty("job_state", out var value))
        {
            throw Malformed(zeroBasedOffset);
        }
        string? state = null;
        if (value.ValueKind == JsonValueKind.String)
        {
            state = value.GetString();
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in value.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String
                    || !SlurmModelValidation.IsSafeIdentifier(item.GetString()))
                {
                    throw Malformed(zeroBasedOffset);
                }
                state ??= item.GetString();
            }
        }
        if (!SlurmModelValidation.IsSafeIdentifier(state))
        {
            throw Malformed(zeroBasedOffset);
        }
        return SlurmJobState.Parse(state!);
    }

    private static string? ReadDisplayString(
        JsonElement element,
        string propertyName,
        int zeroBasedOffset,
        bool required = false)
    {
        if (!element.TryGetProperty(propertyName, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            if (required)
            {
                throw Malformed(zeroBasedOffset);
            }
            return null;
        }
        if (value.ValueKind != JsonValueKind.String
            || !IsSafeDisplayField(value.GetString()))
        {
            throw Malformed(zeroBasedOffset);
        }
        return value.GetString();
    }

    private static JsonUnsignedValue ReadUnsigned(
        JsonElement element,
        string propertyName,
        int zeroBasedOffset)
    {
        if (!element.TryGetProperty(propertyName, out var value))
        {
            return default;
        }
        return ReadUnsignedValue(value, zeroBasedOffset, depth: 0);
    }

    private static JsonUnsignedValue ReadUnsignedValue(
        JsonElement value,
        int zeroBasedOffset,
        int depth)
    {
        if (depth > 2)
        {
            throw Malformed(zeroBasedOffset);
        }
        if (value.ValueKind == JsonValueKind.Null)
        {
            return default;
        }
        if (value.ValueKind == JsonValueKind.Number
            && value.TryGetInt64(out var number)
            && number >= 0)
        {
            return new JsonUnsignedValue(true, false, number);
        }
        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString()?.Trim().ToUpperInvariant();
            if (text is "NO_VAL" or "NONE" or "N/A" or "UNKNOWN" or "")
            {
                return default;
            }
            if (text is "INFINITE" or "UNLIMITED")
            {
                return new JsonUnsignedValue(true, true, null);
            }
            if (long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out number)
                && number >= 0)
            {
                return new JsonUnsignedValue(true, false, number);
            }
            throw Malformed(zeroBasedOffset);
        }
        if (value.ValueKind != JsonValueKind.Object)
        {
            throw Malformed(zeroBasedOffset);
        }

        if (value.TryGetProperty("set", out var isSet))
        {
            if (isSet.ValueKind != JsonValueKind.True
                && isSet.ValueKind != JsonValueKind.False)
            {
                throw Malformed(zeroBasedOffset);
            }
            if (isSet.ValueKind == JsonValueKind.False)
            {
                return default;
            }
        }
        if (value.TryGetProperty("infinite", out var infinite))
        {
            if (infinite.ValueKind != JsonValueKind.True
                && infinite.ValueKind != JsonValueKind.False)
            {
                throw Malformed(zeroBasedOffset);
            }
            if (infinite.ValueKind == JsonValueKind.True)
            {
                return new JsonUnsignedValue(true, true, null);
            }
        }
        if (value.TryGetProperty("number", out var wrappedNumber))
        {
            return ReadUnsignedValue(wrappedNumber, zeroBasedOffset, depth + 1) with
            {
                IsSet = true,
            };
        }
        if (value.TryGetProperty("value", out var wrappedValue))
        {
            return ReadUnsignedValue(wrappedValue, zeroBasedOffset, depth + 1) with
            {
                IsSet = true,
            };
        }
        return default;
    }

    private static void ValidateTimestamp(JsonUnsignedValue value, int zeroBasedOffset)
    {
        if (value.Infinite || value.Number is < 0 or > MaximumUnixTimeSeconds)
        {
            throw Malformed(zeroBasedOffset);
        }
    }

    private static string FormatElapsed(long? startTime, long? endTime)
    {
        if (startTime is null or 0)
        {
            return "0:00";
        }
        var effectiveEnd = endTime is > 0
            ? endTime.Value
            : DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return FormatDuration(Math.Max(0, effectiveEnd - startTime.Value));
    }

    private static string FormatDuration(long seconds)
    {
        var days = seconds / 86_400;
        var remainder = seconds % 86_400;
        var hours = remainder / 3_600;
        var minutes = remainder % 3_600 / 60;
        var remainingSeconds = remainder % 60;
        if (days > 0)
        {
            return string.Create(
                CultureInfo.InvariantCulture,
                $"{days}-{hours:00}:{minutes:00}:{remainingSeconds:00}");
        }
        if (hours > 0)
        {
            return string.Create(
                CultureInfo.InvariantCulture,
                $"{hours}:{minutes:00}:{remainingSeconds:00}");
        }
        return string.Create(
            CultureInfo.InvariantCulture,
            $"{minutes}:{remainingSeconds:00}");
    }

    private static string? FormatTimestamp(long? value) =>
        value is null or 0
            ? null
            : DateTimeOffset
                .FromUnixTimeSeconds(value.Value)
                .ToLocalTime()
                .ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    private static SlurmParserException Malformed(int zeroBasedOffset) =>
        new(SlurmParserError.MalformedRow, zeroBasedOffset + 1);

    private static bool IsSafeDisplayField(string? value) =>
        value is not null
        && Encoding.UTF8.GetByteCount(value) <= 16_384
        && !value.Any(static character => char.IsControl(character));

    private readonly record struct JsonUnsignedValue(
        bool IsSet,
        bool Infinite,
        long? Number);
}
