# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/cargo/metadata_finder"
require_common_spec "metadata_finders/shared_examples_for_metadata_finders"

RSpec.describe Dependabot::Cargo::MetadataFinder do
  it_behaves_like "a dependency metadata finder"

  let(:dependency) do
    Dependabot::Dependency.new(
      name: dependency_name,
      version: "1.3.0",
      requirements: [{
        file: "Cargo.toml",
        requirement: "~1.3.0",
        groups: [],
        source: dependency_source
      }],
      package_manager: "cargo"
    )
  end
  subject(:finder) do
    described_class.new(dependency: dependency, credentials: credentials)
  end
  let(:credentials) do
    [{
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => "token"
    }]
  end
  let(:dependency_name) { "bitflags" }
  let(:dependency_source) { nil }

  before do
    stub_request(:get, "https://example.com/status").to_return(
      status: 200,
      body: "Not GHES",
      headers: {}
    )
  end

  describe "#source_url" do
    subject(:source_url) { finder.source_url }
    let(:crates_url) { "https://crates.io/api/v1/crates/bitflags" }

    before do
      stub_request(:get, crates_url)
        .to_return(
          status: 200,
          body: crates_response
        )
    end
    let(:crates_response) do
      fixture("crates_io_responses", crates_fixture_name)
    end
    let(:crates_fixture_name) { "bitflags.json" }

    context "when there is a github link in the crates.io response" do
      let(:crates_fixture_name) { "bitflags.json" }

      it { is_expected.to eq("https://github.com/rust-lang-nursery/bitflags") }

      it "caches the call to crates.io" do
        2.times { source_url }
        expect(WebMock).to have_requested(:get, crates_url).once
      end
    end

    context "when there is no recognised source link in the response" do
      let(:crates_response) do
        fixture("crates_io_responses", crates_fixture_name).gsub!("github.com", "example.com")
      end

      it { is_expected.to be_nil }

      it "caches the call to crates.io" do
        2.times { source_url }
        expect(WebMock).to have_requested(:get, crates_url).once
      end
    end

    context "when the crates.io link resolves to a redirect" do
      let(:redirect_url) { "https://crates.io/api/v1/crates/Bitflags" }
      let(:crates_fixture_name) { "bitflags.json" }

      before do
        stub_request(:get, crates_url)
          .to_return(status: 302, headers: { "Location" => redirect_url })
        stub_request(:get, redirect_url)
          .to_return(status: 200, body: crates_response)
      end

      it { is_expected.to eq("https://github.com/rust-lang-nursery/bitflags") }
    end

    context "for a git source" do
      let(:crates_response) { nil }
      let(:dependency_source) do
        { type: "git", url: "https://github.com/my_fork/bitflags" }
      end

      it { is_expected.to eq("https://github.com/my_fork/bitflags") }

      context "that doesn't match a supported source" do
        let(:dependency_source) do
          { type: "git", url: "https://example.com/my_fork/bitflags" }
        end

        it { is_expected.to be_nil }
      end
    end
  end
end
