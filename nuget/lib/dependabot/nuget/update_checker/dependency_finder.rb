# typed: strict
# frozen_string_literal: true

require "nokogiri"
require "sorbet-runtime"
require "stringio"
require "zip"

require "dependabot/update_checkers/base"
require "dependabot/nuget/version"

module Dependabot
  module Nuget
    class UpdateChecker < Dependabot::UpdateCheckers::Base
      class DependencyFinder
        extend T::Sig

        require_relative "requirements_updater"
        require_relative "nuspec_fetcher"

        sig { returns(T::Hash[String, T.untyped]) }
        def self.transitive_dependencies_cache
          CacheManager.cache("dependency_finder_transitive_dependencies")
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def self.updated_peer_dependencies_cache
          CacheManager.cache("dependency_finder_updated_peer_dependencies")
        end

        sig { returns(T::Hash[String, T.untyped]) }
        def self.fetch_dependencies_cache
          CacheManager.cache("dependency_finder_fetch_dependencies")
        end

        sig do
          params(
            dependency: Dependabot::Dependency,
            dependency_files: T::Array[Dependabot::DependencyFile],
            credentials: T::Array[Dependabot::Credential],
            repo_contents_path: T.nilable(String)
          ).void
        end
        def initialize(dependency:, dependency_files:, credentials:, repo_contents_path:)
          @dependency             = dependency
          @dependency_files       = dependency_files
          @credentials            = credentials
          @repo_contents_path     = repo_contents_path
        end

        sig { returns(T::Array[Dependabot::Dependency]) }
        def transitive_dependencies
          key = "#{dependency.name.downcase}::#{dependency.version}"
          cache = DependencyFinder.transitive_dependencies_cache

          unless cache[key]
            begin
              # first do a quick sanity check on the version string; if it can't be parsed, an exception will be raised
              _ = Version.new(dependency.version)

              cache[key] = fetch_transitive_dependencies(
                @dependency.name,
                T.must(@dependency.version)
              ).map do |dependency_info|
                package_name = dependency_info["packageName"]
                target_version = dependency_info["version"]

                Dependency.new(
                  name: package_name,
                  version: target_version.to_s,
                  requirements: [], # Empty requirements for transitive dependencies
                  package_manager: @dependency.package_manager
                )
              end
            rescue StandardError
              # if anything happened above, there are no meaningful dependencies that can be derived
              cache[key] = []
            end
          end

          cache[key]
        end

        sig { returns(T::Array[Dependabot::Dependency]) }
        def updated_peer_dependencies
          key = "#{dependency.name.downcase}::#{dependency.version}"
          cache = DependencyFinder.updated_peer_dependencies_cache

          cache[key] ||= fetch_transitive_dependencies(
            @dependency.name,
            T.must(@dependency.version)
          ).filter_map do |dependency_info|
            package_name = dependency_info["packageName"]
            target_version = dependency_info["version"]

            # Find the Dependency object for the peer dependency. We will not return
            # dependencies that are not referenced from dependency files.
            peer_dependency = top_level_dependencies.find { |d| d.name == package_name }
            next unless peer_dependency
            next unless target_version > peer_dependency.numeric_version

            # Use version finder to determine the source details for the peer dependency.
            target_version_details = version_finder(peer_dependency).versions.find do |v|
              v.fetch(:version) == target_version
            end
            next unless target_version_details

            Dependency.new(
              name: peer_dependency.name,
              version: target_version_details.fetch(:version).to_s,
              requirements: updated_requirements(peer_dependency, target_version_details),
              previous_version: peer_dependency.version,
              previous_requirements: peer_dependency.requirements,
              package_manager: peer_dependency.package_manager,
              metadata: { information_only: true } # Instruct updater to not directly update this dependency
            )
          end

          cache[key]
        end

        private

        sig { returns(Dependabot::Dependency) }
        attr_reader :dependency

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        attr_reader :dependency_files

        sig { returns(T::Array[Dependabot::Credential]) }
        attr_reader :credentials

        sig { returns(T.nilable(String)) }
        attr_reader :repo_contents_path

        sig do
          params(
            dep: Dependabot::Dependency,
            target_version_details: T::Hash[Symbol, T.untyped]
          )
            .returns(T::Array[T::Hash[String, T.untyped]])
        end
        def updated_requirements(dep, target_version_details)
          @updated_requirements ||= T.let({}, T.nilable(T::Hash[String, T.untyped]))
          @updated_requirements[dep.name] ||=
            RequirementsUpdater.new(
              requirements: dep.requirements,
              latest_version: target_version_details.fetch(:version).to_s,
              source_details: target_version_details.slice(:nuspec_url, :repo_url, :source_url)
            ).updated_requirements
        end

        sig { returns(T::Array[Dependabot::Dependency]) }
        def top_level_dependencies
          @top_level_dependencies ||=
            T.let(
              Nuget::FileParser.new(
                dependency_files: dependency_files,
                repo_contents_path: repo_contents_path,
                source: nil
              ).parse.select(&:top_level?),
              T.nilable(T::Array[Dependabot::Dependency])
            )
        end

        sig { returns(T::Array[Dependabot::DependencyFile]) }
        def nuget_configs
          @nuget_configs ||=
            T.let(
              @dependency_files.select { |f| f.name.match?(/nuget\.config$/i) },
              T.nilable(T::Array[Dependabot::DependencyFile])
            )
        end

        sig { returns(T::Array[T::Hash[Symbol, String]]) }
        def dependency_urls
          @dependency_urls ||=
            T.let(
              RepositoryFinder.new(
                dependency: @dependency,
                credentials: @credentials,
                config_files: nuget_configs
              )
              .dependency_urls
              .select { |url| url.fetch(:repository_type) == "v3" },
              T.nilable(T::Array[T::Hash[Symbol, String]])
            )
        end

        sig { params(package_id: String, package_version: String).returns(T::Array[T::Hash[String, T.untyped]]) }
        def fetch_transitive_dependencies(package_id, package_version)
          all_dependencies = {}
          fetch_transitive_dependencies_impl(package_id, package_version, all_dependencies)
          all_dependencies.map { |_, dependency_info| dependency_info }
        end

        sig { params(package_id: String, package_version: String, all_dependencies: T::Hash[String, T.untyped]).void }
        def fetch_transitive_dependencies_impl(package_id, package_version, all_dependencies)
          dependencies = fetch_dependencies(package_id, package_version)
          return unless dependencies.any?

          dependencies.each do |dependency|
            next if dependency.nil?

            dependency_id = dependency["packageName"]
            dependency_version_range = dependency["versionRange"]

            nuget_version_range_regex = /[\[(](\d+(\.\d+)*(-\w+(\.\d+)*)?)/
            nuget_version_range_match_data = nuget_version_range_regex.match(dependency_version_range)

            dependency_version = if nuget_version_range_match_data.nil?
                                   dependency_version_range
                                 else
                                   nuget_version_range_match_data[1]
                                 end

            dependency["version"] = Version.new(dependency_version)

            current_dependency = all_dependencies[dependency_id.downcase]
            next unless current_dependency.nil? || current_dependency["version"] < dependency["version"]

            all_dependencies[dependency_id.downcase] = dependency
            fetch_transitive_dependencies_impl(dependency_id, dependency_version, all_dependencies)
          end
        end

        sig { params(package_id: String, package_version: String).returns(T::Array[T::Hash[String, T.untyped]]) }
        def fetch_dependencies(package_id, package_version)
          key = "#{package_id.downcase}::#{package_version}"
          cache = DependencyFinder.fetch_dependencies_cache

          cache[key] ||= begin
            nuspec_xml = NuspecFetcher.fetch_nuspec(dependency_urls, package_id, package_version)
            if nuspec_xml.nil?
              []
            else
              read_dependencies_from_nuspec(nuspec_xml)
            end
          end

          cache[key]
        end

        sig { params(nuspec_xml: Nokogiri::XML::Document).returns(T::Array[T::Hash[String, String]]) }
        def read_dependencies_from_nuspec(nuspec_xml) # rubocop:disable Metrics/PerceivedComplexity
          # we want to exclude development dependencies from the lookup
          allowed_attributes = %w(all compile native runtime)

          nuspec_xml_dependencies = nuspec_xml.xpath("//dependencies/child::node()/dependency").select do |dependency|
            include_attr = dependency.attribute("include")
            exclude_attr = dependency.attribute("exclude")

            if include_attr.nil? && exclude_attr.nil?
              true
            elsif include_attr
              include_values = include_attr.value.split(",").map(&:strip)
              include_values.any? { |element1| allowed_attributes.any? { |element2| element1.casecmp?(element2) } }
            else
              exclude_values = exclude_attr.value.split(",").map(&:strip)
              exclude_values.none? { |element1| allowed_attributes.any? { |element2| element1.casecmp?(element2) } }
            end
          end

          dependency_list = []
          nuspec_xml_dependencies.each do |dependency|
            next unless dependency.attribute("version")

            dependency_list << {
              "packageName" => dependency.attribute("id").value,
              "versionRange" => dependency.attribute("version").value
            }
          end

          dependency_list
        end

        sig { params(dep: Dependabot::Dependency).returns(Dependabot::Nuget::UpdateChecker::VersionFinder) }
        def version_finder(dep)
          VersionFinder.new(
            dependency: dep,
            dependency_files: dependency_files,
            credentials: credentials,
            ignored_versions: [],
            raise_on_ignored: false,
            security_advisories: [],
            repo_contents_path: repo_contents_path
          )
        end
      end
    end
  end
end
