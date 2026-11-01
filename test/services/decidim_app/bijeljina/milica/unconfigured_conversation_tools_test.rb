# frozen_string_literal: true
require "test_helper"
require_relative "../../../../support/synthetic_civic_facts"

class UnconfiguredConversationToolsTest < ActiveSupport::TestCase
  Host = DecidimApp::Bijeljina
  Dialogue = Decidim::Bih::Concierge::Dialogue

  setup do
    @organization = create_organization
    @now = Time.utc(2040, 4, 9, 12)
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id,
      conversation_key: "a" * 64, actor_id: nil, account_state: "anonymous", capabilities: ["public_reads"], now: @now, deadline: Dialogue::TurnBudget.new)
  end

  def with_civic_configuration(directory, hosts = [])
    owner = Host::CivicDomainFacts
    constants = { CONFIG_DIR: owner::CONFIG_DIR, REVIEWED_HOSTS: owner::REVIEWED_HOSTS }
    cached = owner.instance_variable_defined?(:@cache)
    prior = owner.instance_variable_get(:@cache)
    { CONFIG_DIR: directory, REVIEWED_HOSTS: hosts }.each do |name, value|
      owner.send(:remove_const, name)
      owner.const_set(name, value)
    end
    owner.reset!
    yield
  ensure
    constants.each do |name, value|
      owner.send(:remove_const, name)
      owner.const_set(name, value)
    end
    owner.remove_instance_variable(:@cache) if owner.instance_variable_defined?(:@cache)
    owner.instance_variable_set(:@cache, prior) if cached
  end

  def bundle
    Host::Milica::ConversationTools.new(organization: @organization, clock: -> { @now })
  end

  def test_absent_optional_catalogs_keep_platform_tools_usable_and_civic_facts_unavailable
    with_civic_configuration("") do
      tools = bundle
      declarations = tools.registry.declarations.index_by { |row| row.fetch("name") }
      assert_equal 29, declarations.size
      assert_includes declarations.keys, "published_boarding_points"
      assert_not declarations.fetch("read_procedure").dig("parameters", "properties", "key").has_key?("enum")
      assert_not declarations.fetch("read_civic_guidance").dig("parameters", "properties", "biller").has_key?("enum")
      result = tools.registry.call(name: "read_platform_guidance", arguments: { "subject" => "account" }, context: @context, eligibility: tools.eligibility)
      assert_equal "ok", result.status
      assert result.for_prompt(context: @context, eligibility: tools.eligibility)
      result = tools.registry.call(name: "read_civic_guidance", arguments: { "domain" => "billing", "biller" => "example-provider" }, context: @context, eligibility: tools.eligibility)
      assert_equal "unavailable", result.status
      assert_empty result.evidence
      assert_includes result.warnings, "reviewed_civic_facts_unavailable"
      assert result.for_prompt(context: @context, eligibility: tools.eligibility)
      assert_raises(Dialogue::Contracts::Invalid) do
        tools.registry.call(name: "read_civic_guidance", arguments: { "domain" => "billing", "organization_id" => 999 }, context: @context, eligibility: tools.eligibility)
      end
    end
  end

  def test_every_unconfigured_source_topic_stays_unavailable_without_reading_prepared_sources
    checker = Object.new
    checker.define_singleton_method(:check) { |**| raise "unconfigured source must not be read" }
    reader = Host::Milica::SourceRead.new(source_checker: checker)
    Host::CityServiceSources::TOPIC_SOURCE_KEYS.each do |topic, keys|
      next if keys.empty?

      result = reader.call(topic: topic, context: @context, locale: "sr", entities: {})
      assert_equal "unavailable", result.fetch(:status), topic
      assert_includes result.fetch(:warnings), "source_not_configured", topic
      assert_empty Array(result[:facts]), topic
    end
  end

  def test_explicitly_disabled_source_is_not_read
    sources = Host::CityServiceSources
    previous = sources::SOURCES
    checker = Object.new
    checker.define_singleton_method(:check) { |**| raise "disabled source must not be read" }
    keys = sources::TOPIC_SOURCE_KEYS.fetch("weather")
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, keys.map { |key| { key:, enabled: false, source_url: "https://community.example.invalid/weather" } }.freeze)
    result = Host::Milica::SourceRead.new(source_checker: checker).call(topic: "weather", context: @context, locale: "sr", entities: {})
    assert_equal "unavailable", result.fetch(:status)
    assert_includes result.fetch(:warnings), "source_not_configured"
    assert_empty Array(result[:facts])
  ensure
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, previous)
  end

  def test_absent_gazette_review_date_cannot_produce_a_current_reference
    result = Host::Milica::ReferenceRead.new(organization: @organization).call(topic: "gazette", entities: {}, context: @context, locale: "sr")
    assert_equal "unavailable", result.fetch(:status)
    assert_empty result.fetch(:facts)
    assert_includes result.fetch(:warnings), "gazette_index_not_reviewed"
  end

  def test_enabled_source_reads_only_explicitly_active_keys
    sources = Host::CityServiceSources
    previous = sources::SOURCES
    keys = sources::TOPIC_SOURCE_KEYS.fetch("air_quality")
    requests = []
    checker = Object.new
    checker.define_singleton_method(:check) { |**arguments| requests << arguments; [] }
    active = { key: keys.first, enabled: true, provider: "Izmišljeni izvor", source_url: "https://community.example.invalid/air" }
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [active].freeze)
    result = Host::Milica::SourceRead.new(source_checker: checker).call(topic: "air_quality", context: @context, locale: "sr", entities: {})
    assert_equal 1, requests.size
    assert_equal [keys.first], requests.first.fetch(:keys)
    assert_not_includes result.fetch(:warnings), "source_not_configured"
    assert_empty Array(result[:facts]), "An enabled source without a prepared observation cannot invent facts"
  ensure
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, previous)
  end

  def test_weather_without_an_organization_does_not_read_prepared_sources
    sources = Host::CityServiceSources
    previous = sources::SOURCES
    checker = Object.new
    checker.define_singleton_method(:check) { |**| raise "unbound weather must not be read" }
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, [{ key: "weather_warnings", enabled: true,
      provider: "Izmišljeni izvor", source_url: "https://community.example.invalid/weather" }].freeze)
    result = Host::Milica::SourceRead.new(source_checker: checker).call(topic: "weather", context: @context, locale: "sr", entities: {})
    assert_equal "unavailable", result.fetch(:status)
    assert_includes result.fetch(:warnings), "weather_organization_required"
    assert_empty Array(result[:facts])
  ensure
    sources.send(:remove_const, :SOURCES)
    sources.const_set(:SOURCES, previous)
  end

  def test_reviewed_empty_gazette_retains_its_date_and_becomes_stale_after_the_existing_limit
    index = Object.new
    index.define_singleton_method(:recent) { |**| [] }
    index.define_singleton_method(:search) { |*args, **| [] }
    checked = @now.to_date
    gazette = Object.new
    gazette.define_singleton_method(:index) { index }
    gazette.define_singleton_method(:source_url) { "https://community.example.invalid/gazette" }
    gazette.define_singleton_method(:index_checked_on) { checked }
    reader = Host::Milica::ReferenceRead.new(organization: @organization, gazette:)
    result = reader.call(topic: "gazette", entities: {}, context: @context, locale: "sr")
    assert_equal "empty", result.fetch(:status)
    assert_equal checked.iso8601, result.fetch(:validity).fetch("index_captured_on")
    assert_empty result.fetch(:facts)
    checked -= 46
    result = reader.call(topic: "gazette", entities: {}, context: @context, locale: "sr")
    assert_equal "stale", result.fetch(:status)
    assert_includes result.fetch(:warnings), "gazette_index_stale"
    assert_empty result.fetch(:facts)
  end

  def test_explicit_authored_catalog_retains_closed_biller_choices_and_real_reader
    Dir.mktmpdir("synthetic-tools-civic-") do |directory|
      SyntheticCivicFacts.write_reader_contract(root: directory, day: @now.to_date)
      with_civic_configuration(directory, ["civic.example.invalid"]) do
        tools = bundle
        schema = tools.registry.declarations.find { |row| row.fetch("name") == "read_civic_guidance" }.dig("parameters", "properties", "biller")
        assert_equal %w(waste water electricity heating city_levies), schema.fetch("enum")
        result = tools.registry.call(name: "read_civic_guidance", arguments: { "domain" => "billing", "biller" => "water" }, context: @context, eligibility: tools.eligibility)
        assert_equal "ok", result.status
        assert result.evidence.any?
        assert result.for_prompt(context: @context, eligibility: tools.eligibility)
        assert_raises(Dialogue::Contracts::Invalid) do
          tools.registry.call(name: "read_civic_guidance", arguments: { "domain" => "billing", "biller" => "invented-provider" }, context: @context, eligibility: tools.eligibility)
        end
      end
    end
  end

  def test_explicit_missing_catalog_is_not_silently_treated_as_unconfigured
    Dir.mktmpdir("synthetic-tools-missing-") do |directory|
      with_civic_configuration(directory) { assert_raises(Errno::ENOENT) { bundle } }
    end
  end
end
