# typed: true
# frozen_string_literal: true

require "dependabot/dependency_file"
require "dependabot/file_parsers/base"
require "dependabot/bundler/file_updater/gemspec_sanitizer"

module Dependabot
  module Bundler
    class FileParser < Dependabot::FileParsers::Base
      class FilePreparer
        def initialize(dependency_files:)
          @dependency_files = dependency_files
        end

        def prepared_dependency_files
          files = []

          gemspecs.compact.each do |file|
            files << DependencyFile.new(
              name: file.name,
              content: sanitize_gemspec_content(file.content),
              directory: file.directory,
              support_file: file.support_file?
            )
          end

          files += [
            gemfile,
            *evaled_gemfiles,
            lockfile,
            ruby_version_file,
            *imported_ruby_files,
            *specification_files
          ].compact
        end

        private

        attr_reader :dependency_files

        def gemfile
          dependency_files.find { |f| f.name == "Gemfile" } ||
            dependency_files.find { |f| f.name == "gems.rb" }
        end

        def evaled_gemfiles
          dependency_files
            .reject { |f| f.name.end_with?(".gemspec") }
            .reject { |f| f.name.end_with?(".specification") }
            .reject { |f| f.name.end_with?(".lock") }
            .reject { |f| f.name.end_with?(".ruby-version") }
            .reject { |f| f.name == "Gemfile" }
            .reject { |f| f.name == "gems.rb" }
            .reject { |f| f.name == "gems.locked" }
        end

        def specification_files
          dependency_files.select { |f| f.name.end_with?(".specification") }
        end

        def lockfile
          dependency_files.find { |f| f.name == "Gemfile.lock" } ||
            dependency_files.find { |f| f.name == "gems.locked" }
        end

        def gemspecs
          dependency_files.select { |f| f.name.end_with?(".gemspec") }
        end

        def ruby_version_file
          dependency_files.find { |f| f.name == ".ruby-version" }
        end

        def imported_ruby_files
          dependency_files
            .select { |f| f.name.end_with?(".rb") }
            .reject { |f| f.name == "gems.rb" }
        end

        def sanitize_gemspec_content(gemspec_content)
          # No need to set the version correctly - this is just an update
          # check so we're not going to persist any changes to the lockfile.
          FileUpdater::GemspecSanitizer
            .new(replacement_version: "0.0.1")
            .rewrite(gemspec_content)
        end
      end
    end
  end
end
