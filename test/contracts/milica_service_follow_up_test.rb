# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- pure Minitest, not Rails assertions

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require_relative "../support/isolated_i18n_backend"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/service_follow_up_question")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/service_directory")
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# Real reviewed static directory and URL validation, synthetic typed context.
# No Rails, records, network, model, contacts or tariff-number extraction.
class MilicaServiceFollowUpTest < Minitest::Test
  Dialogue = Decidim::Bih::Concierge::Dialogue
  # Authored shape only; no municipal directory, contacts or payment codes.
  module Directory
    ENTRIES = %i(parking vodovod_servis).to_h do |key|
      url = "https://community.example.invalid/#{key}"
      [key, { key:, title: "Izmišljena služba #{key}", answer: "SMS TEST-PARKING 2,35 KM — izmišljeni primjer.",
              source_url: url, source_checked_on: "2026-06-29", record_kind: "service_guidance",
              verification_scope: "source_guidance", facts: [{ id: "synthetic-#{key}", kind: "authored_test",
                source_checked_on: "2026-06-29", source_url: url }] }]
    end.freeze
    def self.find(key) = ENTRIES[key.to_sym]
  end
  ReadPort = DecidimApp::Bijeljina::Milica::ReadPort
  NOW = Time.utc(2026, 9, 10, 9)

  class CurrentDirectory
    attr_accessor :entry_override
    attr_reader :reads

    def initialize
      @reads = []
    end

    def find(key)
      reads << key
      entry_override || Directory.find(key)
    end
  end

  def setup
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    I18n.backend = MiTestSupport::IsolatedI18nBackend.new
    I18n.available_locales = Dialogue::Contracts::LOCALES
    I18n.available_locales.each do |locale|
      # Root owns shipping locale copy; these markers test the typed seam only.
      I18n.backend.store_translations(locale, decidim: { bih: { dialogue: {
                                        service_contact_unavailable: "NO_REVIEWED_SERVICE_CONTACT: %{title}. USE_OFFICIAL_PAGE.",
                                        service_official_page: "REVIEWED_OFFICIAL_PAGE: %{title}."
                                      } } })
    end
    @prior_sources = DecidimApp::Bijeljina::CityServiceSources::SOURCES
    DecidimApp::Bijeljina::CityServiceSources.send(:remove_const, :SOURCES)
    DecidimApp::Bijeljina::CityServiceSources.const_set(:SOURCES, [
      { key: "synthetic_directory", source_url: "https://community.example.invalid/directory", enabled: false }
    ].freeze)
    @directory = CurrentDirectory.new
    @port = ReadPort.allocate
    @port.instance_variable_set(:@organization, Data.define(:id).new(71))
    @port.instance_variable_set(:@directory, @directory)
  end

  def teardown
    DecidimApp::Bijeljina::CityServiceSources.send(:remove_const, :SOURCES)
    DecidimApp::Bijeljina::CityServiceSources.const_set(:SOURCES, @prior_sources)
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
  end

  def test_parking_payment_source_followup_never_becomes_a_service_phone_number
    entry = Directory.find(:parking)
    assert_includes entry.fetch(:answer), "SMS TEST-PARKING"
    evidence = Dialogue::PriorEvidence.capture(
      result: Dialogue::Contracts::ReadResult.new(status: "ok"),
      facts: [{ "id" => "service:parking", "source_id" => "city_services:parking", "source_label" => entry.fetch(:title),
                "source_url" => "https://obsolete.example.test/", "text" => entry.fetch(:answer) }],
      action: "ask_information", topic: "parking", now: NOW, expires_at: NOW.to_f + 600
    )
    state = { "active_task" => "ask_information", "topic" => "parking", "draft" => nil,
              "prior_evidence" => evidence, "expires_at" => NOW.to_f + 600 }
    id = Dialogue::ServiceFollowUpQuestion.retained_source_id(state:, context: context)
    focus = Dialogue::ServiceFollowUpQuestion.focus("A koji je broj telefona službe?")
    answer = read(source_id: id, focus:)

    assert_equal "ok", answer.status
    assert_equal ["parking"], @directory.reads
    assert_equal false, answer.coverage.fetch("contact_available")
    assert_equal "contact", answer.coverage.fetch("focus")
    assert_includes answer.facts.first.fetch("text"), "NO_REVIEWED_SERVICE_CONTACT"
    assert_includes answer.facts.first.fetch("text"), "USE_OFFICIAL_PAGE"
    refute_match(/TEST-PARKING|SMS|KM/, answer.facts.first.fetch("text"))
    assert_equal entry.fetch(:source_url), answer.source.fetch("url")
    assert_includes answer.warnings, "reviewed_service_contact_unavailable"
    assert_includes answer.warnings, "snapshot_not_live_status"
    assert_nil answer.checked_at
    assert_equal false, answer.validity.fetch("live_status")
    refute_includes answer.to_h.to_s, "obsolete.example.test"
    refute evidence.fetch("facts").first.has_key?("text")
    refute evidence.fetch("facts").first.has_key?("source_url")
  end

  def test_utility_website_followup_rereads_exact_current_source_and_keeps_review_dates
    entry = Directory.find(:vodovod_servis)
    first = read(source_id: "city_services:vodovod_servis", focus: "website")
    assert_equal entry.fetch(:source_url), first.source.fetch("url")
    assert_equal "2026-06-29", first.facts.first.fetch("observed_at")
    changed_url = "https://community.example.invalid/synthetic-reviewed-source/"
    @directory.entry_override = entry.merge(source_url: changed_url, source_checked_on: "2026-09-10")
    latest = read(source_id: "city_services:vodovod_servis", focus: "website")

    assert_equal %w(vodovod_servis vodovod_servis), @directory.reads
    assert_equal changed_url, latest.source.fetch("url")
    assert_equal "2026-09-10", latest.facts.first.fetch("observed_at")
    assert_equal "city_services:vodovod_servis", latest.source.fetch("id")
    assert_equal "service:vodovod_servis", latest.facts.first.fetch("id")
    assert_equal "website", latest.coverage.fetch("focus")
    assert_includes latest.facts.first.fetch("text"), "REVIEWED_OFFICIAL_PAGE"
    assert_equal entry.fetch(:facts).map { |item| item.slice(:id, :kind, :source_checked_on, :source_url).transform_keys(&:to_s) }, latest.facts.first.fetch("provenance")
    assert_equal ["snapshot_not_live_status"], latest.warnings
  end

  def test_public_tenant_deadline_and_closed_identifier_guards_precede_directory_reads
    assert_equal "not_authorized", read(trusted: context(capabilities: [])).status
    assert_raises(Dialogue::Contracts::Invalid) { read(trusted: context(organization_id: 72)) }
    expired = context(deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1)
    assert_equal ["deadline_exceeded"], read(trusted: expired).warnings
    [nil, "https://community.example.invalid/", "city_services:../../private", "city_services:kontakt_grada", "city_services:missing", "procedure:maticar"].each do |id|
      assert_empty read(source_id: id).facts
    end
    assert_empty read(focus: "payment").facts
    assert_empty @directory.reads
  end

  def test_wrong_identity_unreviewed_future_and_unapproved_source_entries_are_not_used
    entry = Directory.find(:parking)
    [entry.merge(key: :vodovod_servis), entry.merge(record_kind: "personal_contact"), entry.merge(verification_scope: "unreviewed"),
     entry.merge(source_checked_on: nil), entry.merge(source_checked_on: "2026-02-30"), entry.merge(source_checked_on: "2027-01-01"),
     entry.merge(source_url: "https://attacker.invalid/"), entry.merge(source_url: "https://user:secret@community.example.invalid/")].each do |changed|
      @directory.entry_override = changed
      result = read
      assert_equal "unavailable", result.status
      assert_empty result.facts
      assert_nil result.source
    end
  end

  private

  def context(organization_id: 71, capabilities: ["public_reads"], deadline: nil)
    Dialogue::Contracts::TrustedContext.new(organization_id:, conversation_key: "c" * 64, capabilities:, deadline:, now: NOW)
  end

  def read(source_id: "city_services:parking", focus: "contact", trusted: context)
    @port.service_follow_up(source_id:, focus:, context: trusted, locale: "sr")
  end
end

# rubocop:enable Rails/RefuteMethods
