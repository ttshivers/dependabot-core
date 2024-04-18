# typed: false
# frozen_string_literal: true

require "spec_helper"
require "dependabot/hex/update_checker/requirements_updater"

RSpec.describe Dependabot::Hex::UpdateChecker::RequirementsUpdater do
  let(:updater) do
    described_class.new(
      requirements: requirements,
      latest_resolvable_version: latest_resolvable_version,
      updated_source: updated_source
    )
  end

  let(:requirements) { [mixfile_req] }
  let(:updated_source) { nil }
  let(:mixfile_req) do
    {
      file: "mix.exs",
      requirement: mixfile_req_string,
      groups: [],
      source: nil
    }
  end
  let(:mixfile_req_string) { "~> 1.4.0" }

  let(:latest_resolvable_version) { "1.5.0" }

  describe "#updated_requirements" do
    subject { updater.updated_requirements.first }

    specify { expect(updater.updated_requirements.count).to eq(1) }

    let(:mixfile_req_string) { "~> 1.0.0" }
    let(:latest_resolvable_version) { nil }

    context "when there is no resolvable version" do
      let(:latest_resolvable_version) { nil }
      its([:requirement]) { is_expected.to eq(mixfile_req_string) }
    end

    context "with a git dependency" do
      let(:latest_resolvable_version) do
        "aa218f56b14c9653891f9e74264a383fa43fefbd"
      end
      let(:requirements) { [mixfile_req, git_req] }
      let(:git_req) do
        {
          file: "mix.exs",
          requirement: nil,
          groups: [],
          source: {
            type: "git",
            url: "https://github.com/dependabot-fixtures/phoenix.git",
            branch: "master",
            ref: nil
          }
        }
      end
      let(:updated_source) do
        {
          type: "git",
          url: "https://github.com/dependabot-fixtures/phoenix.git",
          branch: "master",
          ref: nil
        }
      end
      subject { updater.updated_requirements }
      it { is_expected.to eq([mixfile_req, git_req]) }

      context "when asked to update the source" do
        let(:updated_source) { { type: "git", ref: "v1.5.0" } }
        before { git_req.merge!(source: { type: "git", ref: "v1.2.0" }) }

        it "updates the git requirement, but not the registry one" do
          expect(updater.updated_requirements)
            .to eq([mixfile_req, git_req.merge!(source: updated_source)])
        end
      end
    end

    context "when there is a resolvable version" do
      let(:latest_resolvable_version) { "1.5.0" }

      context "and a full version was previously specified" do
        let(:mixfile_req_string) { "1.2.3" }
        its([:requirement]) { is_expected.to eq("1.5.0") }

        context "with an == operator" do
          let(:mixfile_req_string) { "== 1.2.3" }
          its([:requirement]) { is_expected.to eq("== 1.5.0") }
        end
      end

      context "and a partial version was previously specified" do
        let(:mixfile_req_string) { "0.1" }
        its([:requirement]) { is_expected.to eq("1.5") }
      end

      context "and the new version has fewer digits than the old one" do
        let(:mixfile_req_string) { "1.1.0.1" }
        its([:requirement]) { is_expected.to eq("1.5.0") }
      end

      context "and a tilde was previously specified" do
        let(:mixfile_req_string) { "~> 0.2.3" }
        its([:requirement]) { is_expected.to eq("~> 1.5.0") }

        context "specified at two digits" do
          let(:mixfile_req_string) { "~> 0.2" }
          its([:requirement]) { is_expected.to eq("~> 1.5") }
        end

        context "that is already satisfied" do
          let(:mixfile_req_string) { "~> 1.2" }
          its([:requirement]) { is_expected.to eq(mixfile_req_string) }
        end
      end

      context "and a < was previously specified" do
        let(:mixfile_req_string) { "< 1.2.3" }
        its([:requirement]) { is_expected.to eq("< 1.5.1") }

        context "that is already satisfied" do
          let(:mixfile_req_string) { "< 2.0.0" }
          its([:requirement]) { is_expected.to eq(mixfile_req_string) }
        end
      end

      context "and there were multiple specifications" do
        let(:mixfile_req_string) { "> 1.0.0 and < 1.2.0" }
        its([:requirement]) { is_expected.to eq("> 1.0.0 and < 1.6.0") }

        context "that are already satisfied" do
          let(:mixfile_req_string) { "> 1.0.0 and < 2.0.0" }
          its([:requirement]) { is_expected.to eq(mixfile_req_string) }
        end

        context "specified with an or" do
          let(:latest_resolvable_version) { "2.5.0" }

          let(:mixfile_req_string) { "~> 0.2 or ~> 1.0" }

          its([:requirement]) do
            is_expected.to eq("~> 0.2 or ~> 1.0 or ~> 2.5")
          end

          context "one of which is already satisfied" do
            let(:mixfile_req_string) { "~> 0.2 or < 3.0.0" }
            its([:requirement]) { is_expected.to eq(mixfile_req_string) }
          end
        end
      end

      context "and multiple mix.exs files specified the dependency" do
        subject(:updated_requirements) { updater.updated_requirements }

        let(:requirements) do
          [
            {
              file: "apps/dependabot_business/mix.exs",
              requirement: "~> 1.3.0",
              groups: [],
              source: nil
            },
            {
              file: "apps/dependabot_web/mix.exs",
              requirement: "1.3.6",
              groups: [],
              source: nil
            }
          ]
        end

        it "updates both requirements" do
          expect(updated_requirements)
            .to match_array(
              [
                {
                  file: "apps/dependabot_business/mix.exs",
                  requirement: "~> 1.5.0",
                  groups: [],
                  source: nil
                },
                {
                  file: "apps/dependabot_web/mix.exs",
                  requirement: "1.5.0",
                  groups: [],
                  source: nil
                }
              ]
            )
        end
      end
    end
  end
end
