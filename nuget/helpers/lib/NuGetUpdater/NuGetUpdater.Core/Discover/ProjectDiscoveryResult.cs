using System.Collections.Immutable;

namespace NuGetUpdater.Core.Discover;

public record ProjectDiscoveryResult : IDiscoveryResultWithDependencies
{
    public required string FilePath { get; init; }
    public required ImmutableArray<Dependency> Dependencies { get; init; }
    public bool IsSuccess { get; init; } = true;
    public ImmutableArray<Property> Properties { get; init; } = [];
    public ImmutableArray<string> TargetFrameworks { get; init; } = [];
    public ImmutableArray<string> ReferencedProjectPaths { get; init; } = [];
}
