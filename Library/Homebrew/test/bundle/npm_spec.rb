# typed: true
# frozen_string_literal: true

require "bundle"
require "bundle/dsl"
require "bundle/extensions/npm"
require "language/node"

RSpec.describe Homebrew::Bundle::Npm do
  describe "dumping" do
    subject(:dumper) { described_class }

    context "when npm is not installed" do
      before do
        described_class.reset!
        allow(described_class).to receive(:package_manager_executable).and_return(nil)
      end

      specify do
        expect(dumper.packages).to be_empty
        expect(dumper.dump).to eql("")
      end
    end

    context "when npm is installed" do
      let(:npm_list_args) { [Pathname("npm"), "list", "-g", "--depth=0", "--json"] }

      before do
        described_class.reset!
        allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("npm"))
      end

      it "returns package list" do
        allow(Utils).to receive(:popen_read_text).with(*npm_list_args, err: File::NULL).and_return(<<~JSON)
          {
            "dependencies": {
              "npm": { "version": "11.11.0" },
              "vercel": { "version": "39.0.0" },
              "typescript": { "version": "5.7.3" }
            }
          }
        JSON

        expect(dumper.packages).to eql(%w[vercel typescript])
      end

      it "adds npm's directory to PATH when listing packages" do
        npm = mktmpdir/"bin/npm"
        npm.dirname.mkpath
        npm.write("")

        allow(described_class).to receive(:package_manager_executable).and_return(npm)
        expect(Utils).to receive(:popen_read_text)
          .with(npm, "list", "-g", "--depth=0", "--json", err: File::NULL) do
          expect(ENV.fetch("PATH", "")).to start_with("#{npm.dirname}:")
          '{"dependencies":{"eslint":{"version":"10.4.0"}}}'
        end

        expect(dumper.packages).to eql(["eslint"])
      end

      it "excludes npm itself from the package list" do
        allow(Utils).to receive(:popen_read_text).with(*npm_list_args, err: File::NULL).and_return(<<~JSON)
          {
            "dependencies": {
              "npm": { "version": "11.11.0" }
            }
          }
        JSON

        expect(dumper.packages).to be_empty
      end

      it "handles invalid JSON" do
        allow(Utils).to receive(:popen_read_text).with(*npm_list_args, err: File::NULL).and_return("not json")

        expect(dumper.packages).to be_empty
      end

      it "handles empty output" do
        allow(Utils).to receive(:popen_read_text).with(*npm_list_args, err: File::NULL).and_return("")

        expect(dumper.packages).to be_empty
      end

      it "dumps package list" do
        allow(dumper).to receive(:packages).and_return(["vercel", "typescript"])
        expect(dumper.dump).to eql("npm \"vercel\"\nnpm \"typescript\"")
      end
    end
  end

  describe "outdated packages" do
    let(:npm_outdated_args) { [Pathname("npm"), "outdated", "-g", "--depth=0", "--json"] }

    before do
      described_class.reset!
      allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("npm"))
    end

    it "returns packages with a newer version" do
      allow(Utils).to receive(:popen_read_text).with(*npm_outdated_args, err: File::NULL).and_return(<<~JSON)
        {
          "vercel": { "current": "39.0.0", "wanted": "40.0.0", "latest": "40.0.0" },
          "npm": { "current": "11.11.0", "wanted": "12.0.0", "latest": "12.0.0" }
        }
      JSON

      expect(described_class.outdated_packages).to eql(["vercel"])
    end

    it "ignores the error npm reports when it fails" do
      allow(Utils).to receive(:popen_read_text).with(*npm_outdated_args, err: File::NULL).and_return(<<~JSON)
        {
          "error": {
            "code": "ENOENT",
            "summary": "ENOENT: no such file or directory, lstat '/home/user/.local/lib'"
          }
        }
      JSON

      expect(described_class.outdated_packages).to be_empty
    end

    it "handles no outdated packages" do
      allow(Utils).to receive(:popen_read_text).with(*npm_outdated_args, err: File::NULL).and_return("{}")

      expect(described_class.outdated_packages).to be_empty
    end

    it "handles invalid JSON" do
      allow(Utils).to receive(:popen_read_text).with(*npm_outdated_args, err: File::NULL).and_return("not json")

      expect(described_class.outdated_packages).to be_empty
    end

    it "handles empty output" do
      allow(Utils).to receive(:popen_read_text).with(*npm_outdated_args, err: File::NULL).and_return("")

      expect(described_class.outdated_packages).to be_empty
    end

    it "returns nothing when npm is not installed" do
      allow(described_class).to receive(:package_manager_executable).and_return(nil)

      expect(described_class.outdated_packages).to be_empty
    end

    it "treats a package that is not installed as not outdated" do
      allow(described_class).to receive_messages(installed_packages: [], outdated_packages: ["vercel"])

      expect(described_class.package_outdated?("vercel")).to be(false)
    end
  end

  describe "checking" do
    subject(:checker) { described_class.new }

    describe "#installed_and_up_to_date?" do
      it "returns false when the package is not installed" do
        allow(described_class).to receive(:installed_packages).and_return([])

        expect(checker.installed_and_up_to_date?("vercel")).to be(false)
      end

      it "returns true when the installed package is up to date" do
        allow(described_class).to receive_messages(installed_packages: ["vercel"], outdated_packages: [])

        expect(checker.installed_and_up_to_date?("vercel")).to be(true)
      end

      it "returns false when the installed package is outdated" do
        allow(described_class).to receive_messages(installed_packages: ["vercel"], outdated_packages: ["vercel"])

        expect(checker.installed_and_up_to_date?("vercel")).to be(false)
      end

      it "returns true when the installed package is outdated and upgrades are disabled" do
        allow(described_class).to receive_messages(installed_packages: ["vercel"], outdated_packages: ["vercel"])

        expect(checker.installed_and_up_to_date?("vercel", no_upgrade: true)).to be(true)
      end
    end

    describe "#failure_reason" do
      it "reports a package that needs to be installed" do
        allow(described_class).to receive(:installed_packages).and_return([])

        expect(checker.failure_reason("vercel", no_upgrade: false)).to eq("npm Package vercel needs to be installed.")
      end

      it "reports a package that needs to be upgraded" do
        allow(described_class).to receive_messages(installed_packages: ["vercel"], outdated_packages: ["vercel"])

        expect(checker.failure_reason("vercel", no_upgrade: false)).to eq("npm Package vercel needs to be upgraded.")
      end
    end

    it "reports an outdated package as needing an upgrade" do
      allow(described_class).to receive_messages(installed_packages: ["vercel"], outdated_packages: ["vercel"])
      entries = [Homebrew::Bundle::Dsl::Entry.new(:npm, "vercel")]

      expect(described_class.check(entries)).to eql(["npm Package vercel needs to be upgraded."])
    end
  end

  describe "cleanup" do
    before do
      described_class.reset!
      allow(described_class).to receive_messages(
        package_manager_executable: Pathname.new("/opt/homebrew/bin/npm"),
        packages:                   %w[vercel typescript prettier],
        installed_packages:         %w[vercel typescript prettier],
      )
    end

    it "returns packages not in Brewfile entries" do
      entries = [Homebrew::Bundle::Dsl::Entry.new(:npm, "vercel")]
      expect(described_class.cleanup_items(entries)).to eql(%w[typescript prettier])
    end

    it "returns empty when all packages are in Brewfile" do
      entries = [
        Homebrew::Bundle::Dsl::Entry.new(:npm, "vercel"),
        Homebrew::Bundle::Dsl::Entry.new(:npm, "typescript"),
        Homebrew::Bundle::Dsl::Entry.new(:npm, "prettier"),
      ]
      expect(described_class.cleanup_items(entries)).to eql([])
    end

    it "returns frozen empty array when npm is not installed" do
      allow(described_class).to receive(:package_manager_installed?).and_return(false)
      entries = [Homebrew::Bundle::Dsl::Entry.new(:npm, "vercel")]
      expect(described_class.cleanup_items(entries)).to eql([])
    end
  end

  describe "installing" do
    context "when npm is not installed" do
      before do
        described_class.reset!
        allow(described_class).to receive(:package_manager_executable).and_return(nil)
      end

      it "tries to install node" do
        expect(Homebrew::Bundle).to \
          receive(:system).with(HOMEBREW_BREW_FILE, "install", "--formula", "node", verbose: false)
                          .and_return(true)
        expect { described_class.preinstall!("vercel") }.to raise_error(RuntimeError)
      end
    end

    context "when npm is installed" do
      before do
        allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("npm"))
      end

      context "when package is installed" do
        before do
          allow(described_class).to receive_messages(
            installed_packages: ["vercel"],
            outdated_packages:  [],
          )
        end

        it "skips" do
          expect(Homebrew::Bundle).not_to receive(:system)
          expect(described_class.preinstall!("vercel")).to be(false)
        end
      end

      context "when package is outdated" do
        before do
          allow(described_class).to receive_messages(
            installed_packages: ["vercel"],
            outdated_packages:  ["vercel"],
          )
        end

        it "reports an upgrade" do
          expect(described_class.install_verb("vercel")).to eql("Upgrading")
        end

        it "does not skip the install" do
          expect(described_class.preinstall!("vercel")).to be(true)
        end

        it "skips the install when upgrades are disabled" do
          expect(Homebrew::Bundle).not_to receive(:system)
          expect(described_class.preinstall!("vercel", no_upgrade: true)).to be(false)
        end

        it "installs the package again, which npm upgrades" do
          expect(Homebrew::Bundle).to receive(:system)
            .with("npm", "install", *Language::Node.npm_install_security_args, "-g", "vercel", verbose: false)
            .and_return(true)

          expect(described_class.install!("vercel")).to be(true)
        end
      end

      context "when package is not installed" do
        before do
          allow(described_class).to receive_messages(
            package_manager_executable: Pathname.new("/opt/homebrew/bin/npm"),
            installed_packages:         [],
          )
        end

        it "installs a package that is not installed even when upgrades are disabled" do
          expect(described_class.preinstall!("vercel", no_upgrade: true)).to be(true)
        end

        it "installs package" do
          expect(Homebrew::Bundle).to receive(:system)
            .with(
              "/opt/homebrew/bin/npm",
              "install",
              "--min-release-age=1",
              "--cache=#{HOMEBREW_CACHE}/npm_cache",
              "--ignore-scripts",
              "-g",
              "vercel",
              verbose: false,
            )
            .and_return(true)
          expect(described_class.preinstall!("vercel")).to be(true)
          expect(described_class.install!("vercel")).to be(true)
        end

        it "installs multiple packages in npm's native batch" do
          entries = [
            Homebrew::Bundle::Dsl::Entry.new(:npm, "vercel"),
            Homebrew::Bundle::Dsl::Entry.new(:npm, "typescript"),
          ]
          expect(described_class.batch_installable?("vercel")).to be(true)
          expect(Homebrew::Bundle).to receive(:system)
            .with(
              "/opt/homebrew/bin/npm",
              "install",
              "--min-release-age=1",
              "--cache=#{HOMEBREW_CACHE}/npm_cache",
              "--ignore-scripts",
              "-g",
              "vercel",
              "typescript",
              verbose: false,
            )
            .and_return(true)

          expect(described_class.install_batch!(entries, verbose: false)).to be(true)
        end
      end
    end
  end
end
