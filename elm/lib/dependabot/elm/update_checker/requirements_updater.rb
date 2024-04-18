# typed: true
# frozen_string_literal: true

require "dependabot/elm/version"
require "dependabot/elm/requirement"
require "dependabot/elm/update_checker"

module Dependabot
  module Elm
    class UpdateChecker
      class RequirementsUpdater
        RANGE_REQUIREMENT_REGEX =
          /(\d+\.\d+\.\d+) <= v < (\d+\.\d+\.\d+)/
        SINGLE_VERSION_REGEX = /\A(\d+\.\d+\.\d+)\z/

        def initialize(requirements:, latest_resolvable_version:)
          @requirements = requirements

          return unless latest_resolvable_version
          return unless version_class.correct?(latest_resolvable_version)

          @latest_resolvable_version =
            version_class.new(latest_resolvable_version)
        end

        def updated_requirements
          return requirements unless latest_resolvable_version

          requirements.map do |req|
            updated_req_string = update_requirement(
              req[:requirement],
              latest_resolvable_version
            )

            req.merge(requirement: updated_req_string)
          end
        end

        private

        attr_reader :requirements
        attr_reader :latest_resolvable_version

        def update_requirement(old_req, new_version)
          if requirement_class.new(old_req).satisfied_by?(new_version)
            old_req
          elsif (match = RANGE_REQUIREMENT_REGEX.match(old_req))
            require_range(match[1], new_version)
          elsif SINGLE_VERSION_REGEX.match?(old_req)
            new_version.to_s
          else
            require_exactly(new_version)
          end
        end

        def require_range(minimum, version)
          major, _minor, _patch = version.to_s.split(".").map(&:to_i)
          "#{minimum} <= v < #{major + 1}.0.0"
        end

        def require_exactly(version)
          "#{version} <= v <= #{version}"
        end

        def version_class
          Elm::Version
        end

        def requirement_class
          Elm::Requirement
        end
      end
    end
  end
end
