using System.Collections.Immutable;

using Microsoft.Language.Xml;

using NuGet.Versioning;

namespace NuGetUpdater.Core;

internal static class SdkPackageUpdater
{
    public static async Task UpdateDependencyAsync(
        string repoRootPath,
        string projectPath,
        string dependencyName,
        string previousDependencyVersion,
        string newDependencyVersion,
        bool isTransitive,
        Logger logger)
    {
        // SDK-style project, modify the XML directly
        logger.Log("  Running for SDK-style project");

        (ImmutableArray<ProjectBuildFile> buildFiles, string[] tfms) = await MSBuildHelper.LoadBuildFilesAndTargetFrameworksAsync(repoRootPath, projectPath);

        // Get the set of all top-level dependencies in the current project
        var topLevelDependencies = MSBuildHelper.GetTopLevelPackageDependencyInfos(buildFiles).ToArray();
        if (!await DoesDependencyRequireUpdateAsync(repoRootPath, projectPath, tfms, topLevelDependencies, dependencyName, newDependencyVersion, logger))
        {
            return;
        }

        if (isTransitive)
        {
            await UpdateTransitiveDependencyAsnyc(projectPath, dependencyName, newDependencyVersion, buildFiles, logger);
        }
        else
        {
            var peerDependencies = await GetUpdatedPeerDependenciesAsync(repoRootPath, projectPath, tfms, dependencyName, newDependencyVersion, logger);
            if (peerDependencies is null)
            {
                return;
            }

            await UpdateTopLevelDepdendency(repoRootPath, buildFiles, tfms, dependencyName, previousDependencyVersion, newDependencyVersion, peerDependencies, logger);
        }

        if (!await AreDependenciesCoherentAsync(repoRootPath, projectPath, dependencyName, logger, buildFiles, tfms))
        {
            return;
        }

        await SaveBuildFilesAsync(buildFiles, logger);
    }

    /// <summary>
    /// Verifies that the package does not already satisfy the requested dependency version.
    /// </summary>
    /// <returns>Returns false if the package is not found or does not need to be updated.</returns>
    private static async Task<bool> DoesDependencyRequireUpdateAsync(
        string repoRootPath,
        string projectPath,
        string[] tfms,
        Dependency[] topLevelDependencies,
        string dependencyName,
        string newDependencyVersion,
        Logger logger)
    {
        var newDependencyNuGetVersion = NuGetVersion.Parse(newDependencyVersion);

        bool packageFound = false;
        bool needsUpdate = false;

        foreach (var tfm in tfms)
        {
            var dependencies = await MSBuildHelper.GetAllPackageDependenciesAsync(
                repoRootPath,
                projectPath,
                tfm,
                topLevelDependencies,
                logger);
            foreach (var (packageName, packageVersion, _, _, _, _, _, _, _, _) in dependencies)
            {
                if (packageVersion is null)
                {
                    continue;
                }

                if (packageName.Equals(dependencyName, StringComparison.OrdinalIgnoreCase))
                {
                    packageFound = true;

                    var nugetVersion = NuGetVersion.Parse(packageVersion);
                    if (nugetVersion < newDependencyNuGetVersion)
                    {
                        needsUpdate = true;
                        break;
                    }
                }
            }

            if (packageFound && needsUpdate)
            {
                break;
            }
        }

        // Skip updating the project if the dependency does not exist in the graph
        if (!packageFound)
        {
            logger.Log($"    Package [{dependencyName}] Does not exist as a dependency in [{projectPath}].");
            return false;
        }

        // Skip updating the project if the dependency version meets or exceeds the newDependencyVersion
        if (!needsUpdate)
        {
            logger.Log($"    Package [{dependencyName}] already meets the requested dependency version in [{projectPath}].");
            return false;
        }

        return true;
    }

    private static async Task UpdateTransitiveDependencyAsnyc(string projectPath, string dependencyName, string newDependencyVersion, ImmutableArray<ProjectBuildFile> buildFiles, Logger logger)
    {
        var directoryPackagesWithPinning = buildFiles.OfType<ProjectBuildFile>()
            .FirstOrDefault(bf => IsCpmTransitivePinningEnabled(bf));
        if (directoryPackagesWithPinning is not null)
        {
            PinTransitiveDependency(directoryPackagesWithPinning, dependencyName, newDependencyVersion, logger);
        }
        else
        {
            await AddTransitiveDependencyAsync(projectPath, dependencyName, newDependencyVersion, logger);
        }
    }

