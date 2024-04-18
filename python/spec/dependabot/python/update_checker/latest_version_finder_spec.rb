# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/credential"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/python/update_checker/latest_version_finder"

RSpec.describe Dependabot::Python::UpdateChecker::LatestVersionFinder do
  before do
    stub_request(:get, pypi_url)
      .with(headers: { "Accept" => "text/html" })
      .to_return(status: 200, body: pypi_response)
  end
  let(:pypi_url) { "https://pypi.org/simple/luigi/" }
  let(:pypi_response) { fixture("pypi", "pypi_simple_response.html") }
  let(:finder) do
    described_class.new(
      dependency: dependency,
      dependency_files: dependency_files,
      credentials: credentials,
      ignored_versions: ignored_versions,
      raise_on_ignored: raise_on_ignored,
      security_advisories: security_advisories
    )
  end
  let(:credentials) do
    [Dependabot::Credential.new({
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    })]
  end
  let(:ignored_versions) { [] }
  let(:raise_on_ignored) { false }
  let(:security_advisories) { [] }
  let(:dependency_files) { [requirements_file] }
  let(:pipfile) do
    Dependabot::DependencyFile.new(
      name: "Pipfile",
      content: fixture("pipfile_files", pipfile_fixture_name)
    )
  end
  let(:pipfile_fixture_name) { "exact_version" }
  let(:pyproject) do
    Dependabot::DependencyFile.new(
      name: "pyproject.toml",
      content: fixture("pyproject_files", pyproject_fixture_name)
    )
  end
  let(:pyproject_fixture_name) { "poetry_exact_requirement.toml" }
  let(:requirements_file) do
    Dependabot::DependencyFile.new(
      name: "requirements.txt",
      content: fixture("requirements", requirements_fixture_name)
    )
  end
  let(:requirements_fixture_name) { "version_specified.txt" }
  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: dependency_version,
      requirements: dependency_requirements,
      package_manager: "pip"
    )
  end
  let(:dependency_name) { "luigi" }
  let(:dependency_version) { "2.0.0" }
  let(:dependency_requirements) do
    [{
      file: "requirements.txt",
      requirement: "==2.0.0",
      groups: [],
      source: nil
    }]
  end

  describe "#latest_version" do
    subject { finder.latest_version }
    it { is_expected.to eq(Gem::Version.new("2.6.0")) }

    context "when the pypi link resolves to a redirect" do
      let(:redirect_url) { "https://pypi.org/LuiGi/json" }

      before do
        stub_request(:get, pypi_url)
          .to_return(status: 302, headers: { "Location" => redirect_url })
        stub_request(:get, redirect_url)
          .to_return(status: 200, body: pypi_response)
      end

      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "when the pypi link fails at first" do
      before do
        stub_request(:get, pypi_url)
          .to_raise(Excon::Error::Timeout).then
          .to_return(status: 200, body: pypi_response)
      end

      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "when the pypi link resolves to a 'Not Found' page" do
      let(:pypi_response) { "Not Found (no releases)<a href='#'>123</a>" }
      it { is_expected.to be_nil }
    end

    context "when the PyPI response includes zipped files" do
      let(:pypi_response) { fixture("pypi", "pypi_simple_response_zip.html") }
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "when the pypi link responds with devpi-style" do
      let(:pypi_response) { fixture("pypi", "pypi_simple_response_devpi.html") }
      let(:dependency_version) { "0.9.0" }

      it { is_expected.to eq(Gem::Version.new("0.10.2")) }
    end

    context "when the latest versions have been yanked" do
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_yanked.html")
      end
      it { is_expected.to eq(Gem::Version.new("2.4.0")) }
    end

    context "when the PyPI response includes multi-line links" do
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_multiline.html")
      end
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "when the PyPI response includes data-requires-python entries" do
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_django.html")
      end
      let(:pypi_url) { "https://pypi.org/simple/django/" }
      let(:dependency_name) { "django" }
      let(:dependency_version) { "1.2.4" }

      it { is_expected.to eq(Gem::Version.new("3.2.4")) }

      context "and a python version specified" do
        subject { finder.latest_version(python_version: python_version) }

        context "that allows the latest version" do
          let(:python_version) { Dependabot::Python::Version.new("3.6.3") }
          it { is_expected.to eq(Gem::Version.new("3.2.4")) }
        end

        context "that forbids the latest version" do
          let(:python_version) { Dependabot::Python::Version.new("2.7.11") }
          it { is_expected.to eq(Gem::Version.new("1.11.29")) }
        end
      end
    end

    context "when the dependency name isn't normalised" do
      let(:dependency_name) { "Luigi_ext" }
      let(:pypi_url) { "https://pypi.org/simple/luigi-ext/" }
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_underscore.html")
      end
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }

      context "and contains spaces" do
        let(:pypi_response) do
          fixture("pypi", "pypi_simple_response_space.html")
        end
        it { is_expected.to eq(Gem::Version.new("2.6.0")) }
      end
    end

    context "when the dependency name includes extras" do
      let(:dependency_name) { "luigi[toml]" }

      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "when the user's current version is a pre-release" do
      let(:dependency_version) { "2.6.0a1" }
      let(:dependency_requirements) do
        [{
          file: "requirements.txt",
          requirement: "==2.6.0a1",
          groups: [],
          source: nil
        }]
      end
      it { is_expected.to eq(Gem::Version.new("2.7.0b1")) }
    end

    context "raise_on_ignored when later versions are allowed" do
      let(:raise_on_ignored) { true }
      it "doesn't raise an error" do
        expect { subject }.to_not raise_error
      end
    end

    context "when the user is on the latest version" do
      let(:dependency_version) { "2.6.0" }
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }

      context "raise_on_ignored" do
        let(:raise_on_ignored) { true }
        it "doesn't raise an error" do
          expect { subject }.to_not raise_error
        end
      end
    end

    context "when the dependency version isn't known" do
      let(:dependency_version) { nil }

      context "raise_on_ignored" do
        let(:raise_on_ignored) { true }
        it "doesn't raise an error" do
          expect { subject }.to_not raise_error
        end
      end
    end

    context "when the user is ignoring all later versions" do
      let(:ignored_versions) { ["> 2.0.0"] }
      it { is_expected.to eq(Gem::Version.new("2.0.0")) }

      context "raise_on_ignored" do
        let(:raise_on_ignored) { true }
        it "raises an error" do
          expect { subject }.to raise_error(Dependabot::AllVersionsIgnored)
        end
      end
    end

    context "when the user is ignoring the latest version" do
      let(:ignored_versions) { [">= 2.0.0.a, < 3.0"] }
      it { is_expected.to eq(Gem::Version.new("1.3.0")) }
    end

    context "and the current requirement has a pre-release requirement" do
      let(:dependency_version) { nil }
      let(:dependency_requirements) do
        [{
          file: "requirements.txt",
          requirement: ">=2.6.0a1",
          groups: [],
          source: nil
        }]
      end
      it { is_expected.to eq(Gem::Version.new("2.7.0b1")) }
    end

    context "with a Pipfile with no source" do
      let(:pipfile_fixture_name) { "no_source" }
      let(:dependency_files) { [pipfile] }

      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "with a custom index-url" do
      let(:pypi_url) do
        "https://pypi.weasyldev.com/weasyl/source/+simple/luigi/"
      end

      context "set in a pip.conf file" do
        let(:dependency_files) do
          [
            Dependabot::DependencyFile.new(
              name: "pip.conf",
              content: fixture("pip_conf_files", "custom_index")
            )
          ]
        end

        it { is_expected.to eq(Gem::Version.new("2.6.0")) }

        context "with auth details that need handling carefully" do
          let(:dependency_files) do
            [
              Dependabot::DependencyFile.new(
                name: "pip.conf",
                content: fixture("pip_conf_files", "custom_index_double_at")
              )
            ]
          end

          it { is_expected.to eq(Gem::Version.new("2.6.0")) }
        end
      end

      context "set in a requirements.txt file" do
        let(:requirements_fixture_name) { "custom_index.txt" }
        let(:dependency_files) { [requirements_file] }
        it { is_expected.to eq(Gem::Version.new("2.6.0")) }

        context "and the url is invalid" do
          let(:requirements_fixture_name) { "custom_index_invalid.txt" }

          it "raises a helpful error" do
            error_class = Dependabot::DependencyFileNotResolvable
            expect { subject }
              .to raise_error(error_class) do |error|
                expect(error.message)
                  .to eq("Invalid URL: https://redacted@pypi.weasyldev.com/weasyl/source/+simple/")
              end
          end
        end
      end

      context "set in a Pipfile" do
        let(:pipfile_fixture_name) { "private_source" }
        let(:dependency_files) { [pipfile] }
        let(:pypi_url) { "https://some.internal.registry.com/pypi/luigi/" }
        it { is_expected.to eq(Gem::Version.new("2.6.0")) }

        context "that is unparseable" do
          let(:pipfile_fixture_name) { "unparseable" }
          let(:pypi_url) { "https://pypi.org/simple/luigi/" }
          it { is_expected.to eq(Gem::Version.new("2.6.0")) }
        end

        context "that 403s" do
          let(:pypi_base_url) { "https://some.internal.registry.com/pypi/" }
          before do
            stub_request(:get, pypi_url)
              .to_return(status: 403, body: pypi_response)
          end

          context "and the base URL also 403s" do
            before do
              stub_request(:get, pypi_base_url)
                .to_return(status: 403, body: pypi_response)
            end

            it "raises a helpful error" do
              error_class = Dependabot::PrivateSourceAuthenticationFailure
              expect { subject }
                .to raise_error(error_class) do |error|
                  expect(error.source)
                    .to eq("https://some.internal.registry.com/pypi/")
                end
            end
          end

          context "and the base URL 200s" do
            before do
              stub_request(:get, pypi_base_url)
                .to_return(status: 400, body: pypi_response)
            end

            it { is_expected.to eq(Gem::Version.new("2.6.0")) }
          end
        end
      end

      context "set in a pyproject.toml" do
        let(:pyproject_fixture_name) { "private_source.toml" }
        let(:dependency_files) { [pyproject] }
        let(:pypi_url) { "https://some.internal.registry.com/pypi/luigi/" }
        it { is_expected.to eq(Gem::Version.new("2.6.0")) }
      end

      context "set in credentials" do
        let(:credentials) do
          [Dependabot::Credential.new({
            "type" => "python_index",
            "index-url" => "https://pypi.weasyldev.com/weasyl/source/+simple",
            "replaces-base" => true
          })]
        end

        it { is_expected.to eq(Gem::Version.new("2.6.0")) }

        context "with credentials passed as a token" do
          before do
            stub_request(:get, pypi_url).to_return(status: 404, body: "")
            stub_request(:get, pypi_url)
              .with(basic_auth: %w(user pass))
              .to_return(status: 200, body: pypi_response)
          end

          let(:credentials) do
            [Dependabot::Credential.new({
              "type" => "python_index",
              "index-url" => "https://pypi.weasyldev.com/weasyl/source/+simple",
              "token" => "user:pass",
              "replaces-base" => true
            })]
          end

          it { is_expected.to eq(Gem::Version.new("2.6.0")) }
        end
      end
    end

    context "with an extra-index-url" do
      let(:extra_url) do
        "https://pypi.weasyldev.com/weasyl/source/+simple/luigi/"
      end
      let(:extra_response) do
        fixture("pypi", "pypi_simple_response_extra.html")
      end
      before do
        stub_request(:get, extra_url)
          .to_return(status: 200, body: extra_response)
      end

      context "set in a pip.conf file" do
        let(:dependency_files) do
          [
            Dependabot::DependencyFile.new(
              name: "pip.conf",
              content: fixture("pip_conf_files", "extra_index")
            )
          ]
        end

        its(:to_s) { is_expected.to eq("3.0.0+weasyl.2") }

        context "that includes an environment variables" do
          let(:dependency_files) do
            [
              Dependabot::DependencyFile.new(
                name: "pip.conf",
                content: fixture("pip_conf_files", "extra_index_env_variable")
              )
            ]
          end

          it "raises a helpful error" do
            error_class = Dependabot::PrivateSourceAuthenticationFailure
            expect { subject }
              .to raise_error(error_class) do |error|
                expect(error.source)
                  .to eq("https://pypi.weasyldev.com/${SECURE_NAME}" \
                         "/source/+simple/")
              end
          end

          context "that was provided as a config variable" do
            let(:credentials) do
              [Dependabot::Credential.new({
                "type" => "python_index",
                "index-url" => "https://pypi.weasyldev.com/weasyl/" \
                               "source/+simple",
                "replaces-base" => false
              })]
            end

            its(:to_s) { is_expected.to eq("3.0.0+weasyl.2") }

            context "with a gemfury style" do
              let(:credentials) do
                [Dependabot::Credential.new({
                  "type" => "python_index",
                  "index-url" => "https://pypi.weasyldev.com/source/+simple"
                })]
              end
              let(:url) { "https://pypi.weasyldev.com/source/+simple/luigi/" }

              before do
                stub_request(:get, url)
                  .to_return(status: 200, body: extra_response)
              end

              its(:to_s) { is_expected.to eq("3.0.0+weasyl.2") }
            end
          end
        end
      end

      context "set in a requirements.txt file" do
        let(:dependency_files) do
          [
            Dependabot::DependencyFile.new(
              name: "requirements.txt",
              content: fixture("requirements", "extra_index.txt")
            )
          ]
        end

        its(:to_s) { is_expected.to eq("3.0.0+weasyl.2") }

        context "that times out" do
          before do
            stub_request(:get, extra_url).to_raise(Excon::Error::Timeout)
          end

          it "raises a helpful error" do
            error_class = Dependabot::PrivateSourceTimedOut
            expect { subject }
              .to raise_error(error_class) do |error|
                expect(error.source)
                  .to eq("https://pypi.weasyldev.com/weasyl/source/+simple/")
              end
          end
        end
      end

      context "set in credentials" do
        let(:credentials) do
          [Dependabot::Credential.new({
            "type" => "python_index",
            "index-url" => "https://pypi.weasyldev.com/weasyl/source/+simple",
            "replaces-base" => false
          })]
        end

        its(:to_s) { is_expected.to eq("3.0.0+weasyl.2") }

        context "that times out" do
          before do
            stub_request(:get, extra_url).to_raise(Excon::Error::Timeout)
          end

          it "raises a helpful error" do
            error_class = Dependabot::PrivateSourceTimedOut
            expect { subject }
              .to raise_error(error_class) do |error|
                expect(error.source)
                  .to eq("https://pypi.weasyldev.com/weasyl/source/+simple/")
              end
          end
        end
      end
    end
  end

  describe "#latest_version_with_no_unlock" do
    subject { finder.latest_version_with_no_unlock }
    let(:dependency) do
      Dependabot::Dependency.new(
        name: dependency_name,
        version: version,
        requirements: requirements,
        package_manager: "pip"
      )
    end
    let(:requirements) do
      [{ file: "req.txt", requirement: req_string, groups: [], source: nil }]
    end

    context "with no requirement" do
      let(:req_string) { nil }
      let(:version) { nil }
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }

      context "when the user is ignoring the latest version" do
        let(:ignored_versions) { [">= 2.0.0.a, < 3.0"] }
        it { is_expected.to eq(Gem::Version.new("1.3.0")) }
      end

      context "when the latest versions have been yanked" do
        let(:pypi_response) do
          fixture("pypi", "pypi_simple_response_yanked.html")
        end
        it { is_expected.to eq(Gem::Version.new("2.4.0")) }
      end

      context "when the PyPI response includes data-requires-python entries" do
        let(:pypi_response) do
          fixture("pypi", "pypi_simple_response_django.html")
        end
        let(:pypi_url) { "https://pypi.org/simple/django/" }
        let(:dependency_name) { "django" }
        let(:dependency_version) { "1.2.4" }

        it { is_expected.to eq(Gem::Version.new("3.2.4")) }

        context "and a python version specified" do
          subject do
            finder.latest_version_with_no_unlock(python_version: python_version)
          end

          context "that allows the latest version" do
            let(:python_version) { Dependabot::Python::Version.new("3.6.3") }
            it { is_expected.to eq(Gem::Version.new("3.2.4")) }
          end

          context "that forbids the latest version" do
            let(:python_version) { Dependabot::Python::Version.new("2.7.11") }
            it { is_expected.to eq(Gem::Version.new("1.11.29")) }
          end
        end
      end
    end

    context "with an equality string" do
      let(:req_string) { "==2.0.0" }
      let(:version) { "2.0.0" }
      it { is_expected.to eq(Gem::Version.new("2.0.0")) }
    end

    context "with a >= string" do
      let(:req_string) { ">=2.0.0" }
      let(:version) { nil }
      it { is_expected.to eq(Gem::Version.new("2.6.0")) }
    end

    context "with a full range string" do
      let(:req_string) { ">=2.0.0,<2.5.0" }
      let(:version) { nil }
      it { is_expected.to eq(Gem::Version.new("2.4.0")) }
    end

    context "with a ~= string" do
      let(:req_string) { "~=2.0.0" }
      let(:version) { nil }
      it { is_expected.to eq(Gem::Version.new("2.0.1")) }
    end

    context "with multiple requirements" do
      let(:requirements) do
        [
          { file: "req.txt", requirement: req1, groups: [], source: nil },
          { file: "req2.txt", requirement: req2, groups: [], source: nil }
        ]
      end
      let(:req1) { "~=2.0" }
      let(:req2) { "<=2.5.0" }
      let(:version) { nil }
      it { is_expected.to eq(Gem::Version.new("2.5.0")) }
    end
  end

  describe "#lowest_security_fix_version" do
    subject { finder.lowest_security_fix_version }

    let(:dependency_version) { "2.0.0" }
    let(:security_advisories) do
      [
        Dependabot::SecurityAdvisory.new(
          dependency_name: dependency_name,
          package_manager: "pip",
          vulnerable_versions: ["<= 2.1.0"]
        )
      ]
    end
    it { is_expected.to eq(Gem::Version.new("2.1.1")) }

    context "when the lowest version has been yanked" do
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_yanked.html")
      end
      it { is_expected.to eq(Gem::Version.new("2.2.0")) }
    end

    context "when the user has ignored all versions" do
      let(:ignored_versions) { ["> 0"] }
      it "returns nil" do
        expect(subject).to be_nil
      end

      context "raise_on_ignored" do
        let(:raise_on_ignored) { true }
        it "raises an error" do
          expect { subject }.to raise_error(Dependabot::AllVersionsIgnored)
        end
      end
    end

    context "when the PyPI response includes data-requires-python entries" do
      let(:pypi_response) do
        fixture("pypi", "pypi_simple_response_django.html")
      end
      let(:pypi_url) { "https://pypi.org/simple/django/" }
      let(:dependency_name) { "django" }
      let(:dependency_version) { "1.2.4" }

      it { is_expected.to eq(Gem::Version.new("2.1.1")) }

      context "and a python version specified" do
        subject do
          finder.lowest_security_fix_version(python_version: python_version)
        end

        context "that allows the safe version" do
          let(:python_version) { Dependabot::Python::Version.new("3.6.3") }
          it { is_expected.to eq(Gem::Version.new("2.1.1")) }
        end

        context "that forbids the safe version" do
          let(:python_version) { Dependabot::Python::Version.new("2.7.11") }
          it { is_expected.to be_nil }
        end
      end
    end
  end
end
