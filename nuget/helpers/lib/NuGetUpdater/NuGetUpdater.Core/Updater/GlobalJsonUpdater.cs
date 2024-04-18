namespace NuGetUpdater.Core;

internal static class GlobalJsonUpdater
{
    public static async Task UpdateDependencyAsync(
        string repoRootPath,
        string workspacePath,
        string dependencyName,
        string previousDependencyVersion,
        string newDependencyVersion,
        Logger logger)
    {
        if (!MSBuildHelper.TryGetGlobalJsonPath(repoRootPath, workspacePath, out var globalJsonPath))
        {
            logger.Log("  No global.json file found.");
            return;
        }

        var globalJsonFile = GlobalJsonBuildFile.Open(repoRootPath, globalJsonPath, logger);

        logger.Log($"  Updating [{globalJsonFile.RelativePath}] file.");

        var containsDependency = globalJsonFile.GetDependencies().Any(d => d.Name.Equals(dependencyName, StringComparison.OrdinalIgnoreCase));
        if (!containsDependency)
        {
            logger.Log($"    Dependency [{dependencyName}] not found.");
            return;
        }

        if (globalJsonFile.MSBuildSdks?.TryGetPropertyValue(dependencyName, out var version) != true
            || version?.GetValue<string>() is not string versionString)
        {
            logger.Log("    Unable to determine dependency version.");
            return;
        }

        if (versionString != previousDependencyVersion)
        {
            return;
        }

        globalJsonFile.UpdateProperty(["msbuild-sdks", dependencyName], newDependencyVersion);

        if (await globalJsonFile.SaveAsync())
        {
            logger.Log($"    Saved [{globalJsonFile.RelativePath}].");
        }
    }
}
