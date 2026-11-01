# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "i18n"

engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine, "app/services/decidim/bih/text")
require File.join(engine, "lib/decidim/bih/transliterator")
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/neighborhood_activity_read"

# Pure query-shape/typed projection contracts. The owning model visibility
# scopes are reused, not reimplemented by a fake database. No Rails/DB boot.
class MilicaNeighborhoodActivityReadTest < Minitest::Test
  Reader = DecidimApp::Bijeljina::Milica::NeighborhoodActivityRead
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Area = Data.define(:id, :slug, :kind, :decidim_organization_id, :boundary) do
    def translated_name = "Area #{slug}"
  end
  PublicRow = Struct.new(:id, :title, :komsiluk_id, :starts_at, :ends_at, :opportunity_kind, :updated_at, :start_time, :end_time,
                         :component, :project, :starts_on, :ends_on, keyword_init: true) do
    def description = raise "Private description must not be read"
  end
  class Scope
    attr_reader :calls, :records

    def initialize(records = [])
      @records = records
      @calls = []
    end

    [:publicly_visible, :approved, :published, :active, :visible_for, :not_hidden, :not_withdrawn, :where, :select, :order, :includes, :joins, :merge, :or].each do |method|
      define_method(method) do |*args|
        raise "Predicate after query limit" if @limit && [:where, :merge, :or].include?(method)

        calls << [method, args]
        self
      end
    end

    def limit(number)
      @limit = number
      calls << [:limit, [number]]
      self
    end

    def to_a = records.first(@limit)
  end

  def setup
    # The city-wide label is real copy, so this fixture reads the host locale
    # file it ships in and puts the process back exactly as it found it.
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = Contracts::LOCALES
    I18n.backend.load_translations(File.expand_path("../../config/locales/milica_activity.yml", __dir__))
    @created_constants = []
    @public_path_overridden = false
    @created_modules = []
    @organization = Data.define(:id, :host).new(71, "mi.example.test")
    @now = Time.utc(2026, 9, 9, 12)
    @area = Area.new(12, "komsiluk-12", "komsiluk", 71,
                     { "type" => "Polygon", "coordinates" => [[[19, 44], [20, 44], [20, 45], [19, 45], [19, 44]]] })
    @scopes = {}
    model(Decidim::Bih, :VolunteerOpportunity, "decidim_bih_volunteer_opportunities")
    model(Decidim::Bih, :PartnerProfile, "decidim_bih_partner_profiles")
    model(Decidim::Bih, :PartnerProjectSubmission, "decidim_bih_partner_project_submissions")
    model(Decidim::Bih, :ProjectDonationLink, "decidim_bih_project_donation_links")
    model(Decidim, :ParticipatoryProcess, "decidim_participatory_processes")
    model(Decidim, :Assembly, "decidim_assemblies")
    model(Decidim, :Component, "decidim_components")
    model(namespace(Decidim, :Meetings), :Meeting, "decidim_meetings_meetings")
    @budget = nil
    owner = self
    install(Decidim::Bih, :Setting, Class.new do
      define_singleton_method(:namespace_for) do |organization, name|
        raise "Wrong tenant" unless organization.id == 71 && name == "community_projects"

        { "budget_id" => 9 }
      end
    end)
    install(namespace(Decidim, :Budgets), :Budget, Class.new do
      define_singleton_method(:find_by) { |**| owner.instance_variable_get(:@budget) }
    end)
    install(Decidim, :EngineRouter, Class.new do
      define_singleton_method(:main_proxy) do |_|
        Object.new.tap { |router| router.define_singleton_method(:meeting_path) { |row| "/processes/public/f/4/meetings/#{row.id}" } }
      end
    end)
    @old_public_path = Decidim::Bih.method(:public_path) if Decidim::Bih.respond_to?(:public_path)
    Decidim::Bih.define_singleton_method(:public_path) { |suffix| "/biceriseno/#{suffix}" }
    @public_path_overridden = true
  end

  def teardown
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
    if @public_path_overridden
      Decidim::Bih.singleton_class.send(:remove_method, :public_path)
      Decidim::Bih.define_singleton_method(:public_path, @old_public_path) if @old_public_path
    end
    @created_constants.reverse_each do |owner, name, previous|
      owner.send(:remove_const, name)
      owner.const_set(name, previous) if previous
    end
    @created_modules.reverse_each { |owner, name| owner.send(:remove_const, name) }
  end

  def test_real_trusted_context_and_tenant_guard_run_before_any_catalog_read
    [context(capabilities: []), context(organization_id: 72)].each do |trusted|
      result = read(context: trusted)
      assert_equal "not_authorized", result.status
      assert_empty @scopes.values.flat_map(&:calls)
    end
    result = read(areas: [@area.with(decidim_organization_id: 72)])
    # A foreign-tenant area is no area at all: the reader asks for the place
    # (E2) and still never touches a catalog scope.
    assert_equal "ambiguous", result.status
    assert_equal ["activity_area_required"], result.warnings
    assert_empty @scopes.values.flat_map(&:calls)
  end

  def test_volunteer_public_scope_tenant_area_cancellation_signup_and_half_open_dates_precede_limit # rubocop:disable Metrics/CyclomaticComplexity
    @scopes[:VolunteerOpportunity].records << row(1, :volunteer)
    result = read
    calls = @scopes[:VolunteerOpportunity].calls
    assert_equal :publicly_visible, calls.first.first
    assert_includes calls, [:where, [{ organization: @organization, komsiluk_id: [12, nil], cancelled_at: nil }]]
    assert_includes calls, [:order, [{ komsiluk_id: :asc, starts_at: :asc, id: :asc }]]
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("signup_deadline_at > ?") && args.last == @now })
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("starts_at < ?") && args.last == @now + 7.days })
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("ends_at > ?") && args[1] == @now })
    assert_equal [:limit, [4]], calls.last
    assert_includes calls, [:select, Reader::VOLUNTEER_COLUMNS]
    assert_equal "ok", result.coverage.dig("families", "volunteers", "status")
    assert_equal "neighborhood_activity", result.facts.first["kind"]
    assert_equal "volunteer", result.facts.first.dig("coverage", "activity_type")
    assert_equal "Public 1", result.facts.first["text"]
    assert_includes result.warnings, "neighborhood_activity_participation_on_page"
  end

  # The owner decided on 2026-09-13 that an activity with no komšiluk covers
  # the whole city. It answers the komšiluk question, after every local row,
  # and says in its own coverage and text that it is not a local match.
  def test_row_without_a_komsiluk_is_answered_after_local_rows_and_labelled_city_wide
    @scopes[:VolunteerOpportunity].records << row(1, :volunteer)
    @scopes[:VolunteerOpportunity].records << row(2, :volunteer, komsiluk_id: nil)
    result = read
    local, citywide = result.facts
    assert_equal "komsiluk", local.dig("coverage", "geographic_scope")
    assert_equal "located_in", local.dig("coverage", "relation")
    assert_equal ["komsiluk-12"], local.dig("coverage", "area_slugs")
    assert_equal "Public 1", local.fetch("text")
    assert_equal "citywide", citywide.dig("coverage", "geographic_scope")
    assert_equal "covers_city", citywide.dig("coverage", "relation")
    assert_empty citywide.dig("coverage", "area_slugs")
    assert_equal "volunteer", citywide.dig("coverage", "activity_type")
    assert_equal "Public 2\n#{I18n.t("decidim_app.milica.activity.citywide", locale: "sr")}", citywide.fetch("text")
  end

  def test_mz_request_never_uses_komsiluk_id_or_headquarters_as_volunteer_geography
    result = read(areas: [@area.with(kind: "mz", slug: "mz-ledinci")])
    assert_equal "unsupported_geography", result.coverage.dig("families", "volunteers", "status")
    assert_includes result.warnings, "neighborhood_activity_mz_volunteer_unmapped"
    assert_empty @scopes[:VolunteerOpportunity].calls
  end

  def test_meetings_apply_public_hierarchy_venue_geometry_visibility_and_time_before_limit # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    @scopes[:Meeting].records << row(2, :meeting)
    result = read
    calls = @scopes[:Meeting].calls
    assert_equal [:visible_for, :not_hidden, :not_withdrawn], calls.first(3).map(&:first)
    assert(calls.any? { |method, args| method == :where && args.first.is_a?(Hash) && args.first[:private_meeting] == false && args.first[:deleted_at].nil? })
    assert_includes calls, [:where, [{ type_of_meeting: %w(in_person hybrid) }]]
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("end_time > ?") && args[1] == @now + 7.days && args[2] == @now })
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("point(decidim_meetings_meetings.longitude, decidim_meetings_meetings.latitude)") })
    assert_equal [:limit, [4]], calls.last
    [:ParticipatoryProcess, :Assembly].each do |name|
      assert_includes @scopes[name].calls, [:where, [{ organization: @organization, private_space: false, deleted_at: nil }]]
      assert_includes @scopes[name].calls, [:where, [{ published_at: ..@now }]]
    end
    assert_equal "/processes/public/f/4/meetings/2", result.facts.first["destination"]
  end

  def test_projects_use_approved_public_projection_and_hidden_storage_policy_not_raw_submission
    configure_budget
    submission = row(3, :project)
    @scopes[:PartnerProjectSubmission].records << submission
    result = read
    calls = @scopes[:PartnerProjectSubmission].calls
    assert_equal :approved, calls.first.first
    assert_includes calls, [:where, [{ organization: @organization }]]
    assert_includes calls, [:where, [{ decidim_budgets_projects: { decidim_budgets_budget_id: 9, deleted_at: nil } }]]
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("ends_on >= ?") })
    assert(calls.any? { |method, args| method == :where && args.first.to_s.include?("point(decidim_budgets_projects.longitude, decidim_budgets_projects.latitude)") })
    projection = calls.find { |method, _| method == :select }.last
    assert(projection.all? { |column| !column.match?(/description|title|address|decidim_user_id/) })
    assert_equal "Public native project", result.facts.first["text"]
    assert_equal "community_project", result.facts.first.dig("coverage", "activity_type")
    assert_equal "date", result.facts.first.dig("validity", "precision")
    assert_equal "/biceriseno/projekti/30", result.facts.first["destination"]
  end

  def test_unpublished_future_or_foreign_storage_does_not_expose_projects
    configure_budget(published_at: @now + 1.day)
    assert_equal "empty", read.coverage.dig("families", "projects", "status")
    assert_empty @scopes[:PartnerProjectSubmission].calls
  end

  def test_explicit_date_and_bounded_family_truncation_are_visible_and_round_robin
    configure_budget
    @scopes[:VolunteerOpportunity].records.concat((1..4).map { |id| row(id, :volunteer) })
    @scopes[:Meeting].records << row(5, :meeting)
    @scopes[:PartnerProjectSubmission].records << row(6, :project)
    first = @now + 1.day
    last = @now + 2.days
    result = read(explicit_time: true, starts_at: first, ends_at: last)
    assert_equal first.iso8601, result.coverage["starts_at"]
    assert_equal last.iso8601, result.coverage["ends_at"]
    assert_equal(%w(volunteer meeting community_project), result.facts.first(3).map { |fact| fact.dig("coverage", "activity_type") })
    assert_equal 5, result.facts.length
    assert_equal true, result.coverage.dig("families", "volunteers", "truncated")
    assert_includes result.warnings, "neighborhood_activity_list_bounded"
    assert_equal false, result.coverage["complete_inventory"]
  end

  def test_requested_family_does_not_query_other_catalogs_and_existing_weekend_window_is_reused
    reader = Reader.new(organization: @organization, area_matcher: Object.new)
    from, through = reader.requested_window(entities: { "time_expression" => "ovog vikenda" }, context:, topic: "volunteer")
    assert_equal "2026-09-12T00:00:00+02:00", from.iso8601
    assert_equal "2026-09-14T00:00:00+02:00", through.iso8601
    result = reader.call(areas: [@area], context:, starts_at: from, ends_at: through, explicit_time: true, locale: "sr", family_keys: ["volunteers"])
    assert_equal ["volunteers"], result.coverage["families"].keys
    assert_empty @scopes[:Meeting].calls
    assert_empty @scopes[:PartnerProjectSubmission].calls
  end

  def test_missing_geometry_does_not_widen_to_city_and_preserves_explicit_komsiluk_activity
    @scopes[:VolunteerOpportunity].records << row(1, :volunteer)
    result = read(areas: [@area.with(boundary: {})])
    assert_equal "ok", result.status
    assert_equal(["volunteer"], result.facts.map { |fact| fact.dig("coverage", "activity_type") })
    assert_equal "unavailable", result.coverage.dig("families", "meetings", "status")
    assert_equal "unavailable", result.coverage.dig("families", "projects", "status")
    assert_includes result.warnings, "neighborhood_activity_unavailable"
    assert_empty @scopes[:Meeting].calls
    assert_empty @scopes[:PartnerProjectSubmission].calls
  end

  def test_exact_soon_window_is_next_seven_days_without_changing_other_catalog_time_rules
    reader = Reader.new(organization: @organization, area_matcher: Object.new)
    assert_equal [@now, @now + 7.days], reader.requested_window(entities: { "time_expression" => "uskoro" }, context:, topic: "participation")
    assert_raises(ArgumentError) { reader.requested_window(entities: { "time_expression" => "sljedeceg mjeseca" }, context:, topic: "participation") }
  end

  private

  def namespace(owner, name)
    return owner.const_get(name, false) if owner.const_defined?(name, false)

    owner.const_set(name, Module.new).tap { @created_modules << [owner, name] }
  end

  def install(owner, name, value)
    # The contracts also run inside the full Rails suite. Preserve loaded or
    # autoloaded real models, then restore their exact objects after each test.
    previous = owner.const_get(name, false) if owner.const_defined?(name, false)
    owner.send(:remove_const, name) if previous
    owner.const_set(name, value)
    @created_constants << [owner, name, previous]
  end

  def model(owner, name, table_name)
    relation = Scope.new
    @scopes[name] = relation
    install(owner, name, Class.new do
      define_singleton_method(:table_name) { table_name }
      [:publicly_visible, :approved, :active, :published, :visible_for].each do |method|
        define_singleton_method(method) { |*args| relation.public_send(method, *args) }
      end
    end)
  end

  def context(capabilities: ["public_reads"], organization_id: 71)
    Contracts::TrustedContext.new(organization_id:, conversation_key: "a" * 64, now: @now, capabilities:)
  end

  def read(areas: [@area], context: self.context, starts_at: @now, ends_at: @now + 12.hours, explicit_time: false)
    Reader.new(organization: @organization, area_matcher: Object.new).call(areas:, context:, starts_at:, ends_at:, explicit_time:, locale: "sr")
  end

  def row(id, kind, komsiluk_id: 12)
    row = PublicRow.new(id:, title: "<b>Public #{id}</b>", komsiluk_id:, starts_at: @now + 1.hour, ends_at: @now + 2.hours,
                        opportunity_kind: "volunteer", updated_at: @now, start_time: @now + 1.hour, end_time: @now + 2.hours,
                        starts_on: @now.to_date, ends_on: @now.to_date + 2, component: Object.new)
    row.project = PublicRow.new(id: id * 10, title: { "sr" => "Public native project" }, updated_at: @now) if kind == :project
    row
  end

  def configure_budget(published_at: @now - 1.day)
    space = Struct.new(:organization, :deleted_at) { def published? = false }.new(@organization, nil)
    component = Struct.new(:participatory_space, :published_at) { def published? = true }.new(space, published_at)
    @budget = Data.define(:id, :deleted_at, :component).new(9, nil, component)
  end
end
