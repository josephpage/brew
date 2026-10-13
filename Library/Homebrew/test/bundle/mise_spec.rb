# typed: true
# frozen_string_literal: true

require "bundle"
require "bundle/dsl"
require "bundle/extensions/mise"

RSpec.describe Homebrew::Bundle::Mise do
  let(:mise_list_args) { [Pathname("mise"), "ls", "--global", "--json"] }

  describe "entries" do
    it "accepts a tool with a version" do
      entry = described_class.entry("node@20")
      expect(entry.name).to eql("node@20")
    end

    it "accepts a tool without a version" do
      entry = described_class.entry("node")
      expect(entry.name).to eql("node")
    end

    it "drops a request for latest" do
      entry = described_class.entry("node@latest")
      expect(entry.name).to eql("node")
    end

    it "rejects unknown options" do
      expect { described_class.entry("node@20", source: "https://example.com") }
        .to raise_error(RuntimeError, /unknown options\(\[:source\]\) for mise/)
    end

    it "rejects a request with no tool name" do
      expect { described_class.entry("@latest") }
        .to raise_error(RuntimeError, /should include a tool name/)
    end
  end

  describe "checking" do
    subject(:checker) { described_class.new }

    describe "#installed_and_up_to_date?" do
      it "returns false when the tool is not installed" do
        allow(described_class).to receive(:installed_packages).and_return([])

        expect(checker.installed_and_up_to_date?("node@20")).to be(false)
      end

      it "returns true when the requested version is installed" do
        allow(described_class).to receive(:installed_packages).and_return(["node@20"])

        expect(checker.installed_and_up_to_date?("node@20")).to be(true)
      end

      it "treats a request for latest as the tool without a version" do
        allow(described_class).to receive(:installed_packages).and_return(["node"])

        expect(checker.installed_and_up_to_date?("node@latest")).to be(true)
      end

      it "does not treat another installed version as installed" do
        allow(described_class).to receive(:installed_packages).and_return(["node@22"])

        expect(checker.installed_and_up_to_date?("node@20")).to be(false)
      end
    end

    describe "#failure_reason" do
      it "returns a tool-specific message" do
        expect(checker.failure_reason("node@20", no_upgrade: false))
          .to eq("mise Tool node@20 needs to be installed.")
      end
    end

    describe "#find_actionable" do
      let(:entries) do
        [
          Homebrew::Bundle::Dsl::Entry.new(:mise, "node@20"),
          Homebrew::Bundle::Dsl::Entry.new(:mise, "jq"),
          Homebrew::Bundle::Dsl::Entry.new(:brew, "wget"),
        ]
      end

      it "returns missing mise tools" do
        allow(described_class).to receive(:installed_packages).and_return(["jq"])

        actionable = checker.find_actionable(entries, exit_on_first_error: false, no_upgrade: false, verbose: false)
        expect(actionable).to eq(["mise Tool node@20 needs to be installed."])
      end
    end
  end

  describe "dumping" do
    subject(:dumper) { described_class }

    before do
      described_class.reset!
    end

    context "when mise is not installed" do
      before do
        allow(described_class).to receive(:package_manager_executable).and_return(nil)
      end

      it "returns no packages" do
        expect(dumper.packages).to be_empty
      end
    end

    context "when mise is installed" do
      before do
        allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("mise"))
      end

      context "with a global config" do
        before do
          allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return(<<~OUTPUT)
            {
              "jq": [
                {
                  "version": "1.8.2",
                  "requested_version": "latest",
                  "installed": true
                }
              ],
              "node": [
                {
                  "version": "20.11.1",
                  "requested_version": "20",
                  "installed": true
                }
              ],
              "bun": [
                {
                  "version": "1.1.30",
                  "requested_version": "1.1",
                  "installed": false
                }
              ]
            }
          OUTPUT
        end

        it "dumps every requested tool, sorted by name" do
          dump = dumper.dump
          expect(dump).to eql("mise \"bun@1.1\"\nmise \"jq\"\nmise \"node@20\"")
        end

        it "treats only installed tools as installed" do
          installed = dumper.installed_packages
          expect(installed).to eql(["jq", "node@20"])
        end
      end

      it "returns no packages when the global config has no tools" do
        allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return("{}")

        expect(dumper.packages).to be_empty
      end

      it "returns no packages when mise output is not JSON" do
        allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return("node 20.11.1")

        expect(dumper.packages).to be_empty
      end

      it "ignores a record with no requested version" do
        allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return(<<~OUTPUT)
          {
            "node": [
              {
                "version": "20.11.1",
                "installed": true
              }
            ]
          }
        OUTPUT

        expect(dumper.packages).to be_empty
      end
    end
  end

  describe "installing" do
    context "when mise is not installed" do
      before do
        described_class.reset!
        allow(described_class).to receive(:package_manager_executable).and_return(nil)
      end

      it "tries to install mise" do
        expect(Homebrew::Bundle).to \
          receive(:system).with(HOMEBREW_BREW_FILE, "install", "--formula", "mise", verbose: false)
                          .and_return(true)
        expect { described_class.preinstall!("node@20") }.to raise_error(RuntimeError)
      end
    end

    context "when mise is installed" do
      before do
        described_class.reset!
        allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("mise"))
        allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return("{}")
      end

      it "skips a tool that is already installed" do
        allow(described_class).to receive(:installed_packages).and_return(["node@20"])

        expect(Homebrew::Bundle).not_to receive(:system)
        expect(described_class.preinstall!("node@20")).to be(false)
      end

      it "installs a tool globally" do
        expect(Homebrew::Bundle).to receive(:system).with("mise", "use", "--global", "node@20", verbose: false)
                                                    .and_return(true)

        expect(described_class.preinstall!("node@20")).to be(true)
        expect(described_class.install!("node@20")).to be(true)
      end

      it "updates dump output after install in the same process" do
        expect(Homebrew::Bundle).to receive(:system).with("mise", "use", "--global", "node@20", verbose: false)
                                                    .and_return(true)

        described_class.install!("node@20")

        expect(described_class.dump).to eql("mise \"node@20\"")
      end
    end
  end

  describe "cleanup" do
    before do
      described_class.reset!
      allow(described_class).to receive(:package_manager_executable).and_return(Pathname.new("mise"))
      allow(Utils).to receive(:popen_read_text).with(*mise_list_args, err: File::NULL).and_return(<<~OUTPUT)
        {
          "jq": [
            {
              "version": "1.8.2",
              "requested_version": "latest",
              "installed": true
            }
          ],
          "node": [
            {
              "version": "20.11.1",
              "requested_version": "20",
              "installed": true
            }
          ]
        }
      OUTPUT
    end

    it "returns tools that the Brewfile does not request" do
      entries = [Homebrew::Bundle::Dsl::Entry.new(:mise, "node@20")]

      expect(described_class.cleanup_items(entries)).to eql(["jq"])
    end

    it "keeps a tool that the Brewfile requests for latest" do
      entries = [described_class.entry("jq@latest")]

      expect(described_class.cleanup_items(entries)).to eql(["node@20"])
    end

    it "returns no tools when mise is not installed" do
      allow(described_class).to receive(:package_manager_installed?).and_return(false)
      entries = [Homebrew::Bundle::Dsl::Entry.new(:mise, "node@20")]

      expect(described_class.cleanup_items(entries)).to eql([])
    end

    it "removes a tool from the global config" do
      expect(Homebrew::Bundle).to receive(:system)
        .with("/tmp/mise/bin/mise", "unuse", "--global", "jq", verbose: false)

      described_class.uninstall_package!("jq", executable: Pathname.new("/tmp/mise/bin/mise"))
    end
  end
end
