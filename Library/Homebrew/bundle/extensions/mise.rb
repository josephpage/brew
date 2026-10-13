# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class Mise < Extension
      Tool = T.type_alias { { name: String, installed: T::Boolean } }

      class << self
        sig { override.returns(Symbol) }
        def type = :mise

        sig { override.returns(String) }
        def check_label = "mise Tool"

        sig { override.returns(String) }
        def banner_name = "mise tools"

        sig { override.params(name: String, options: Homebrew::Bundle::EntryInputOptions).returns(Dsl::Entry) }
        def entry(name, options = {})
          raise "unknown options(#{options.keys.inspect}) for mise" if options.present?

          normalized_name = normalize_name(name)
          raise "name(#{name.inspect}) should include a tool name" if normalized_name.blank?

          Dsl::Entry.new(:mise, normalized_name)
        end

        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
        end

        sig { override.returns(T.nilable(String)) }
        def cleanup_heading
          banner_name
        end

        sig { override.returns(T::Array[String]) }
        def packages
          load_packages
          @packages || []
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          load_packages
          @installed_packages || []
        end

        sig {
          override.params(
            name:    String,
            with:    T.nilable(T::Array[String]),
            verbose: T::Boolean,
          ).returns(T::Boolean)
        }
        def install_package!(name, with: nil, verbose: false)
          _ = with

          Bundle.system(package_manager_executable!.to_s, "use", "--global", name, verbose:)
        end

        sig { override.params(name: String, executable: Pathname).void }
        def uninstall_package!(name, executable: Pathname.new(""))
          Bundle.system(executable.to_s, "unuse", "--global", name, verbose: false)
        end

        sig { override.params(name: String, with: T.nilable(T::Array[String])).returns(String) }
        def package_record(name, with: nil)
          _ = with

          normalize_name(name)
        end

        sig { void }
        def load_packages
          return if @packages

          if (mise = package_manager_executable)
            packages = parse_package_list(Utils.popen_read_text(mise, "ls", "--global", "--json", err: File::NULL))
            @packages = packages.map { |package| package[:name] }
            @installed_packages = packages.filter_map { |package| package[:name] if package[:installed] }
          end
        end
        private :load_packages

        sig { params(output: String).returns(T::Array[Tool]) }
        def parse_package_list(output)
          return [] if output.blank?

          json = JSON.parse(output)
          return [] unless json.is_a?(Hash)

          packages = json.flat_map do |tool, records|
            next [] unless records.is_a?(Array)

            records.filter_map do |record|
              next unless record.is_a?(Hash)

              requested_version = record["requested_version"]
              next unless requested_version.is_a?(String)

              { name: normalize_name("#{tool}@#{requested_version}"), installed: record["installed"] == true }
            end
          end
          packages.sort_by { |package| package[:name] }
        rescue JSON::ParserError
          []
        end
        private :parse_package_list

        # `mise use --global` records a tool with no version as `latest`, which
        # `mise ls --global` then reports as a `latest` request. Dropping the
        # suffix keeps `mise "node"` and `mise "node@latest"` the same entry, so a
        # dumped Brewfile compares equal to a hand-written one.
        sig { params(name: String).returns(String) }
        def normalize_name(name)
          name.strip.delete_suffix("@latest")
        end
        private :normalize_name
      end
    end
  end
end