    private static bool IsCpmTransitivePinningEnabled(ProjectBuildFile buildFile)
    {
        var buildFileName = Path.GetFileName(buildFile.Path);
        if (!buildFileName.Equals("Directory.Packages.props", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var propertyElements = buildFile.PropertyNodes;

        var isCpmEnabledValue = propertyElements.FirstOrDefault(e =>
            e.Name.Equals("ManagePackageVersionsCentrally", StringComparison.OrdinalIgnoreCase))?.GetContentValue();
        if (isCpmEnabledValue is null || !string.Equals(isCpmEnabledValue, "true", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var isTransitivePinningEnabled = propertyElements.FirstOrDefault(e =>
            e.Name.Equals("CentralPackageTransitivePinningEnabled", StringComparison.OrdinalIgnoreCase))?.GetContentValue();
        return isTransitivePinningEnabled is not null && string.Equals(isTransitivePinningEnabled, "true", StringComparison.OrdinalIgnoreCase);
    }

    private static void PinTransitiveDependency(ProjectBuildFile directoryPackages, string dependencyName, string newDependencyVersion, Logger logger)
    {
        var existingPackageVersionElement = directoryPackages.ItemNodes
            .Where(e => e.Name.Equals("PackageVersion", StringComparison.OrdinalIgnoreCase) &&
                        e.Attributes.Any(a => a.Name.Equals("Include", StringComparison.OrdinalIgnoreCase) &&
                                              a.Value.Equals(dependencyName, StringComparison.OrdinalIgnoreCase)))
            .FirstOrDefault();

        logger.Log($"    Pinning [{dependencyName}/{newDependencyVersion}] as a package version.");

        var lastPackageVersion = directoryPackages.ItemNodes
            .Where(e => e.Name.Equals("PackageVersion", StringComparison.OrdinalIgnoreCase))
            .LastOrDefault();

        if (lastPackageVersion is null)
        {
            logger.Log($"    Transitive dependency [{dependencyName}/{newDependencyVersion}] was not pinned.");
            return;
        }

        var lastItemGroup = lastPackageVersion.Parent;

        IXmlElementSyntax updatedItemGroup;
        if (existingPackageVersionElement is null)
        {
            // need to add a new entry
            logger.Log("      New PackageVersion element added.");
            var leadingTrivia = lastPackageVersion.AsNode.GetLeadingTrivia();
            var packageVersionElement = XmlExtensions.CreateSingleLineXmlElementSyntax("PackageVersion", new SyntaxList<SyntaxNode>(leadingTrivia))
                .WithAttribute("Include", dependencyName)
                .WithAttribute("Version", newDependencyVersion);
            updatedItemGroup = lastItemGroup.AddChild(packageVersionElement);
        }
        else
        {
            IXmlElementSyntax updatedPackageVersionElement;
            var versionAttribute = existingPackageVersionElement.Attributes.FirstOrDefault(a => a.Name.Equals("Version", StringComparison.OrdinalIgnoreCase));
            if (versionAttribute is null)
            {
                // need to add the version
                logger.Log("      Adding version attribute to element.");
                updatedPackageVersionElement = existingPackageVersionElement.WithAttribute("Version", newDependencyVersion);
            }
            else if (!versionAttribute.Value.Equals(newDependencyVersion, StringComparison.OrdinalIgnoreCase))
            {
                // need to update the version
                logger.Log($"      Updating version attribute of [{versionAttribute.Value}].");
                var updatedVersionAttribute = versionAttribute.WithValue(newDependencyVersion);
                updatedPackageVersionElement = existingPackageVersionElement.ReplaceAttribute(versionAttribute, updatedVersionAttribute);
            }
            else
            {
                logger.Log("      Existing PackageVersion element version was already correct.");
                return;
            }

            updatedItemGroup = lastItemGroup.ReplaceChildElement(existingPackageVersionElement, updatedPackageVersionElement);
        }

        var updatedXml = directoryPackages.Contents.ReplaceNode(lastItemGroup.AsNode, updatedItemGroup.AsNode);
        directoryPackages.Update(updatedXml);
    }

    private static async Task AddTransitiveDependencyAsync(string projectPath, string dependencyName, string newDependencyVersion, Logger logger)
    {
        logger.Log($"    Adding [{dependencyName}/{newDependencyVersion}] as a top-level package reference.");

        // see https://learn.microsoft.com/nuget/consume-packages/install-use-packages-dotnet-cli
        var (exitCode, stdout, stderr) = await ProcessEx.RunAsync("dotnet", $"add {projectPath} package {dependencyName} --version {newDependencyVersion}", workingDirectory: Path.GetDirectoryName(projectPath));
        if (exitCode != 0)
        {
            logger.Log($"    Transitive dependency [{dependencyName}/{newDependencyVersion}] was not added.\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}");
        }
    }

    /// <summary>
    /// Gets the set of peer dependencies that need to be updated.
    /// </summary>
    /// <returns>Returns null if there are conflicting versions.</returns>
    private static async Task<Dictionary<string, string>?> GetUpdatedPeerDependenciesAsync(
        string repoRootPath,
        string projectPath,
        string[] tfms,
        string dependencyName,
        string newDependencyVersion,
        Logger logger)
    {
        var newDependency = new[] { new Dependency(dependencyName, newDependencyVersion, DependencyType.Unknown) };
        var tfmsAndDependencies = new Dictionary<string, Dependency[]>();
        foreach (var tfm in tfms)
        {
            var dependencies = await MSBuildHelper.GetAllPackageDependenciesAsync(repoRootPath, projectPath, tfm, newDependency, logger);
            tfmsAndDependencies[tfm] = dependencies;
        }

        var unupgradableTfms = tfmsAndDependencies.Where(kvp => !kvp.Value.Any()).Select(kvp => kvp.Key);
        if (unupgradableTfms.Any())
        {
            logger.Log($"    The following target frameworks could not find packages to upgrade: {string.Join(", ", unupgradableTfms)}");
            return null;
        }

        var conflictingPackageVersionsFound = false;
        var packagesAndVersions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (_, dependencies) in tfmsAndDependencies)
        {
            foreach (var (packageName, packageVersion, _, _, _, _, _, _, _, _) in dependencies)
            {
                if (packagesAndVersions.TryGetValue(packageName, out var existingVersion) &&
                    existingVersion != packageVersion)
                {
                    logger.Log($"    Package [{packageName}] tried to update to version [{packageVersion}], but found conflicting package version of [{existingVersion}].");
                    conflictingPackageVersionsFound = true;
                }
                else
                {
                    packagesAndVersions[packageName] = packageVersion!;
                }
            }
        }

        // stop update process if we find conflicting package versions
        if (conflictingPackageVersionsFound)
        {
            return null;
        }

        return packagesAndVersions;
    }

    private static async Task UpdateTopLevelDepdendency(
        string repoRootPath,
        ImmutableArray<ProjectBuildFile> buildFiles,
        string[] targetFrameworks,
        string dependencyName,
        string previousDependencyVersion,
        string newDependencyVersion,
        IDictionary<string, string> peerDependencies,
        Logger logger)
    {
        var result = TryUpdateDependencyVersion(buildFiles, dependencyName, previousDependencyVersion, newDependencyVersion, logger);
        if (result == UpdateResult.NotFound)
        {
            logger.Log($"    Root package [{dependencyName}/{previousDependencyVersion}] was not updated; skipping dependencies.");
            return;
        }

        foreach (var (packageName, packageVersion) in peerDependencies.Where(kvp => string.Compare(kvp.Key, dependencyName, StringComparison.OrdinalIgnoreCase) != 0))
        {
            TryUpdateDependencyVersion(buildFiles, packageName, previousDependencyVersion: null, newDependencyVersion: packageVersion, logger);
        }

        // now make all dependency requirements coherent
        Dependency[] updatedTopLevelDependencies = MSBuildHelper.GetTopLevelPackageDependencyInfos(buildFiles).ToArray();
        foreach (ProjectBuildFile projectFile in buildFiles)
        {
            foreach (string tfm in targetFrameworks)
            {
                Dependency[]? resolvedDependencies = await MSBuildHelper.ResolveDependencyConflicts(repoRootPath, projectFile.Path, tfm, updatedTopLevelDependencies, logger);
                if (resolvedDependencies is null)
                {
                    logger.Log($"    Unable to resolve dependency conflicts for {projectFile.Path}.");
                    continue;
                }

                // ensure the originally requested dependency was resolved to the correct version
                var specificResolvedDependency = resolvedDependencies.Where(d => d.Name.Equals(dependencyName, StringComparison.OrdinalIgnoreCase)).FirstOrDefault();
                if (specificResolvedDependency is null)
                {
                    logger.Log($"    Unable resolve requested dependency for {dependencyName} in {projectFile.Path}.");
                    continue;
                }

                if (!newDependencyVersion.Equals(specificResolvedDependency.Version, StringComparison.OrdinalIgnoreCase))
                {
                    logger.Log($"    Inconsistent resolution for {dependencyName}; attempted upgrade to {newDependencyVersion} but resolved {specificResolvedDependency.Version}.");
                    continue;
                }

                // update all other dependencies
                foreach (Dependency resolvedDependency in resolvedDependencies
                                                          .Where(d => !d.Name.Equals(dependencyName, StringComparison.OrdinalIgnoreCase))
                                                          .Where(d => d.Version is not null))
                {
                    TryUpdateDependencyVersion(buildFiles, resolvedDependency.Name, previousDependencyVersion: null, newDependencyVersion: resolvedDependency.Version!, logger);
                }
            }
        }
    }

    private static UpdateResult TryUpdateDependencyVersion(
        ImmutableArray<ProjectBuildFile> buildFiles,
        string dependencyName,
        string? previousDependencyVersion,
        string newDependencyVersion,
        Logger logger)
    {
        var foundCorrect = false;
        var foundUnsupported = false;
        var updateWasPerformed = false;
        var propertyNames = new List<string>();

        // First we locate all the PackageReference, GlobalPackageReference, or PackageVersion which set the Version
        // or VersionOverride attribute. In the simplest case we can update the version attribute directly then move
        // on. When property substitution is used we have to additionally search for the property containing the version.

        foreach (var buildFile in buildFiles)
        {
            var updateNodes = new List<XmlNodeSyntax>();
            var packageNodes = FindPackageNodes(buildFile, dependencyName);

            var previousPackageVersion = previousDependencyVersion;

            foreach (var packageNode in packageNodes)
            {
                var versionAttribute = packageNode.GetAttribute("Version", StringComparison.OrdinalIgnoreCase)
                                       ?? packageNode.GetAttribute("VersionOverride", StringComparison.OrdinalIgnoreCase);
                var versionElement = packageNode.Elements.FirstOrDefault(e => e.Name.Equals("Version", StringComparison.OrdinalIgnoreCase))
                                     ?? packageNode.Elements.FirstOrDefault(e => e.Name.Equals("VersionOverride", StringComparison.OrdinalIgnoreCase));
                if (versionAttribute is not null)
                {
                    // Is this the case where version is specified with property substitution?
                    if (MSBuildHelper.TryGetPropertyName(versionAttribute.Value, out var propertyName))
                    {
                        propertyNames.Add(propertyName);
                    }
                    // Is this the case that the version is specified directly in the package node?
                    else
                    {
                        var currentVersion = versionAttribute.Value.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported [{packageNode.Name}] version attribute value [{versionAttribute.Value}] in [{buildFile.RelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (string.Equals(currentVersion, previousDependencyVersion, StringComparison.Ordinal))
                        {
                            logger.Log($"    Found incorrect [{packageNode.Name}] version attribute in [{buildFile.RelativePath}].");
                            updateNodes.Add(versionAttribute);
                        }
                        else if (previousDependencyVersion == null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer [{packageNode.Name}] version attribute in [{buildFile.RelativePath}].");
                                updateNodes.Add(versionAttribute);
                            }
                        }
                        else if (string.Equals(currentVersion, newDependencyVersion, StringComparison.Ordinal))
                        {
                            logger.Log($"    Found correct [{packageNode.Name}] version attribute in [{buildFile.RelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }
                else if (versionElement is not null)
                {
                    var versionValue = versionElement.GetContentValue();
                    if (MSBuildHelper.TryGetPropertyName(versionValue, out var propertyName))
                    {
                        propertyNames.Add(propertyName);
                    }
                    else
                    {
                        var currentVersion = versionValue.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported [{packageNode.Name}] version node value [{versionValue}] in [{buildFile.RelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (currentVersion == previousDependencyVersion)
                        {
                            logger.Log($"    Found incorrect [{packageNode.Name}] version node in [{buildFile.RelativePath}].");
                            if (versionElement is XmlElementSyntax elementSyntax)
                            {
                                updateNodes.Add(elementSyntax);
                            }
                            else
                            {
                                throw new InvalidDataException("A concrete type was required for updateNodes. This should not happen.");
                            }
                        }
                        else if (previousDependencyVersion == null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer [{packageNode.Name}] version node in [{buildFile.RelativePath}].");
                                if (versionElement is XmlElementSyntax elementSyntax)
                                {
                                    updateNodes.Add(elementSyntax);
                                }
                                else
                                {
                                    // This only exists for completeness in case we ever add a new type of node we don't want to silently ignore them.
                                    throw new InvalidDataException("A concrete type was required for updateNodes. This should not happen.");
                                }
                            }
                        }
                        else if (currentVersion == newDependencyVersion)
                        {
                            logger.Log($"    Found correct [{packageNode.Name}] version node in [{buildFile.RelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }
                else
                {
                    // We weren't able to find the version node. Central package management?
                    logger.Log("    Found package reference but was unable to locate version information.");
                }
            }

            if (updateNodes.Count > 0)
            {
                var updatedXml = buildFile.Contents
                    .ReplaceNodes(updateNodes, (_, n) =>
                    {
                        if (n is XmlAttributeSyntax attributeSyntax)
                        {
                            return attributeSyntax.WithValue(attributeSyntax.Value.Replace(previousPackageVersion!, newDependencyVersion));
                        }

                        if (n is XmlElementSyntax elementsSyntax)
                        {
                            var modifiedContent = elementsSyntax.GetContentValue().Replace(previousPackageVersion!, newDependencyVersion);

                            var textSyntax = SyntaxFactory.XmlText(SyntaxFactory.Token(null, SyntaxKind.XmlTextLiteralToken, null, modifiedContent));
                            return elementsSyntax.WithContent(SyntaxFactory.SingletonList(textSyntax));
                        }

                        throw new InvalidDataException($"Unsupported SyntaxType {n.GetType().Name} marked for update");
                    });
                buildFile.Update(updatedXml);
                updateWasPerformed = true;
            }
        }

        // If property substitution was used to set the Version, we must search for the property containing
        // the version string. Since it could also be populated by property substitution this search repeats
        // with the each new property name until the version string is located.

        var processedPropertyNames = new HashSet<string>();

        for (int propertyNameIndex = 0; propertyNameIndex < propertyNames.Count; propertyNameIndex++)
        {
            var propertyName = propertyNames[propertyNameIndex];
            if (processedPropertyNames.Contains(propertyName))
            {
                continue;
            }

            processedPropertyNames.Add(propertyName);

            foreach (var buildFile in buildFiles)
            {
                var updateProperties = new List<XmlElementSyntax>();
                var propertyElements = buildFile.PropertyNodes
                    .Where(e => e.Name.Equals(propertyName, StringComparison.OrdinalIgnoreCase));

                var previousPackageVersion = previousDependencyVersion;

                foreach (var propertyElement in propertyElements)
                {
                    var propertyContents = propertyElement.GetContentValue();

                    // Is this the case where this property contains another property substitution?
                    if (MSBuildHelper.TryGetPropertyName(propertyContents, out var propName))
                    {
                        propertyNames.Add(propName);
                    }
                    // Is this the case that the property contains the version?
                    else
                    {
                        var currentVersion = propertyContents.TrimStart('[', '(').TrimEnd(']', ')');
                        if (currentVersion.Contains(',') || currentVersion.Contains('*'))
                        {
                            logger.Log($"    Found unsupported version property [{propertyElement.Name}] value [{propertyContents}] in [{buildFile.RelativePath}].");
                            foundUnsupported = true;
                        }
                        else if (currentVersion == previousDependencyVersion)
                        {
                            logger.Log($"    Found incorrect version property [{propertyElement.Name}] in [{buildFile.RelativePath}].");
                            updateProperties.Add((XmlElementSyntax)propertyElement.AsNode);
                        }
                        else if (previousDependencyVersion is null && NuGetVersion.TryParse(currentVersion, out var previousVersion))
                        {
                            var newVersion = NuGetVersion.Parse(newDependencyVersion);
                            if (previousVersion < newVersion)
                            {
                                previousPackageVersion = currentVersion;

                                logger.Log($"    Found incorrect peer version property [{propertyElement.Name}] in [{buildFile.RelativePath}].");
                                updateProperties.Add((XmlElementSyntax)propertyElement.AsNode);
                            }
                        }
                        else if (currentVersion == newDependencyVersion)
                        {
                            logger.Log($"    Found correct version property [{propertyElement.Name}] in [{buildFile.RelativePath}].");
                            foundCorrect = true;
                        }
                    }
                }

                if (updateProperties.Count > 0)
                {
                    var updatedXml = buildFile.Contents
                        .ReplaceNodes(updateProperties, (o, n) => n.WithContent(o.GetContentValue().Replace(previousPackageVersion!, newDependencyVersion)).AsNode);
                    buildFile.Update(updatedXml);
                    updateWasPerformed = true;
                }
            }
        }

        return updateWasPerformed
            ? UpdateResult.Updated
            : foundCorrect
                ? UpdateResult.Correct
                : foundUnsupported
                    ? UpdateResult.NotSupported
                    : UpdateResult.NotFound;
    }

    private static IEnumerable<IXmlElementSyntax> FindPackageNodes(
        ProjectBuildFile buildFile,
        string packageName)
        => buildFile.PackageItemNodes.Where(e =>
            string.Equals(
                e.GetAttributeOrSubElementValue("Include", StringComparison.OrdinalIgnoreCase) ?? e.GetAttributeOrSubElementValue("Update", StringComparison.OrdinalIgnoreCase),
                packageName,
                StringComparison.OrdinalIgnoreCase) &&
            (e.GetAttributeOrSubElementValue("Version", StringComparison.OrdinalIgnoreCase) ?? e.GetAttributeOrSubElementValue("VersionOverride", StringComparison.OrdinalIgnoreCase)) is not null);

    private static async Task<bool> AreDependenciesCoherentAsync(string repoRootPath, string projectPath, string dependencyName, Logger logger, ImmutableArray<ProjectBuildFile> buildFiles, string[] tfms)
    {
        var updatedTopLevelDependencies = MSBuildHelper.GetTopLevelPackageDependencyInfos(buildFiles).ToArray();
        foreach (var tfm in tfms)
        {
            var updatedPackages = await MSBuildHelper.GetAllPackageDependenciesAsync(repoRootPath, projectPath, tfm, updatedTopLevelDependencies, logger);
            var dependenciesAreCoherent = await MSBuildHelper.DependenciesAreCoherentAsync(repoRootPath, projectPath, tfm, updatedPackages, logger);
            if (!dependenciesAreCoherent)
            {
                logger.Log($"    Package [{dependencyName}] could not be updated in [{projectPath}] because it would cause a dependency conflict.");
                return false;
            }
        }

        return true;
    }

    private static async Task SaveBuildFilesAsync(ImmutableArray<ProjectBuildFile> buildFiles, Logger logger)
    {
        foreach (var buildFile in buildFiles)
        {
            if (await buildFile.SaveAsync())
            {
                logger.Log($"    Saved [{buildFile.RelativePath}].");
            }
        }
    }
}
