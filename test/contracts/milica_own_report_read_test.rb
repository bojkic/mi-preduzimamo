# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "i18n"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text") unless defined?(Decidim::Bih::Text)
require File.join(engine_root, "app/presenters/decidim/bih/report_status_presenter") unless defined?(Decidim::Bih::ReportStatusPresenter)
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/own_report_question") unless defined?(Decidim::Bih::Concierge::Dialogue::OwnReportQuestion)
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_metrics"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"

# The real read boundary and selector; only records, status-label presentation
# and route generation are synthetic. No Rails, database or citizen content.
class MilicaOwnReportReadTest < Minitest::Test
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Record = Data.define(:id, :reference, :status, :created_at, :updated_at, :decidim_organization_id, :decidim_user_id)
  Relation = Data.define(:rows, :trace) do
    def select(*columns)
      trace << [:select, columns]
      self
    end

    def order(**ordering)
      trace << [:order, ordering]
      raise "Wrong recent-report ordering" unless ordering == { created_at: :desc, id: :desc }

      self.class.new(rows.sort_by { |row| [row.created_at, row.id] }.reverse, trace)
    end

    def limit(number)
      trace << [:limit, number]
      raise "Unbounded recent-report query" unless [1, 3].include?(number)

      self.class.new(rows.first(number), trace)
    end

    def to_a = rows
  end

  def setup
    @old_locales = I18n.available_locales
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    @temporary = []
    [[Decidim, :User], [Decidim::Bih, :Report], [Decidim::Bih, :ReportStatusPresenter], [Decidim::Bih, :Engine]].each do |namespace, name|
      next if namespace.const_defined?(name, false)

      namespace.const_set(name, Class.new do
        def self.find_by(*) = raise "Unexpected lookup"

        def self.where(*) = raise "Unexpected query"

        def self.label(*) = raise "Unexpected label"

        def self.routes = raise "Unexpected route"
      end)
      @temporary << [namespace, name]
    end
    @organization = Data.define(:id).new(71)
    @actor = Data.define(:id).new(17)
    @now = Time.utc(2026, 9, 9, 12)
    @rows = (1..4).map { |id| record(id) } + [record(98, owner: 18), record(99, organization: 72)]
    @trace = []
  end

  def teardown
    @temporary.reverse_each { |namespace, name| namespace.send(:remove_const, name) }
    I18n.available_locales = @old_locales
  end

  def test_latest_and_list_are_actor_tenant_scoped_ordered_and_bounded_before_materialization
    [["Moja posljednja prijava", 1, [4]], ["Moje prijave", 3, [4, 3, 2]]].each do |query, limit, ids|
      @trace.clear
      result = read(entities: { "query" => query })
      assert_equal "ok", result.status
      assert_equal(ids.map { |id| record(id).reference }, result.facts.map { |fact| fact.fetch("reference") })
      assert_equal [:where, { decidim_organization_id: 71, decidim_user_id: 17 }], @trace.first
      assert_includes @trace, [:select, [:id, :reference, :status, :duplicate_of_report_id, :review_state, :reviewed_at, :last_citizen_reply_at, :created_at, :updated_at]]
      assert_includes @trace, [:order, { created_at: :desc, id: :desc }]
      assert_equal [:limit, limit], @trace.last
      assert_equal "actor", result.coverage.fetch("ownership")
      assert_equal limit, result.coverage.fetch("limit")
      result.facts.each do |fact|
        assert_equal false, fact.has_key?("description")
        assert_equal false, fact.has_key?("address")
        assert_equal "own_report_status", fact.fetch("kind")
      end
    end
  end

  def test_anonymous_missing_permission_and_wrong_actor_never_query_reports
    [[nil, ["own_report_reads"]], [nil, ["public_reads"]], [17, ["public_reads"]]].each do |actor_id, capabilities|
      result = read(actor_id:, capabilities:, entities: { "query" => "Moje prijave" })
      assert_equal "not_authorized", result.status
      assert_empty result.facts
      assert_empty @trace
    end
    assert_raises(Contracts::Invalid) { read(actor_id: 999, entities: { "query" => "Moje prijave" }) }
    assert_empty @trace
  end

  def test_no_owned_rows_does_not_fall_back_to_someone_elses_recent_report
    @rows = @rows.reject { |row| row.decidim_organization_id == 71 && row.decidim_user_id == 17 }
    result = read(entities: { "query" => "Moja posljednja prijava" })
    assert_equal "empty", result.status
    assert_equal ["no_owned_reports"], result.warnings
    assert_empty result.facts
  end

  def test_unqualified_or_other_person_queries_still_require_a_reference
    ["Posljednja prijava", "Prijave komšije", "Ne prikazuj moje prijave", "Moja prijava"].each do |query|
      result = read(entities: { "query" => query })
      assert_equal "ambiguous", result.status
      assert_equal ["report_reference_required"], result.warnings
      assert_empty @trace
    end
  end

  def test_explicit_reference_keeps_exact_owned_lookup_and_never_falls_back_to_latest
    [[record(2).reference, "ok"], [record(98, owner: 18).reference, "empty"], ["BR-2026-404", "empty"]].each do |reference, expected|
      @trace.clear
      result = read(entities: { "reference" => reference, "query" => "Moja posljednja prijava" })
      assert_equal expected, result.status
      assert_equal [[:find_by, { decidim_organization_id: 71, decidim_user_id: 17, reference: }]], @trace
      assert_equal reference, result.facts.first.fetch("reference") if expected == "ok"
    end
  end

  private

  def record(id, owner: 17, organization: 71)
    Record.new(id, format("BR-2026-%04d", id), "primljeno", @now - 100 + id, @now - 100 + id, organization, owner)
  end

  def read(entities:, actor_id: 17, capabilities: ["own_report_reads"])
    context = Contracts::TrustedContext.new(organization_id: 71, actor_id:, capabilities:, conversation_key: "d" * 64, now: @now)
    unused = Object.new
    port = DecidimApp::Bijeljina::Milica::ReadPort.new(organization: @organization, area_matcher: unused, event_feed: unused,
                                                       source_checker: unused, timetable: unused, directory: unused, duplicate_finder: unused, waste_schedule: unused)
    port.define_singleton_method(:log_failure) { |error, _| raise error }
    actor_lookup = ->(**scope) { @actor if scope == { id: 17, organization: @organization } }
    lookup = lambda do |**scope|
      @trace << [:find_by, scope]
      @rows.find { |row| scope.all? { |key, value| row.public_send(key) == value } }
    end
    query = lambda do |**scope|
      @trace << [:where, scope]
      Relation.new(@rows.select { |row| scope.all? { |key, value| row.public_send(key) == value } }, @trace)
    end
    paths = Object.new
    paths.define_singleton_method(:report_path) { |reference:| "/reports/#{reference}" }
    routes = Data.define(:url_helpers).new(paths)
    DecidimApp::Bijeljina::Milica::ReadMetrics.stub(:record, nil) do
      Decidim::User.stub(:find_by, actor_lookup) do
        Decidim::Bih::Report.stub(:find_by, lookup) do
          Decidim::Bih::Report.stub(:where, query) do
            Decidim::Bih::ReportStatusPresenter.stub(:label, ->(status, **) { "public-status:#{status}" }) do
              Decidim::Bih::Engine.stub(:routes, routes) { port.call(action: "report_status", topic: "report", entities:, context:) }
            end
          end
        end
      end
    end
  end
end
