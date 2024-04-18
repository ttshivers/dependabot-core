# typed: true
# frozen_string_literal: true

require "excon"
require "dependabot/metadata_finders"
require "dependabot/metadata_finders/base"
require "dependabot/registry_client"

module Dependabot
  module Cargo
    class MetadataFinder < Dependabot::MetadataFinders::Base
      SOURCE_KEYS = %w(repository homepage documentation).freeze

      private

      def look_up_source
        case new_source_type
        when "default" then find_source_from_crates_listing
        when "git" then find_source_from_git_url
        else raise "Unexpected source type: #{new_source_type}"
        end
      end

      def new_source_type
        dependency.source_type
      end

      def find_source_from_crates_listing
        potential_source_urls =
          SOURCE_KEYS
          .filter_map { |key| crates_listing.dig("crate", key) }

        source_url = potential_source_urls.find { |url| Source.from_url(url) }
        Source.from_url(source_url)
      end

      def find_source_from_git_url
        info = dependency.requirements.filter_map { |r| r[:source] }.first

        url = info[:url] || info.fetch("url")
        Source.from_url(url)
      end

      def crates_listing
        return @crates_listing unless @crates_listing.nil?

        response = Dependabot::RegistryClient.get(url: "https://crates.io/api/v1/crates/#{dependency.name}")
        @crates_listing = JSON.parse(response.body)
      end
    end
  end
end

Dependabot::MetadataFinders.register("cargo", Dependabot::Cargo::MetadataFinder)
