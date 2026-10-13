# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"
require "language/node"

module Homebrew
  module Bundle
    class Npm < Extension
      class << self
        sig { override.returns(Symbol) }
        def type = :npm

        sig { override.returns(String) }
        def check_label = "npm Package"

        sig { override.returns(String) }
        def banner_name = "npm packages"

        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
          @outdated_packages = T.let(nil, T.nilable(T::Array[String]))
        end

        sig { override.returns(T.nilable(String)) }
        def cleanup_heading
          banner_name
        end

        sig { override.returns(String) }
        def package_manager_name
          "node"
        end

        sig { override.returns(T.nilable(Pathname)) }
        def package_manager_executable
          which("npm", ORIGINAL_PATHS)
        end

        sig { override.params(_name: String, _options: Homebrew::Bundle::EntryOptions).returns(T::Boolean) }
        def batch_installable?(_name, _options = {})
          true
        end

        sig { override.params(entries: T::Array[Dsl::Entry], verbose: T::Boolean).returns(T::Boolean) }
        def install_batch!(entries, verbose: false)
          Bundle.system(package_manager_executable!.to_s, "install", *Language::Node.npm_install_security_args,
                        "-g", *entries.map(&:name), verbose:)
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = if (npm = package_manager_executable) &&
                         (!npm.to_s.start_with?("/") || npm.exist?)
            with_env(package_manager_env(npm)) do
              parse_package_list(Utils.popen_read_text(npm, "list", "-g", "--depth=0", "--json", err: File::NULL))
            end
          end
          return [] if @packages.nil?

          @packages
        end

        sig { returns(T::Array[String]) }
        def outdated_packages
          outdated_packages = @outdated_packages
          return outdated_packages if outdated_packages

          @outdated_packages = if (npm = package_manager_executable) &&
                                  (!npm.to_s.start_with?("/") || npm.exist?)
            with_env(package_manager_env(npm)) do
              parse_outdated_packages(
                Utils.popen_read_text(npm, "outdated", "-g", "--depth=0", "--json", err: File::NULL),
              )
            end
          end
          return [] if @outdated_packages.nil?

          @outdated_packages
        end

        sig { params(name: String).returns(T::Boolean) }
        def package_outdated?(name)
          package_installed?(name) && outdated_packages.include?(name)
        end

        sig { override.params(name: String, _options: Homebrew::Bundle::EntryOptions).returns(String) }
        def install_verb(name = "", _options = {})
          package_outdated?(name) ? "Upgrading" : "Installing"
        end

        sig {
          override.params(
            name:       String,
            with:       T.nilable(T::Array[String]),
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
            _options:   Homebrew::Bundle::EntryOption,
          ).returns(T::Boolean)
        }
        def preinstall!(name, with: nil, no_upgrade: false, verbose: false, **_options)
          ensure_package_manager_installed!(name, verbose:)

          if package_installed?(name, with:) && (no_upgrade || !package_outdated?(name))
            puts "Skipping install of #{name} #{package_description}. It is already installed." if verbose
            return false
          end

          true
        end

        sig {
          override.params(
            name:       String,
            with:       T.nilable(T::Array[String]),
            preinstall: T::Boolean,
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
            force:      T::Boolean,
            _options:   Homebrew::Bundle::EntryOption,
          ).returns(T::Boolean)
        }
        def install!(name, with: nil, preinstall: true, no_upgrade: false, verbose: false, force: false, **_options)
          _ = no_upgrade
          _ = force

          return true unless preinstall

          puts "#{install_verb(name)} #{name} #{package_description}." if verbose
          return false unless install_package!(name, with:, verbose:)

          installed_packages << name unless installed_packages.include?(name)
          packages << name unless packages.include?(name)
          true
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

          npm = package_manager_executable!

          Bundle.system(npm.to_s, "install", *Language::Node.npm_install_security_args, "-g", name, verbose:)
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          installed_packages = @installed_packages
          return installed_packages if installed_packages

          @installed_packages = packages.dup
        end

        sig { override.params(name: String, executable: Pathname).void }
        def uninstall_package!(name, executable: Pathname.new(""))
          Bundle.system(executable.to_s, "uninstall", "-g", name, verbose: false)
        end

        sig { params(output: String).returns(T::Array[String]) }
        def parse_package_list(output)
          return [] if output.blank?

          json = JSON.parse(output)
          deps = json.fetch("dependencies", {})
          deps.keys.reject { |name| name == "npm" }
        rescue JSON::ParserError
          []
        end
        private :parse_package_list

        # `npm outdated` exits non-zero as soon as it finds an outdated package and
        # prints an `error` object when it fails, so only entries reporting a
        # `latest` version count as outdated packages.
        sig { params(output: String).returns(T::Array[String]) }
        def parse_outdated_packages(output)
          return [] if output.blank?

          json = JSON.parse(output)
          return [] unless json.is_a?(Hash)

          json.filter_map do |name, package|
            next if name == "npm"

            name if package.is_a?(Hash) && package["latest"].is_a?(String)
          end.sort
        rescue JSON::ParserError
          []
        end
        private :parse_outdated_packages
      end

      sig { override.params(package: Object, no_upgrade: T::Boolean).returns(T::Boolean) }
      def installed_and_up_to_date?(package, no_upgrade: false)
        name = self.class.dump_name(package)
        return false unless self.class.package_installed?(name, with: self.class.dump_with(package))
        return true if no_upgrade

        !self.class.package_outdated?(name)
      end

      sig { override.params(package: Object, no_upgrade: T::Boolean).returns(String) }
      def failure_reason(package, no_upgrade:)
        _ = no_upgrade
        name = self.class.dump_name(package)
        reason = self.class.package_outdated?(name) ? "needs to be upgraded." : "needs to be installed."

        "#{self.class.check_label} #{name} #{reason}"
      end
    end
  end
end
