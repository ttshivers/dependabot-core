# typed: true
# frozen_string_literal: true

require "nokogiri"

require "dependabot/dependency_file"
require "dependabot/maven/file_parser"
require "dependabot/registry_client"

# For documentation, see:
# - http://maven.apache.org/guides/introduction/introduction-to-the-pom.html
# - http://maven.apache.org/pom.html#Properties
module Dependabot
  module Maven
    class FileParser
      class PropertyValueFinder
        require_relative "repositories_finder"
        require_relative "pom_fetcher"

        DOT_SEPARATOR_REGEX = %r{\.(?!\d+([.\/_\-]|$)+)}

        def initialize(dependency_files:, credentials: [])
          @dependency_files = dependency_files
          @credentials = credentials
          @pom_fetcher = PomFetcher.new(dependency_files: dependency_files)
        end

        def property_details(property_name:, callsite_pom:)
          pom = callsite_pom
          doc = Nokogiri::XML(pom.content)
          doc.remove_namespaces!

          # Loop through the paths that would satisfy this property name,
          # looking for one that exists in this POM
          nm = sanitize_property_name(property_name)
          node =
            loop do
              candidate_node =
                doc.xpath("/project/#{nm}").last ||
                doc.xpath("/project/properties/#{property_name}").last ||
                doc.xpath("/project/profiles/profile/properties/#{property_name}").last

              break candidate_node if candidate_node
              break unless nm.match?(DOT_SEPARATOR_REGEX)

              nm = nm.sub(DOT_SEPARATOR_REGEX, "/")
            rescue Nokogiri::XML::XPath::SyntaxError => e
              raise DependencyFileNotEvaluatable, e.message
            end

          # and value is an expression
          if node && node.content.strip.start_with?("${")
            return extract_value_from_expression(
              expression: node.content.strip,
              property_name: property_name,
              callsite_pom: callsite_pom
            )
          end

          # If we found a property, return it
          return { file: pom.name, node: node, value: node.content.strip } if node

          # Otherwise, look for a value in this pom's parent
          return unless (parent = parent_pom(pom))

          property_details(
            property_name: property_name,
            callsite_pom: parent
          )
        end

        private

        attr_reader :dependency_files

        def extract_value_from_expression(expression:, property_name:, callsite_pom:)
          # and the expression is pointing to self then raise the error
          if expression.eql?("${#{property_name}}")
            raise Dependabot::DependencyFileNotParseable.new(
              callsite_pom.name,
              "Error trying to resolve recursive expression '#{expression}'."
            )
          end

          # and the expression is pointing to another tag, then get the value of that tag
          property_details(property_name: expression.slice(2..-2), callsite_pom: callsite_pom)
        end

        def sanitize_property_name(property_name)
          property_name.sub(/^pom\./, "").sub(/^project\./, "")
        end

        # rubocop:disable Metrics/PerceivedComplexity
        def parent_pom(pom)
          doc = Nokogiri::XML(pom.content)
          doc.remove_namespaces!
          group_id = doc.at_xpath("/project/parent/groupId")&.content&.strip
          artifact_id =
            doc.at_xpath("/project/parent/artifactId")&.content&.strip
          version = doc.at_xpath("/project/parent/version")&.content&.strip

          return unless group_id && artifact_id

          name = [group_id, artifact_id].join(":")

          return @pom_fetcher.internal_dependency_poms[name] if @pom_fetcher.internal_dependency_poms[name]

          return unless version && !version.include?(",")

          @pom_fetcher.fetch_remote_parent_pom(group_id, artifact_id, version, parent_repository_urls(pom))
        end
        # rubocop:enable Metrics/PerceivedComplexity

        def parent_repository_urls(pom)
          repositories_finder.repository_urls(
            pom: pom,
            exclude_inherited: true,
            exclude_snapshots: false
          )
        end

        def repositories_finder
          @repositories_finder ||=
            RepositoriesFinder.new(
              pom_fetcher: @pom_fetcher,
              dependency_files: dependency_files,
              credentials: @credentials,
              evaluate_properties: false
            )
        end
      end
    end
  end
end
