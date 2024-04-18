using System.Collections.Immutable;

namespace NuGetUpdater.Core.Discover;

public sealed record WorkspaceDiscoveryResult : IDiscoveryResult
{
    public required string FilePath { get; init; }
    public bool IsSuccess { get; init; } = true;
    public ImmutableArray<ProjectDiscoveryResult> Projects { get; init; }
    public DirectoryPackagesPropsDiscoveryResult? DirectoryPackagesProps { get; init; }
    public GlobalJsonDiscoveryResult? GlobalJson { get; init; }
    public DotNetToolsJsonDiscoveryResult? DotNetToolsJson { get; init; }
}
