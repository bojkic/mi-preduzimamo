# frozen_string_literal: true

# Standalone Minitest has refute helpers, without ActiveSupport assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "i18n"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/service_question")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/question_facet")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/civic_question")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedures/komsiluk")
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_event_feed"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_metrics"
require_relative "../../app/services/decidim_app/bijeljina/milica/reference_read"
require_relative "../../app/services/decidim_app/bijeljina/city_service_place_context"

# Actual ReadPort authorization and profile fallback, with synthetic scoped
# records only. No Rails, database, Redis, source fetches or private post bodies.
class MilicaNeighborhoodReadTest < Minitest::Test
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Area = Data.define(:id, :kind, :slug, :decidim_organization_id) do
    def translated_name = "Komšiluk #{id}"
  end
  Profile = Data.define(:komsiluk, :is_assigned) do
    def assigned? = is_assigned

    def komsiluk_id = komsiluk.id
  end
  Resolution = Data.define(:status, :areas, :source, :warning)
  FeedResult = Data.define(:status, :events, :error_code)
  Event = Data.define(:id, :title, :summary, :source_key, :source_label_text, :source_url, :fetched_at, :starts_at, :ends_at, :area_slugs, :targeting_level) do
    def extraction_metadata
      { "temporal_precision" => "minute", "coverage" => { "status" => "resolved", "affected_places" => area_slugs.map do |slug|
        { "slug" => slug, "kind" => "komsiluk", "relation" => "whole" }
      end } }
    end

    def source_published_at = nil

    def source_updated_at = nil

    def content_version = "synthetic-reviewed-version"

    def lifecycle = "scheduled"

    def facts_confirmed? = true
  end
  EmptyBoard = Data.define(:profile) do
    def visible = self

    def for_komsiluk(id)
      raise "Wrong board area" unless id == profile.komsiluk_id

      self
    end

    def order(*) = self

    def limit(number)
      raise "Unbounded board read" unless number == 5

      self
    end

    def to_a = []
  end

  def setup
    @prior_locales = I18n.available_locales
    @prior_sources = DecidimApp::Bijeljina::CityServiceSources::SOURCES
    DecidimApp::Bijeljina::CityServiceSources.send(:remove_const, :SOURCES)
    DecidimApp::Bijeljina::CityServiceSources.const_set(:SOURCES, [
      { key: "water_service", label: "Izmišljeni vodovod", source_url: "https://water.community.example.invalid/notices", enabled: true },
      { key: "electricity_outages", label: "Izmišljena elektro služba", source_url: "https://power.community.example.invalid/notices", enabled: true }
    ].freeze)
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    @temporary_constants = []
    [[Decidim, :User], [Decidim::Bih, :CitizenProfile], [Decidim::Bih, :KomsilukPost]].each do |namespace, name|
      next if namespace.const_defined?(name, false)

      namespace.const_set(name, Class.new do
        def self.find_by(*) = raise "Unexpected record lookup"

        def self.where(*) = raise "Unexpected board lookup"
      end)
      @temporary_constants << [namespace, name]
    end
    @organization = Data.define(:id).new(71)
    @actor = Data.define(:id).new(17)
    @profile = Profile.new(Area.new(12, "komsiluk", "komsiluk-12", 71), true)
    @resolution = Resolution.new(:ok, [], :unspecified, nil)
    @profile_calls = []
    @board_calls = []
    @feed_calls = []
    @feed_result = FeedResult.new(:empty, [], nil)
  end

  def teardown
    DecidimApp::Bijeljina::CityServiceSources.send(:remove_const, :SOURCES)
    DecidimApp::Bijeljina::CityServiceSources.const_set(:SOURCES, @prior_sources)
    @temporary_constants.reverse_each { |namespace, name| namespace.send(:remove_const, name) }
    I18n.available_locales = @prior_locales
  end

  def test_generic_question_uses_only_the_verified_tenant_assigned_profile_for_public_lookup
    result = read(entities: { "query" => "Koji je moj komšiluk?" })
    assert_equal "ok", result.status
    assert_equal ["komsiluk-12"], result.coverage.fetch("area_slugs")
    assert_equal "trusted_profile", result.facts.first.fetch("coverage").fetch("resolution_source")
    assert_equal [{ decidim_organization_id: 71, decidim_user_id: 17 }], @profile_calls
    assert_includes result.warnings, "area_selection_grants_no_membership"
    assert_empty @board_calls
  end

  def test_generic_board_question_uses_own_assignment_but_keeps_private_board_scope
    result = read(action: "neighborhood_information", entities: { "query" => "Objave u mom komšiluku" })
    assert_equal "empty", result.status
    assert_equal "member_board", result.coverage.fetch("visibility")
    assert_equal ["komsiluk-12"], result.coverage.fetch("area_slugs")
    assert_equal [{ decidim_organization_id: 71 }], @board_calls
    assert_equal 2, @profile_calls.length # Resolution and authorization each recheck the profile.
  end

  def test_anonymous_or_missing_profile_capability_asks_area_without_looking_up_a_profile
    [nil, 17].each do |actor_id|
      result = read(actor_id:, capabilities: ["public_reads"], entities: { "query" => "moj komšiluk" })
      assert_equal "ambiguous", result.status
      assert_equal ["area_required"], result.warnings
      assert_empty @profile_calls
      assert_empty @board_calls
    end
    denied = read(action: "neighborhood_information", actor_id: nil, capabilities: ["public_reads"])
    assert_equal "not_authorized", denied.status
    assert_empty @profile_calls
  end

  def test_cross_tenant_unassigned_and_wrong_kind_profiles_never_supply_an_area
    [Profile.new(Area.new(13, "komsiluk", "komsiluk-13", 72), true),
     Profile.new(Area.new(13, "mz", "mz-izmisljeni-vrt", 71), true),
     Profile.new(@profile.komsiluk, false), nil].each do |profile|
      @profile = profile
      result = read
      assert_equal "ambiguous", result.status
      assert_empty result.facts
      assert_empty @board_calls
    end
  end

  def test_explicit_area_wins_and_an_unknown_or_unresolved_location_never_falls_back_to_home
    other = Area.new(14, "komsiluk", "komsiluk-14", 71)
    @resolution = Resolution.new(:ok, [other], :explicit_name, nil)
    result = read(entities: { "area_query" => "Drugo naselje" })
    assert_equal ["komsiluk-14"], result.coverage.fetch("area_slugs")
    assert_empty @profile_calls

    denied = read(action: "neighborhood_information", entities: { "area_query" => "Drugo naselje" })
    assert_equal "not_authorized", denied.status
    assert_includes denied.warnings, "requested_area_not_assigned"
    assert_empty @board_calls

    @profile_calls.clear
    @resolution = Resolution.new(:unknown, [], :explicit_slug, "area_not_found")
    assert_equal "empty", read(entities: { "area_slug" => "unknown" }).status
    @resolution = Resolution.new(:ok, [], :unspecified, nil)
    assert_equal "ambiguous", read(entities: { "street" => "Nepoznata ulica" }).status
    assert_empty @profile_calls
  end

  def test_public_activity_needs_area_and_never_queries_citywide_on_anonymous_missing_area
    result = read(action: "ask_information", actor_id: nil, capabilities: ["public_reads"])
    assert_equal "ambiguous", result.status
    assert_equal ["area_required"], result.warnings
    assert_empty @feed_calls
    assert_empty @profile_calls
    assert_empty @board_calls
  end

  def test_public_activity_uses_trusted_area_nil_topic_and_current_upcoming_twelve_hours_without_source_fetch
    result = read(action: "ask_information", entities: { "query" => "Servisne informacije" })
    assert_equal "empty", result.status
    assert_equal ["no_matching_collected_notices"], result.warnings
    assert_empty result.facts
    assert_equal 1, @feed_calls.length
    query = @feed_calls.first
    assert_nil query.fetch(:topic)
    assert_equal ["komsiluk-12"], query.fetch(:area_identifiers)
    assert_equal Time.utc(2026, 9, 9, 12), query.fetch(:starts_at)
    assert_equal Time.utc(2026, 9, 10, 0), query.fetch(:ends_at)
    assert_equal "collected_public_service_notices", result.coverage.fetch("scope")
    assert_empty @board_calls
  end

  def test_public_activity_preserves_explicit_area_and_reviewed_fact_provenance
    @resolution = Resolution.new(:ok, [Area.new(14, "komsiluk", "komsiluk-14", 71)], :explicit_name, nil)
    now = Time.utc(2026, 9, 9, 12)
    source = DecidimApp::Bijeljina::CityServiceSources.fetch("water_service")
    event = Event.new(23, "Synthetic reviewed notice", "Synthetic scope", "water_service", source.fetch(:label),
                      source.fetch(:source_url), now - 60, now, now + 3_600, ["komsiluk-14"], "area")
    @feed_result = FeedResult.new(:ok, [event], nil)
    result = read(action: "ask_information", entities: { "area_query" => "Drugo naselje" })
    assert_equal "ok", result.status
    assert_equal ["komsiluk-14"], @feed_calls.first.fetch(:area_identifiers)
    assert_equal "service_event:23", result.facts.first.fetch("id")
    assert_equal "water_service", result.facts.first.fetch("source_id")
    assert_equal source.fetch(:source_url), result.facts.first.fetch("source_url")
    assert_equal now - 60, Time.iso8601(result.facts.first.fetch("checked_at"))
    assert_equal "synthetic-reviewed-version", result.facts.first.fetch("content_version")
    assert_equal "whole", result.facts.first.dig("coverage", "requested_relation")
    assert_nil result.facts.first["source_published_at"]
    assert_empty @profile_calls
    assert_empty @board_calls
  end

  def test_public_activity_unavailable_is_not_reported_as_empty
    @feed_result = FeedResult.new(:unavailable, [], :query_unavailable)
    result = read(action: "ask_information")
    assert_equal "unavailable", result.status
    assert_equal ["query_unavailable"], result.warnings
    refute_includes result.warnings, "no_matching_collected_notices"
    assert_empty @board_calls
  end

  def test_combined_activity_keeps_public_report_facts_when_notice_coverage_is_empty
    report_fact = { "id" => "public_report:BR-2026-0001", "kind" => "area_public_report", "text" => "Synthetic public report", "source_id" => "public_reports" }
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new(
      "ok", [report_fact], { "status" => "ok", "area_slug" => "komsiluk-12", "area_kind" => "komsiluk" }, ["public_reports_recent_window"]
    )
    with_public_reports(reports) do
      result = read(action: "ask_information", entities: { "query" => "Šta se dešava u mom komšiluku?" })
      assert_equal "ok", result.status
      assert_equal [report_fact], result.facts
      assert_equal "collected_public_neighborhood_activity", result.coverage["scope"]
      assert_equal "empty", result.coverage.dig("notices", "status")
      assert_includes result.warnings, "no_matching_collected_notices"
      assert_includes result.warnings, "public_reports_recent_window"
      assert_empty @board_calls
    end
  end

  def test_explicit_public_reports_uses_area_read_without_service_fetch_or_private_posts
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new(
      "empty", [], { "status" => "empty" }, ["no_matching_public_reports"]
    )
    with_public_reports(reports) do
      result = read(action: "ask_information", entities: { "query" => "Javne prijave problema" })
      assert_equal "empty", result.status
      assert_equal "area_public_reports", result.coverage["scope"]
      assert_empty @feed_calls
      assert_empty @board_calls
    end
  end

  def test_unavailable_public_reports_are_not_claimed_empty_when_notices_are_empty
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new(
      "unavailable", [], { "status" => "unavailable" }, ["public_reports_area_unavailable"]
    )
    with_public_reports(reports) do
      result = read(action: "ask_information", entities: { "query" => "Šta ima u mom komšiluku?" })
      assert_equal "unavailable", result.status
      assert_equal "unavailable", result.coverage.dig("reports", "status")
      assert_includes result.warnings, "public_reports_area_unavailable"
      refute_includes result.warnings, "no_matching_public_reports"
      assert_empty @board_calls
    end
  end

  def test_combined_activity_preserves_unconfirmed_collected_notice_alongside_public_reports
    now = Time.utc(2026, 9, 9, 12)
    source = DecidimApp::Bijeljina::CityServiceSources.fetch("water_service")
    unconfirmed_event = Class.new(Event) { def facts_confirmed? = false }
    event = unconfirmed_event.new(23, "Synthetic collected notice", "Synthetic scope", "water_service", source.fetch(:label),
                                  source.fetch(:source_url), now - 60, now, now + 3_600, ["komsiluk-12"], "area")
    @feed_result = FeedResult.new(:ok, [event], nil)
    report_fact = { "id" => "public_report:BR-2026-0001", "kind" => "area_public_report", "text" => "Synthetic public report", "source_id" => "public_reports" }
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new("ok", [report_fact], { "status" => "ok" }, ["public_reports_recent_window"])
    with_public_reports(reports) do
      result = read(action: "ask_information", entities: { "query" => "Šta ima u mom komšiluku?" })
      assert_equal "ok", result.status
      assert_equal(%w(service_event:23 public_report:BR-2026-0001), result.facts.map { |fact| fact["id"] })
      assert_includes result.warnings, "source_facts_unconfirmed"
      assert_equal source.fetch(:source_url), result.facts.first["source_url"]
      assert_equal "ok", result.coverage.dig("notices", "status")
      assert_empty @board_calls
    end
  end

  def test_unlocated_notice_details_are_acknowledged_in_summary_but_remain_available_in_service_read
    now = Time.utc(2026, 9, 9, 12)
    source = DecidimApp::Bijeljina::CityServiceSources.fetch("electricity_outages")
    unlocated_event = Class.new(Event) do
      def facts_confirmed? = false

      def extraction_metadata = { "coverage" => { "status" => "unknown", "affected_places" => [] } }
    end
    @feed_result = FeedResult.new(:ok, [unlocated_event.new(64, "Synthetic feeder notice", "1 NN izlaz", "electricity_outages", source.fetch(:label),
                                                            source.fetch(:source_url), now - 60, now, now + 3_600, [], "unknown")], nil)
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new("empty", [], { "status" => "empty" }, ["no_matching_public_reports"])
    with_public_reports(reports) do
      summary = read(action: "ask_information", entities: { "query" => "Šta ima u mom komšiluku?" })
      assert_equal "empty", summary.status
      assert_empty summary.facts
      assert_equal "unmatched_area", summary.coverage.dig("notices", "status")
      assert_equal 1, summary.coverage.dig("notices", "unlocated_notice_count_in_sample")
      assert_includes summary.warnings, "neighborhood_unlocated_notices"
      refute_includes summary.warnings, "no_matching_collected_notices"

      service = read(action: "ask_information", entities: { "query" => "Servisne informacije" })
      assert_equal "ok", service.status
      assert_equal "service_event:64", service.facts.first["id"]
      assert_includes service.warnings, "source_facts_unconfirmed"
      assert_includes service.warnings, "geographic_scope_unconfirmed"
      assert_empty @board_calls
    end
  end

  def test_combined_summary_round_robins_activity_families_without_exceeding_eight_facts
    now = Time.utc(2026, 9, 9, 12)
    source = DecidimApp::Bijeljina::CityServiceSources.fetch("water_service")
    @feed_result = FeedResult.new(:ok, (1..8).map do |id|
      Event.new(id, "Synthetic notice", "Scope", "water_service", source.fetch(:label), source.fetch(:source_url),
                now - 60, now, now + 3_600, ["komsiluk-12"], "area")
    end, nil)
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new("ok", (1..3).map do |id|
      { "id" => "public_report:#{id}", "kind" => "area_public_report", "text" => "Public report", "source_id" => "public_reports" }
    end, { "status" => "ok" }, [])
    activity_facts = %w(volunteer meeting community_project).flat_map do |kind|
      (1..3).map do |id|
        { "id" => "#{kind}:#{id}", "kind" => "neighborhood_activity", "text" => "Public activity", "source_id" => "platform:#{kind}",
          "coverage" => { "activity_type" => kind } }
      end
    end
    @activity_result = DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead::Result.new("ok", activity_facts, { "status" => "ok" }, [])
    with_public_reports(reports) do
      summary = read(action: "ask_information", entities: { "query" => "Šta ima u mom komšiluku?" })
      assert_equal 8, summary.facts.length
      assert_equal(%w(service_event:1 public_report:1 volunteer:1 meeting:1 community_project:1), summary.facts.first(5).map { |fact| fact["id"] })
      assert_equal "ok", summary.coverage.dig("activities", "status")
      assert_includes summary.warnings, "neighborhood_activity_list_bounded"
      assert_equal summary.facts.map { |fact| fact["source_id"] }.uniq.sort, summary.source.map { |source| source["id"] }.sort
      assert_empty @board_calls
    end
  end

  def test_empty_direct_activity_retains_coverage_warnings_and_unavailable_activity_preserves_public_reports
    @resolution = Resolution.new(:ok, [Area.new(12, "komsiluk", "komsiluk-12", 71)], :explicit_name, nil)
    @activity_result = DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead::Result.new(
      "empty", [], { "status" => "empty", "complete_inventory" => false }, %w(no_matching_public_activity neighborhood_activity_scope_limited)
    )
    direct = read(action: "ask_information", topic: "participation", entities: { "area_query" => "Komšiluk 12", "query" => "Javni sastanci" })
    assert_equal "empty", direct.status
    assert_equal false, direct.coverage.dig("activities", "complete_inventory")
    assert_includes direct.warnings, "no_matching_public_activity"
    assert_includes direct.warnings, "neighborhood_activity_scope_limited"

    @activity_result = DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead::Result.new(
      "unavailable", [], { "status" => "unavailable" }, ["neighborhood_activity_unavailable"]
    )
    report = { "id" => "public_report:1", "kind" => "area_public_report", "text" => "Public report", "source_id" => "public_reports" }
    with_public_reports(DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new("ok", [report], { "status" => "ok" }, [])) do
      summary = read(action: "ask_information", entities: { "query" => "Šta ima u mom komšiluku?" })
      assert_equal "ok", summary.status
      assert_includes summary.facts, report
      assert_includes summary.warnings, "neighborhood_activity_unavailable"
    end
  end

  def test_direct_scoped_activity_questions_select_only_requested_family
    @resolution = Resolution.new(:ok, [Area.new(12, "komsiluk", "komsiluk-12", 71)], :explicit_name, nil)
    @activity_calls = []
    { "participation" => ["Javni sastanci", "meetings"],
      "community" => ["Javni projekti", "projects"] }.each do |topic, (query, family)|
      result = read(action: "ask_information", topic:, entities: { "area_query" => "Komšiluk 12", "query" => query })
      assert_equal "public_neighborhood_activities", result.coverage["scope"]
      assert_equal [family], @activity_calls.last[:family_keys]
      assert_equal true, @activity_calls.last[:explicit_time]
      assert_empty @feed_calls
    end
    assert_empty @board_calls
  end

  def test_scoped_volunteer_questions_preserve_existing_category_and_recurring_calendar_reader
    @activity_calls = []
    catalog_calls = []
    catalog = Object.new
    catalog.define_singleton_method(:call) do |**args|
      catalog_calls << args
      { status: "empty", warnings: [] }
    end
    queries = [{ "area_query" => "Komšiluk 12", "query" => "Volontiranje" },
               { "area_query" => "Komšiluk 12", "query" => "Redovno volontiranje subotom u mom komšiluku",
                 "category" => "environment", "time_expression" => "ovog vikenda", "date" => "2026-09-12" }]
    with_reader_constructor(DecidimApp::Bijeljina::Milica::PlatformCatalogRead, catalog) do
      queries.each do |entities|
        assert_equal "empty", read(action: "ask_information", topic: "volunteer", entities:).status
        assert_equal "volunteer", catalog_calls.last[:topic]
        assert_equal entities, catalog_calls.last[:entities]
      end
    end
    assert_equal 2, catalog_calls.length
    assert_empty @activity_calls
    assert_empty @board_calls
  end

  def test_nested_reader_stub_restores_inherited_constructor_after_parent_stub
    klass = DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead
    original_owner = klass.method(:new).owner
    parent_mock = Object.new
    child_mock = Object.new
    with_reader_constructor(DecidimApp::Bijeljina::Milica::PlatformCatalogRead, parent_mock) do
      with_activity_reader(child_mock) { assert_same child_mock, klass.new }
      assert_same parent_mock, klass.new
    end
    assert_equal original_owner, klass.method(:new).owner
    assert_instance_of klass, klass.new(organization: @organization, area_matcher: Object.new)
  end

  def test_constructor_stub_preserves_fresh_inheritance_even_when_nested_block_raises
    parent = Class.new
    child = Class.new(parent)
    parent_mock = Object.new
    child_mock = Object.new
    assert_equal Class, child.method(:new).owner
    assert_raises(RuntimeError) do
      with_reader_constructor(parent, parent_mock) do
        with_reader_constructor(child, child_mock) do
          assert_same child_mock, child.new
          raise "Synthetic nested stub failure"
        end
      end
    end
    refute_includes parent.singleton_class.instance_methods(false), :new
    refute_includes child.singleton_class.instance_methods(false), :new
    assert_equal Class, child.method(:new).owner
    assert_instance_of child, child.new
  end

  def test_constructor_stub_preserves_an_original_owned_constructor
    parent = Class.new
    original = Object.new
    parent.define_singleton_method(:new) { |**| original }
    child = Class.new(parent)
    with_reader_constructor(parent, Object.new) do
      with_reader_constructor(child, Object.new) { refute_same original, child.new }
    end
    assert_includes parent.singleton_class.instance_methods(false), :new
    refute_includes child.singleton_class.instance_methods(false), :new
    assert_same original, child.new
    assert_equal parent.singleton_class, child.method(:new).owner
  end

  def test_supplied_activity_place_is_matched_and_returned_for_precise_retained_clarification
    @resolution = Resolution.new(:ambiguous, [Area.new(95, "mz", "mz-izmisljeni vrt", 71), Area.new(12, "komsiluk", "komsiluk-12", 71)], :explicit_name, "area_name_ambiguous")
    answer = read(action: "ask_information", entities: { "query" => "Ima li uskoro javnih okupljanja u Izmišljeni vrtma?", "time_expression" => "uskoro" })
    assert_equal "ambiguous", answer.status
    assert_equal "izmisljeni vrtma", @matcher_calls.last[:area_query]
    assert_equal "izmisljeni vrtma", answer.coverage["supplied_area_query"]
    assert_equal "citizen_activity_locative", answer.coverage["area_query_source"]
    assert_equal %w(komsiluk mz), answer.candidates.map { |candidate| candidate["area_kind"] }.sort
    assert_includes answer.warnings, "area_name_ambiguous"
    assert_empty @profile_calls
    assert_empty @feed_calls
    assert_empty @board_calls
  end

  def test_literal_komsiluk_qualifier_reaches_catalog_without_changing_category_date_or_permissions
    catalog_calls = []
    catalog = Object.new
    catalog.define_singleton_method(:call) do |**args|
      catalog_calls << args
      { status: "empty", warnings: [] }
    end
    entities = { "query" => "Koje volonterske akcije ima u komšiluku Izmišljeni vrt ovog vikenda?", "area_query" => "Izmišljeni vrt",
                 "category" => "environment", "time_expression" => "ovog vikenda", "date" => "2026-09-12" }
    with_reader_constructor(DecidimApp::Bijeljina::Milica::PlatformCatalogRead, catalog) do
      answer = read(action: "ask_information", topic: "volunteer", entities:, actor_id: nil, capabilities: ["public_reads"])
      assert_equal "empty", answer.status
      assert_equal "komsiluk izmisljeni vrt", answer.coverage["supplied_area_query"]
      assert_equal entities.merge("area_query" => "komsiluk izmisljeni vrt"), catalog_calls.last[:entities]
      assert_equal ["public_reads"], catalog_calls.last[:context].capabilities
      assert_nil catalog_calls.last[:context].actor_id
    end
    assert_empty @profile_calls
    assert_empty @board_calls
    assert_empty @feed_calls
  end

  def test_qualified_activity_place_reaches_scoped_read_with_explicit_next_seven_days
    @resolution = Resolution.new(:ok, [Area.new(12, "komsiluk", "komsiluk-12", 71)], :explicit_name, nil)
    reports = DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity::Result.new("empty", [], { "status" => "empty" }, [])
    with_public_reports(reports) do
      answer = read(action: "ask_information", entities: { "query" => "Ima li uskoro okupljanja u komšiluku Izmišljeni vrt?", "time_expression" => "uskoro" })
      assert_equal "empty", answer.status
      assert_equal "komsiluk izmisljeni vrt", @matcher_calls.last[:area_query]
      assert_equal "collected_public_neighborhood_activity", answer.coverage["scope"]
      assert_equal Time.utc(2026, 9, 9, 12), @activity_calls.last[:starts_at]
      assert_equal Time.utc(2026, 9, 16, 12), @activity_calls.last[:ends_at]
      assert_equal true, @activity_calls.last[:explicit_time]
      assert_empty @profile_calls
    end
  end

  def test_unscoped_or_other_catalog_intents_do_not_enter_scoped_activity_adapter
    @activity_calls = []
    catalog_calls = []
    catalog = Object.new
    catalog.define_singleton_method(:call) do |**args|
      catalog_calls << args
      { status: "empty", warnings: [] }
    end
    cases = [["volunteer", { "query" => "Volontiranje" }],
             ["community", { "area_query" => "Ledinci", "query" => "Organizacije i potrebe" }],
             ["participation", { "area_query" => "Ledinci", "query" => "Prijedlozi i glasanje" }]]
    with_reader_constructor(DecidimApp::Bijeljina::Milica::PlatformCatalogRead, catalog) do
      cases.each { |topic, entities| assert_equal "empty", read(action: "ask_information", topic:, entities:).status }
    end
    assert_equal 3, catalog_calls.length
    assert_empty @activity_calls
    assert_empty @board_calls
  end

  private

  def with_public_reports(result)
    reader = Object.new
    reader.define_singleton_method(:call) do |**arguments|
      raise "Wrong public report area" unless arguments.fetch(:areas).map(&:slug) == ["komsiluk-12"]

      result
    end
    with_reader_constructor(DecidimApp::Bijeljina::Milica::PublicNeighborhoodActivity, reader) { yield }
  end

  # Minitest restores an inherited constructor as an own singleton method.
  # When the parent is also stubbed, that would permanently retain its mock.
  def with_activity_reader(reader)
    with_reader_constructor(DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead, reader) { yield }
  end

  def with_reader_constructor(klass, reader)
    owned_constructor = klass.singleton_class.instance_methods(false).include?(:new)
    klass.stub(:new, ->(**) { reader }) { yield }
  ensure
    klass.singleton_class.remove_method(:new) if !owned_constructor && klass.singleton_class.instance_methods(false).include?(:new)
  end

  def read(action: "choose_area", topic: "neighborhood", entities: {}, actor_id: 17, capabilities: %w(public_reads neighborhood_reads))
    entities = { "query" => "Servisne informacije" }.merge(entities) if action == "ask_information"
    context = Contracts::TrustedContext.new(organization_id: 71, actor_id:, conversation_key: "c" * 64,
                                            capabilities:, now: Time.utc(2026, 9, 9, 12))
    matcher = Object.new
    resolution = @resolution
    matcher_calls = @matcher_calls ||= []
    matcher.define_singleton_method(:resolve) do |**args|
      matcher_calls << args
      resolution
    end
    unused = Object.new
    feed = Object.new
    feed_calls = @feed_calls
    feed_result = @feed_result
    feed.define_singleton_method(:query) do |**args|
      feed_calls << args
      feed_result
    end
    port = DecidimApp::Bijeljina::Milica::ReadPort.new(organization: @organization, area_matcher: matcher,
                                                       event_feed: feed, source_checker: unused, timetable: unused,
                                                       directory: unused, duplicate_finder: unused, waste_schedule: unused)
    port.define_singleton_method(:log_failure) { |error, _| raise error }
    activity_reader = Object.new
    activity_result = @activity_result || DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead::Result.new("empty", [], { "status" => "empty" }, [])
    activity_calls = @activity_calls ||= []
    activity_reader.define_singleton_method(:call) do |**args|
      activity_calls << args
      activity_result
    end
    activity_reader.define_singleton_method(:requested_window) { |**args| [args.fetch(:context).now, args.fetch(:context).now + 7.days] }
    actor_lookup = lambda do |**scope|
      raise "Unscoped actor lookup" unless scope == { id: 17, organization: @organization }

      @actor
    end
    profile_lookup = lambda do |**scope|
      @profile_calls << scope
      raise "Unscoped profile lookup" unless scope == { decidim_organization_id: 71, decidim_user_id: 17 }

      @profile
    end
    board_lookup = lambda do |**scope|
      @board_calls << scope
      raise "Unscoped board lookup" unless scope == { decidim_organization_id: 71 }

      EmptyBoard.new(@profile)
    end
    Decidim::User.stub(:find_by, actor_lookup) do
      Decidim::Bih::CitizenProfile.stub(:find_by, profile_lookup) do
        Decidim::Bih::KomsilukPost.stub(:where, board_lookup) do
          with_activity_reader(activity_reader) do
            port.call(action:, topic:, entities:, context:)
          end
        end
      end
    end
  end
end

# rubocop:enable Rails/RefuteMethods
