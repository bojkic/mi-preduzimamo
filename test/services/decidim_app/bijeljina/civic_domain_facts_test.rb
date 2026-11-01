# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../support/synthetic_civic_facts"

module DecidimApp
  module Bijeljina
    # The reviewed heating/billing/recycling catalogue is data a citizen is
    # quoted from, so its invariants are asserted rather than trusted: every
    # published fact is dated twice, cites a reviewed host, and an
    # unpublishable row never escapes.
    class CivicDomainFactsTest < ActiveSupport::TestCase
      setup do
        @fixture_root = Dir.mktmpdir("synthetic-civic-facts-")
        SyntheticCivicFacts.write(root: @fixture_root, day: Date.new(2040, 4, 9))
        @prior_directory = CivicDomainFacts::CONFIG_DIR
        @prior_hosts = CivicDomainFacts::REVIEWED_HOSTS
        @prior_cache = CivicDomainFacts.instance_variable_get(:@cache)
        CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
        CivicDomainFacts.const_set(:CONFIG_DIR, @fixture_root)
        CivicDomainFacts.send(:remove_const, :REVIEWED_HOSTS)
        CivicDomainFacts.const_set(:REVIEWED_HOSTS, ["civic.example.invalid"].freeze)
        CivicDomainFacts.reset!
      end

      teardown do
        CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
        CivicDomainFacts.const_set(:CONFIG_DIR, @prior_directory)
        CivicDomainFacts.send(:remove_const, :REVIEWED_HOSTS)
        CivicDomainFacts.const_set(:REVIEWED_HOSTS, @prior_hosts)
        CivicDomainFacts.instance_variable_set(:@cache, @prior_cache)
        FileUtils.remove_entry(@fixture_root) if @fixture_root && File.directory?(@fixture_root)
      end

      test "every domain loads, is dated and names its revision" do
        CivicDomainFacts::DOMAINS.each do |domain|
          assert_equal Date.new(2040, 4, 9), CivicDomainFacts.reviewed_on(domain), domain
          assert_match(/\A\d{4}-\d{2}-\d{2}\.\d+\z/, CivicDomainFacts.revision(domain), domain)
        end
      end

      test "unknown domain raises instead of returning an empty answer" do
        assert_raises(CivicDomainFacts::MissingDomain) { CivicDomainFacts.domain("parking") }
      end

      test "every published fact carries both its source date and its review date" do
        all_facts.each do |domain, fact|
          assert_kind_of Date, fact.source_on, "#{domain}/#{fact.id}"
          assert_kind_of Date, fact.reviewed_on, "#{domain}/#{fact.id}"
          assert fact.source_on <= fact.reviewed_on, "#{domain}/#{fact.id} claims a source newer than its review"
        end
      end

      test "every published fact cites a reviewed https host" do
        all_facts.each do |domain, fact|
          uri = URI.parse(fact.source_url)
          assert_equal "https", uri.scheme, "#{domain}/#{fact.id}"
          assert_includes CivicDomainFacts::REVIEWED_HOSTS, uri.host, "#{domain}/#{fact.id}"
        end
      end

      test "an unpublishable fact is retained as evidence and never returned" do
        assert_includes CivicDomainFacts.retained_fact_ids("heating"), "synthetic_private_contact"
        assert_not_includes CivicDomainFacts.facts("heating", scope: :all).map(&:id), "synthetic_private_contact"
        assert_nil CivicDomainFacts.fact("heating", "synthetic_private_contact")
        # An invented private contact sentinel must never reach an answer.
        assert_not_includes all_facts.map { |_domain, fact| fact.text }.join(" "), "SYNTHETIC_PRIVATE_CONTACT"
      end

      test "a scoped fact is withheld until its scope is asked for" do
        assert_not_includes CivicDomainFacts.facts("recycling").map(&:id), "synthetic_recycling_self_haul"
        assert_includes CivicDomainFacts.facts("recycling", scope: :self_haul).map(&:id), "synthetic_recycling_self_haul"
      end

      test "the blocked amounts are blockers, not missing rows" do
        billing = CivicDomainFacts.blockers("billing").map(&:id)
        assert_includes billing, "synthetic_tariff_unreviewed"
        assert_includes billing, "synthetic_fee_unreviewed"
        recycling = CivicDomainFacts.blockers("recycling").map(&:id)
        assert_includes recycling, "synthetic_locations_unknown"
        assert_includes recycling, "synthetic_glass_unknown"
        assert_includes CivicDomainFacts.blockers("heating").map(&:id), "synthetic_coverage_unknown"
        CivicDomainFacts::DOMAINS.each do |domain|
          CivicDomainFacts.blockers(domain).each do |blocker|
            assert blocker.text.present?, "#{domain}/#{blocker.id} has no citizen-facing text"
            assert blocker.unblock.present?, "#{domain}/#{blocker.id} does not say what would unblock it"
          end
        end
      end

      test "no reviewed fact quotes a blocked amount" do
        text = all_facts.map { |_domain, fact| fact.text }.join(" ")
        # Invented unpublishable amounts must not appear in public facts.
        assert_not_includes text, "9,99"
        ["8,888", "7,777", "6,666", "5,555", "4,444"].each { |rate| assert_not_includes text, rate }
      end

      test "the authenticated provider paths are recorded as exclusions" do
        assert CivicDomainFacts.excluded_authenticated_path?("https://civic.example.invalid/private-account")
        assert CivicDomainFacts.excluded_authenticated_path?("https://civic.example.invalid/private-email")
        assert_not CivicDomainFacts.excluded_authenticated_path?("https://civic.example.invalid/public")
        # Nothing we publish may be one of them.
        all_facts.each do |domain, fact|
          assert_not CivicDomainFacts.excluded_authenticated_path?(fact.source_url), "#{domain}/#{fact.id}"
        end
      end

      test "billing is five separately routable billers" do
        assert_equal %w(waste water electricity heating city_levies), CivicDomainFacts.billers.map { |biller| biller.fetch("id") } # rubocop:disable Lint/AmbiguousBlockAssociation
        CivicDomainFacts.billers.each do |biller|
          assert biller.fetch("provider").present?
          assert biller.fetch("complaint_route").present?, "#{biller.fetch("id")} has no complaint route"
          assert Array(biller["tokens"]).any?, "#{biller.fetch("id")} cannot be routed to"
        end
      end

      test "recycling records the published list verbatim and leaves glass unstated" do
        recycling = CivicDomainFacts.domain("recycling")
        assert_equal ["izmišljeni materijal A", "izmišljeni materijal B", "izmišljena amblaža"], recycling.fetch("recyclables_collected_verbatim")
        assert_equal false, recycling.fetch("glass_listed")
        text = CivicDomainFacts.facts("recycling").map(&:text).join(" ")
        assert_no_match(/staklo se (?:odvozi|prikuplja|sakuplja)/i, text)
        assert_no_match(/staklo se ne (?:odvozi|prikuplja|sakuplja)/i, text)
      end

      test "an absent community configuration fails instead of inventing empty service facts" do
        CivicDomainFacts.send(:remove_const, :CONFIG_DIR)
        CivicDomainFacts.const_set(:CONFIG_DIR, "")
        CivicDomainFacts.reset!
        assert_raises(CivicDomainFacts::MissingDomain) { CivicDomainFacts.facts("heating") }
      end

      test "unreviewed insecure or credential-bearing source citations are rejected" do
        path = File.join(@fixture_root, "heating_reviewed_facts.yml")
        data = YAML.safe_load_file(path)
        ["https://other.example.invalid/source", "http://civic.example.invalid/source",
         "https://synthetic-user@civic.example.invalid/source", "https://civic.example.invalid:444/source"].each do |url|
          data.fetch("facts").first["source_url"] = url
          File.write(path, YAML.dump(data))
          CivicDomainFacts.reset!
          assert_raises(CivicDomainFacts::MissingDomain) { CivicDomainFacts.facts("heating") }
        end
      end

      private

      def all_facts
        CivicDomainFacts::DOMAINS.flat_map do |domain|
          rows = CivicDomainFacts.facts(domain, scope: :all)
          rows += CivicDomainFacts.billers.flat_map { |biller| CivicDomainFacts.biller_facts(biller.fetch("id")) } if domain == "billing"
          rows.map { |fact| [domain, fact] }
        end
      end
    end
  end
end
