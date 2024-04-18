# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"

module Dependabot
  module GithubActions
    class MetadataFinder < Dependabot::MetadataFinders::Base
      extend T::Sig

      private

      sig { override.returns(T.nilable(Dependabot::Source)) }
      def look_up_source
        info = dependency.requirements.filter_map { |r| r[:source] }.first

        url =
          if info.nil?
            "https://github.com/#{dependency.name}"
          else
            info[:url] || info.fetch("url")
          end
        Source.from_url(url)
      end
    end
  end
end

Dependabot::MetadataFinders
  .register("github_actions", Dependabot::GithubActions::MetadataFinder)
