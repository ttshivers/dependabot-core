# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency_file"
require "dependabot/nuget/file_fetcher/sln_project_paths_finder"

RSpec.describe Dependabot::Nuget::FileFetcher::SlnProjectPathsFinder do
  let(:finder) { described_class.new(sln_file: sln_file) }

  let(:sln_file) do
    Dependabot::DependencyFile.new(content: sln_body, name: sln_file_name)
  end
  let(:sln_file_name) { "GraphQL.Client.sln" }
  let(:sln_body) { fixture("sln_files", fixture_name) }

  describe "#project_paths" do
    subject(:project_paths) { finder.project_paths }

    let(:fixture_name) { "GraphQL.Client.sln" }

    it "gets the correct paths" do
      expect(project_paths)
        .to match_array(
          %w(
            src/GraphQL.Common/GraphQL.Common.csproj
            src/GraphQL.Client/GraphQL.Client.csproj
            tests/GraphQL.Client.Tests/GraphQL.Client.Tests.csproj
            tests/GraphQL.Common.Tests/GraphQL.Common.Tests.csproj
            samples/GraphQL.Client.Sample/GraphQL.Client.Sample.csproj
          )
        )
    end

    context "with non-standard project names" do
      let(:fixture_name) { "nanoFramework.Runtime.Events.sln" }

      it "gets the correct paths" do
        expect(project_paths)
          .to match_array(%w(nanoFramework.Runtime.Events.nfproj))
      end
    end

    context "when this project is already in a nested directory" do
      let(:sln_file_name) { "nested/GraphQL.Client.sln" }

      it "gets the correct paths" do
        expect(project_paths)
          .to match_array(
            %w(
              nested/src/GraphQL.Common/GraphQL.Common.csproj
              nested/src/GraphQL.Client/GraphQL.Client.csproj
              nested/tests/GraphQL.Client.Tests/GraphQL.Client.Tests.csproj
              nested/tests/GraphQL.Common.Tests/GraphQL.Common.Tests.csproj
              nested/samples/GraphQL.Client.Sample/GraphQL.Client.Sample.csproj
            )
          )
      end
    end

    context "when the solution has relative links outside its own directory" do
      let(:fixture_name) { "SolutionWithRelativePaths.sln" }
      let(:sln_file_name) { "SolutionWithRelativePaths.sln" }
      let(:sln_file) do
        Dependabot::DependencyFile.new(content: sln_body, name: sln_file_name, directory: "src/")
      end

      it "returns the normalized project paths" do
        expect(project_paths)
          .to match_array(
            %w(
              TheLibrary.csproj
              ../test/TheTests.csproj
            )
          )
      end
    end

    context "when the directory is specified it's not duplicated in the final path" do
      let(:sln_body) { fixture("github", "solution_in_subdirectory", "src", "SolutionInASubDirectory.sln") }
      let(:sln_file_name) { "/ABC/SolutionInASubDirectory.sln" }
      let(:sln_file) do
        Dependabot::DependencyFile.new(content: sln_body, name: sln_file_name, directory: "/ABC/")
      end

      it "returns the correctly appended paths" do
        expect(project_paths)
          .to match_array(
            %w(
              /ABC/ABC.Web/ABC.Web.csproj
              /ABC/ABC.Contracts/ABC.Contracts.csproj
            )
          )
      end
    end
  end
end
