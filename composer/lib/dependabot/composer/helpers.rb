# typed: true
# frozen_string_literal: true

require "dependabot/composer/version"

module Dependabot
  module Composer
    module Helpers
      # From composers json-schema: https://getcomposer.org/schema.json
      COMPOSER_V2_NAME_REGEX = %r{^[a-z0-9]([_.-]?[a-z0-9]+)*/[a-z0-9](([_.]?|-{0,2})[a-z0-9]+)*$}
      # From https://github.com/composer/composer/blob/b7d770659b4e3ef21423bd67ade935572913a4c1/src/Composer/Repository/PlatformRepository.php#L33
      PLATFORM_PACKAGE_REGEX = /
        ^(?:php(?:-64bit|-ipv6|-zts|-debug)?|hhvm|(?:ext|lib)-[a-z0-9](?:[_.-]?[a-z0-9]+)*
        |composer-(?:plugin|runtime)-api)$
      /x

      FAILED_GIT_CLONE_WITH_MIRROR = /^Failed to execute git clone --(mirror|checkout)[^']*'(?<url>[^']*?)'/
      FAILED_GIT_CLONE = /^Failed to clone (?<url>.*?)/

      def self.composer_version(composer_json, parsed_lockfile = nil)
        if parsed_lockfile && parsed_lockfile["plugin-api-version"]
          version = Composer::Version.new(parsed_lockfile["plugin-api-version"])
          return version.canonical_segments.first == 1 ? "1" : "2"
        else
          return "1" if composer_json["name"] && composer_json["name"] !~ COMPOSER_V2_NAME_REGEX
          return "1" if invalid_v2_requirement?(composer_json)
        end

        "2"
      end

      def self.dependency_url_from_git_clone_error(message)
        if message.match?(FAILED_GIT_CLONE_WITH_MIRROR)
          dependency_url = message.match(FAILED_GIT_CLONE_WITH_MIRROR).named_captures.fetch("url")
          raise "Could not parse dependency_url from git clone error: #{message}" if dependency_url.empty?

          clean_dependency_url(dependency_url)
        elsif message.match?(FAILED_GIT_CLONE)
          dependency_url = message.match(FAILED_GIT_CLONE).named_captures.fetch("url")
          raise "Could not parse dependency_url from git clone error: #{message}" if dependency_url.empty?

          clean_dependency_url(dependency_url)
        end
      end

      def self.invalid_v2_requirement?(composer_json)
        return false unless composer_json.key?("require")

        composer_json["require"].keys.any? do |key|
          key !~ PLATFORM_PACKAGE_REGEX && key !~ COMPOSER_V2_NAME_REGEX
        end
      end
      private_class_method :invalid_v2_requirement?

      def self.clean_dependency_url(dependency_url)
        return dependency_url unless URI::DEFAULT_PARSER.regexp[:ABS_URI].match?(dependency_url)

        url = URI.parse(dependency_url)
        url.user = nil
        url.password = nil
        url.to_s
      end
      private_class_method :clean_dependency_url
    end
  end
end
