# typed: false
# frozen_string_literal: true

require "spec_helper"

require "dependabot/python/update_checker/requirements_updater"
require "dependabot/requirements_update_strategy"

RSpec.describe Dependabot::Python::UpdateChecker::RequirementsUpdater do
  let(:updater) do
    described_class.new(
      requirements: requirements,
      latest_resolvable_version: latest_resolvable_version,
      update_strategy: update_strategy,
      has_lockfile: has_lockfile
    )
  end

  let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::BumpVersions }
  let(:requirements) { [requirement_txt_req, setup_py_req, setup_cfg_req].compact }
  let(:requirement_txt_req) do
    {
      file: "requirements.txt",
      requirement: requirement_txt_req_string,
      groups: [],
      source: nil
    }
  end
  let(:setup_py_req) do
    {
      file: "setup.py",
      requirement: setup_py_req_string,
      groups: [],
      source: nil
    }
  end
  let(:setup_cfg_req) do
    {
      file: "setup.cfg",
      requirement: setup_cfg_req_string,
      groups: [],
      source: nil
    }
  end
  let(:requirement_txt_req_string) { "==1.4.0" }
  let(:setup_py_req_string) { ">= 1.4.0" }
  let(:setup_cfg_req_string) { ">= 1.4.0" }
  let(:has_lockfile) { true }

  let(:latest_resolvable_version) { "1.5.0" }

  describe "#updated_requirements" do
    subject(:updated_requirements) { updater.updated_requirements }

    context "for a requirements.txt dependency" do
      subject do
        updated_requirements.find { |r| r[:file] == "requirements.txt" }
      end

      context "when there is no resolvable version" do
        let(:latest_resolvable_version) { nil }
        it { is_expected.to eq(requirement_txt_req) }
      end

      context "when there is a resolvable version" do
        let(:latest_resolvable_version) { "1.5.0" }

        context "and a full version was previously pinned" do
          let(:requirement_txt_req_string) { "==1.4.0" }
          its([:requirement]) { is_expected.to eq("==1.5.0") }

          context "that has fewer digits than the new version" do
            let(:requirement_txt_req_string) { "==1.4.0" }
            let(:latest_resolvable_version) { "1.5.0.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0.1") }
          end

          context "that had a local version" do
            let(:requirement_txt_req_string) { "==1.4.0+gc.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0") }
          end

          context "and used the arbitrary equality matcher" do
            let(:requirement_txt_req_string) { "===1.4.0" }
            its([:requirement]) { is_expected.to eq("===1.5.0") }
          end

          context "and used a single equals (Poetry)" do
            let(:requirement_txt_req_string) { "=1.4.0" }
            its([:requirement]) { is_expected.to eq("=1.5.0") }
          end
        end

        context "and no requirement was specified" do
          let(:requirement_txt_req_string) { nil }
          it { is_expected.to eq(requirement_txt_req) }
        end

        context "and an asterisk was specified" do
          let(:requirement_txt_req_string) { "*" }
          it { is_expected.to eq(requirement_txt_req) }
        end

        context "and a != req was specified" do
          let(:requirement_txt_req_string) { "!= 1.3.0" }
          it { is_expected.to eq(requirement_txt_req) }

          context "for exactly the version being updated to" do
            let(:requirement_txt_req_string) { "!=1.5.0" }
            its([:requirement]) { is_expected.to eq(:unfixable) }
          end
        end

        context "and a range requirement was specified" do
          let(:requirement_txt_req_string) { ">=1.3.0" }
          it { is_expected.to eq(requirement_txt_req) }

          context "that is too high" do
            let(:requirement_txt_req_string) { ">=2.0.0" }
            its([:requirement]) { is_expected.to eq(:unfixable) }
          end

          context "that had a local version" do
            let(:requirement_txt_req_string) { ">=1.3.0+gc.1" }
            it { is_expected.to eq(requirement_txt_req) }
          end

          context "with an upper bound" do
            let(:requirement_txt_req_string) { ">=1.3.0, <=1.5.0" }
            it { is_expected.to eq(requirement_txt_req) }

            context "that needs updating" do
              let(:requirement_txt_req_string) { ">=1.3.0, <1.5" }
              its([:requirement]) { is_expected.to eq(">=1.3.0,<1.6") }

              context "and has more digits than the new version" do
                let(:requirement_txt_req_string) { "<=1.9.2,>=1.9" }
                let(:latest_resolvable_version) { "1.10" }

                its([:requirement]) { is_expected.to eq(">=1.9,<=1.10") }
              end
            end
          end
        end

        context "and a compatibility requirement was specified" do
          let(:requirement_txt_req_string) { "~=1.3.0" }
          its([:requirement]) { is_expected.to eq("~=1.5.0") }

          context "that supports the new version" do
            let(:requirement_txt_req_string) { "~=1.3" }
            its([:requirement]) { is_expected.to eq("~=1.5") }

            context "with the bump_versions_if_necessary update strategy" do
              let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::BumpVersionsIfNecessary }

              its([:requirement]) { is_expected.to eq("~=1.3") }
            end

            context "with the widen_ranges update strategy" do
              let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::WidenRanges }

              its([:requirement]) { is_expected.to eq("~=1.3") }
            end
          end

          context "that does not support the new version" do
            let(:requirement_txt_req_string) { "~=1.3" }
            let(:latest_resolvable_version) { "2.1.0" }
            its([:requirement]) { is_expected.to eq("~=2.1") }

            context "with the bump_versions_if_necessary update strategy" do
              let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::BumpVersionsIfNecessary }

              its([:requirement]) { is_expected.to eq("~=2.1") }
            end

            context "with the widen_ranges update strategy" do
              let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::WidenRanges }

              its([:requirement]) { is_expected.to eq(">=1.3,<3.0") }
            end
          end
        end

        context "and a prefix match was specified" do
          context "that is satisfied" do
            let(:requirement_txt_req_string) { "==1.*.*" }
            it { is_expected.to eq(requirement_txt_req) }
          end

          context "that needs updating" do
            let(:requirement_txt_req_string) { "==1.4.*" }
            its([:requirement]) { is_expected.to eq("==1.5.*") }
          end

          context "along with an exact match" do
            let(:requirement_txt_req_string) { "==1.4.*, ==1.4.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0") }
          end
        end
      end
    end

    context "for a setup.py dependency" do
      subject { updated_requirements.find { |r| r[:file] == "setup.py" } }

      context "when there is no resolvable version" do
        let(:latest_resolvable_version) { nil }
        it { is_expected.to eq(setup_py_req) }
      end

      context "when there is a resolvable version" do
        let(:latest_resolvable_version) { "1.5.0" }

        context "and a full version was previously pinned" do
          let(:setup_py_req_string) { "==1.4.0" }
          its([:requirement]) { is_expected.to eq("==1.5.0") }

          context "that has fewer digits than the new version" do
            let(:setup_py_req_string) { "==1.4.0" }
            let(:latest_resolvable_version) { "1.5.0.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0.1") }
          end

          context "without leading == (technically invalid)" do
            let(:setup_py_req_string) { "1.4.0" }
            its([:requirement]) { is_expected.to eq("1.5.0") }
          end
        end

        context "and no requirement was specified" do
          let(:setup_py_req_string) { nil }
          it { is_expected.to eq(setup_py_req) }
        end

        context "and a range requirement was specified" do
          let(:setup_py_req_string) { ">=1.3.0" }
          it { is_expected.to eq(setup_py_req) }

          context "that is too high" do
            let(:setup_py_req_string) { ">=2.0.0" }
            its([:requirement]) { is_expected.to eq(:unfixable) }
          end

          context "with an upper bound" do
            let(:setup_py_req_string) { ">=1.3.0, <=1.5.0" }
            it { is_expected.to eq(setup_py_req) }

            context "that needs updating" do
              let(:setup_py_req_string) { ">=1.3.0, <1.5" }
              its([:requirement]) { is_expected.to eq(">=1.3.0,<1.6") }
            end
          end
        end

        context "and a compatibility requirement was specified" do
          let(:setup_py_req_string) { "~=1.3.0" }
          its([:requirement]) { is_expected.to eq(">=1.3,<1.6") }

          context "that supports the new version" do
            let(:setup_py_req_string) { "~=1.3" }
            it { is_expected.to eq(setup_py_req) }
          end

          context "that needs to be updated and maintain its precision" do
            let(:setup_py_req_string) { "~=1.3" }
            let(:latest_resolvable_version) { "2.1.0" }
            its([:requirement]) { is_expected.to eq(">=1.3,<3.0") }
          end
        end

        context "and a prefix match was specified" do
          context "that is satisfied" do
            let(:setup_py_req_string) { "==1.*.*" }
            it { is_expected.to eq(setup_py_req) }
          end

          context "that needs updating" do
            let(:setup_py_req_string) { "==1.4.*" }
            its([:requirement]) { is_expected.to eq(">=1.4,<1.6") }
          end

          context "along with an exact match" do
            let(:setup_py_req_string) { "==1.4.*, ==1.4.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0") }
          end
        end
      end
    end

    context "for a setup.cfg dependency" do
      subject { updated_requirements.find { |r| r[:file] == "setup.cfg" } }

      context "when there is no resolvable version" do
        let(:latest_resolvable_version) { nil }
        it { is_expected.to eq(setup_cfg_req) }
      end

      context "when there is a resolvable version" do
        let(:latest_resolvable_version) { "1.5.0" }

        context "and a full version was previously pinned" do
          let(:setup_cfg_req_string) { "==1.4.0" }
          its([:requirement]) { is_expected.to eq("==1.5.0") }

          context "that has fewer digits than the new version" do
            let(:setup_cfg_req_string) { "==1.4.0" }
            let(:latest_resolvable_version) { "1.5.0.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0.1") }
          end

          context "without leading == (technically invalid)" do
            let(:setup_cfg_req_string) { "1.4.0" }
            its([:requirement]) { is_expected.to eq("1.5.0") }
          end
        end

        context "and no requirement was specified" do
          let(:setup_cfg_req_string) { nil }
          it { is_expected.to eq(setup_cfg_req) }
        end

        context "and a range requirement was specified" do
          let(:setup_cfg_req_string) { ">=1.3.0" }
          it { is_expected.to eq(setup_cfg_req) }

          context "that is too high" do
            let(:setup_cfg_req_string) { ">=2.0.0" }
            its([:requirement]) { is_expected.to eq(:unfixable) }
          end

          context "with an upper bound" do
            let(:setup_cfg_req_string) { ">=1.3.0, <=1.5.0" }
            it { is_expected.to eq(setup_cfg_req) }

            context "that needs updating" do
              let(:setup_cfg_req_string) { ">=1.3.0, <1.5" }
              its([:requirement]) { is_expected.to eq(">=1.3.0,<1.6") }
            end
          end
        end

        context "and a compatibility requirement was specified" do
          let(:setup_cfg_req_string) { "~=1.3.0" }
          its([:requirement]) { is_expected.to eq(">=1.3,<1.6") }

          context "that supports the new version" do
            let(:setup_cfg_req_string) { "~=1.3" }
            it { is_expected.to eq(setup_cfg_req) }
          end

          context "that needs to be updated and maintain its precision" do
            let(:setup_cfg_req_string) { "~=1.3" }
            let(:latest_resolvable_version) { "2.1.0" }
            its([:requirement]) { is_expected.to eq(">=1.3,<3.0") }
          end
        end

        context "and a prefix match was specified" do
          context "that is satisfied" do
            let(:setup_cfg_req_string) { "==1.*.*" }
            it { is_expected.to eq(setup_cfg_req) }
          end

          context "that needs updating" do
            let(:setup_cfg_req_string) { "==1.4.*" }
            its([:requirement]) { is_expected.to eq(">=1.4,<1.6") }
          end

          context "along with an exact match" do
            let(:setup_cfg_req_string) { "==1.4.*, ==1.4.1" }
            its([:requirement]) { is_expected.to eq("==1.5.0") }
          end
        end
      end
    end

    context "for a pyproject.toml dependency" do
      let(:requirements) { [pyproject_req].compact }
      let(:pyproject_req) do
        {
          file: "pyproject.toml",
          requirement: pyproject_req_string,
          groups: groups,
          source: nil
        }
      end
      let(:groups) { [] }
      subject { updated_requirements.find { |r| r[:file] == "pyproject.toml" } }
      let(:pyproject_req_string) { "*" }

      [
        Dependabot::RequirementsUpdateStrategy::BumpVersions,
        Dependabot::RequirementsUpdateStrategy::BumpVersionsIfNecessary
      ].each do |update_strategy|
        context "when asked to #{update_strategy}" do
          let(:update_strategy) { update_strategy }

          context "when there is no resolvable version" do
            let(:latest_resolvable_version) { nil }
            it { is_expected.to eq(pyproject_req) }
          end

          context "when there is a resolvable version" do
            let(:latest_resolvable_version) { "1.5.0" }

            context "and a full version was previously pinned" do
              let(:pyproject_req_string) { "1.4.0" }
              its([:requirement]) { is_expected.to eq("1.5.0") }

              context "that has fewer digits than the new version" do
                let(:pyproject_req_string) { "1.4" }
                let(:latest_resolvable_version) { "1.5.0" }
                its([:requirement]) { is_expected.to eq("1.5.0") }
              end

              context "that had a local version" do
                let(:pyproject_req_string) { "1.4.0+gc.1" }
                its([:requirement]) { is_expected.to eq("1.5.0") }
              end

              context "and used an equality matcher" do
                let(:pyproject_req_string) { "==1.4.0" }
                its([:requirement]) { is_expected.to eq("==1.5.0") }

                context "with a single equals" do
                  let(:pyproject_req_string) { "=1.4.0" }
                  its([:requirement]) { is_expected.to eq("=1.5.0") }
                end
              end
            end

            context "and an asterisk was specified" do
              let(:pyproject_req_string) { "*" }
              it { is_expected.to eq(pyproject_req) }
            end

            context "and a range requirement was specified" do
              let(:pyproject_req_string) { ">=1.3.0" }
              it { is_expected.to eq(pyproject_req) }

              context "that is too high" do
                let(:pyproject_req_string) { ">=2.0.0" }
                its([:requirement]) { is_expected.to eq(:unfixable) }
              end

              context "that had a local version" do
                let(:pyproject_req_string) { ">=1.3.0+gc.1" }
                it { is_expected.to eq(pyproject_req) }
              end

              context "with an upper bound" do
                let(:pyproject_req_string) { ">=1.3.0, <=1.5.0" }
                it { is_expected.to eq(pyproject_req) }

                context "that needs updating" do
                  let(:pyproject_req_string) { ">=1.3.0, <1.5" }
                  its([:requirement]) { is_expected.to eq(">=1.3.0,<1.6") }
                end
              end
            end

            context "and a ~= requirement was specified" do
              let(:pyproject_req_string) { "~=1.3.0" }
              its([:requirement]) { is_expected.to eq("~=1.5.0") }
            end

            context "and a ~ requirement was specified" do
              let(:pyproject_req_string) { "~1.3.0" }
              its([:requirement]) { is_expected.to eq("~1.5.0") }
            end

            context "and a ^ requirement was specified" do
              let(:pyproject_req_string) { "^1.3.0" }
              its([:requirement]) do
                is_expected.to eq(
                  if update_strategy == Dependabot::RequirementsUpdateStrategy::BumpVersions
                    "^1.5.0"
                  else
                    "^1.3.0"
                  end
                )
              end

              context "without a lockfile" do
                let(:has_lockfile) { false }
                its([:requirement]) { is_expected.to eq("^1.3.0") }

                context "that needs updating" do
                  let(:latest_resolvable_version) { "2.5.0" }
                  its([:requirement]) { is_expected.to eq("^2.5.0") }
                end
              end

              context "with an || specifier" do
                let(:pyproject_req_string) { "^0.8.0 || ^1.3.0" }
                its([:requirement]) { is_expected.to eq("^0.8.0 || ^1.3.0") }
              end
            end

            context "and a wildcard match was specified" do
              context "that is satisfied" do
                let(:pyproject_req_string) { "==1.*.*" }
                it { is_expected.to eq(pyproject_req) }
              end

              context "that needs updating" do
                let(:pyproject_req_string) { "==1.4.*" }
                its([:requirement]) { is_expected.to eq("==1.5.*") }
              end

              context "along with an exact match" do
                let(:pyproject_req_string) { "==1.4.*, ==1.4.1" }
                its([:requirement]) { is_expected.to eq("==1.5.0") }
              end
            end
          end
        end
      end

      context "when asked to widen ranges" do
        let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::WidenRanges }

        context "when there is no resolvable version" do
          let(:latest_resolvable_version) { nil }
          it { is_expected.to eq(pyproject_req) }
        end

        context "when there is a resolvable version" do
          let(:latest_resolvable_version) { "1.5.0" }

          context "and a full version was previously pinned" do
            let(:pyproject_req_string) { "1.4.0" }
            its([:requirement]) { is_expected.to eq("1.5.0") }

            context "that has fewer digits than the new version" do
              let(:pyproject_req_string) { "1.4" }
              let(:latest_resolvable_version) { "1.5.0" }
              its([:requirement]) { is_expected.to eq("1.5.0") }
            end

            context "that had a local version" do
              let(:pyproject_req_string) { "1.4.0+gc.1" }
              its([:requirement]) { is_expected.to eq("1.5.0") }
            end

            context "and used an equality matcher" do
              let(:pyproject_req_string) { "==1.4.0" }
              its([:requirement]) { is_expected.to eq("==1.5.0") }
            end
          end

          context "and an asterisk was specified" do
            let(:pyproject_req_string) { "*" }
            it { is_expected.to eq(pyproject_req) }
          end

          context "and a range requirement was specified" do
            let(:pyproject_req_string) { ">=1.3.0" }
            it { is_expected.to eq(pyproject_req) }

            context "that had a local version" do
              let(:pyproject_req_string) { ">=1.3.0+gc.1" }
              it { is_expected.to eq(pyproject_req) }
            end

            context "that is too high" do
              let(:pyproject_req_string) { ">=2.0.0" }
              its([:requirement]) { is_expected.to eq(:unfixable) }
            end

            context "with an upper bound" do
              let(:pyproject_req_string) { ">=1.3.0, <=1.5.0" }
              it { is_expected.to eq(pyproject_req) }

              context "that needs updating" do
                let(:pyproject_req_string) { ">=1.3.0, <1.5" }
                its([:requirement]) { is_expected.to eq(">=1.3.0,<1.6") }
              end
            end
          end

          context "and a ~= requirement was specified" do
            let(:pyproject_req_string) { "~=1.3.0" }
            its([:requirement]) { is_expected.to eq(">=1.3,<1.6") }
          end

          context "and a ~ requirement was specified" do
            let(:pyproject_req_string) { "~1.3.0" }
            its([:requirement]) { is_expected.to eq(">=1.3,<1.6") }

            context "on the major version" do
              let(:pyproject_req_string) { "~1" }
              its([:requirement]) { is_expected.to eq("~1") }

              context "and needs updating" do
                let(:latest_resolvable_version) { "2.5.0" }
                its([:requirement]) { is_expected.to eq(">=1,<3") }
              end
            end
          end

          context "and a ^ requirement was specified" do
            let(:pyproject_req_string) { "^1.3.0" }
            its([:requirement]) { is_expected.to eq("^1.3.0") }

            context "for a development dependency" do
              let(:groups) { ["dev-dependencies"] }
              its([:requirement]) { is_expected.to eq("^1.5.0") }

              context "without a lockfile" do
                let(:has_lockfile) { false }
                its([:requirement]) { is_expected.to eq("^1.3.0") }
              end
            end

            context "that needs updating" do
              let(:latest_resolvable_version) { "2.5.0" }
              its([:requirement]) { is_expected.to eq(">=1.3,<3.0") }

              context "that is pre-1.0.0" do
                let(:pyproject_req_string) { "^0.3.0" }
                let(:latest_resolvable_version) { "0.5.0" }
                its([:requirement]) { is_expected.to eq(">=0.3,<0.6") }
              end

              context "that is pre-0.1.0" do
                let(:pyproject_req_string) { "^0.0.3" }
                let(:latest_resolvable_version) { "0.0.5" }
                its([:requirement]) { is_expected.to eq(">=0.0.3,<0.0.6") }
              end

              context "for a development dependency" do
                let(:groups) { ["dev-dependencies"] }
                its([:requirement]) { is_expected.to eq("^2.5.0") }
              end
            end
          end

          context "and a wildcard match was specified" do
            context "that is satisfied" do
              let(:pyproject_req_string) { "==1.*.*" }
              it { is_expected.to eq(pyproject_req) }
            end

            context "that needs updating" do
              let(:pyproject_req_string) { "==1.4.*" }
              its([:requirement]) { is_expected.to eq(">=1.4,<1.6") }
            end

            context "along with an exact match" do
              let(:pyproject_req_string) { "==1.4.*, ==1.4.1" }
              its([:requirement]) { is_expected.to eq("==1.5.0") }
            end

            context "as part of an || condition" do
              let(:pyproject_req_string) { "1.3.* || 1.4.*" }
              its([:requirement]) do
                is_expected.to eq("1.3.* || 1.4.* || 1.5.*")
              end
            end
          end
        end
      end

      context "when asked to not change requirements" do
        let(:update_strategy) { Dependabot::RequirementsUpdateStrategy::LockfileOnly }

        it "does not update any requirements" do
          expect(updated_requirements).to eq(requirements)
        end
      end
    end
  end
end
