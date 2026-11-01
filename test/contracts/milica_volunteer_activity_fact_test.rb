# frozen_string_literal: true

# Standalone Minitest uses refute helpers; this fixture restores its isolated
# locale/backend directly and never changes an application request's locale.
# rubocop:disable Rails/I18nLocaleAssignment, Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support"
require "active_support/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "i18n"

engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/procedure_runner")
require File.join(engine, "lib/decidim/bih/transliterator")
require_relative "../../app/services/decidim_app/bijeljina/milica/platform_catalog_read"

# Real public catalog projection and final renderer; only domain selection and
# unchanged SQL calendar execution are synthetic. No Rails, database or network.
class MilicaVolunteerActivityFactTest < Minitest::Test
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Reader = DecidimApp::Bijeljina::Milica::PlatformCatalogRead
  Row = Struct.new(:id, :title, :description, :komsiluk, :starts_at, :ends_at, :category, :signup_deadline_at,
                   :day_keys, :month_keys, :time_slot_keys, :opportunity_kind, :location_label, :requirements,
                   :capacity, :updated_at, :series_key, :series_position, :series_total, :partner_profile_id, keyword_init: true) do
    def series? = !series_key.to_s.empty? && series_total.to_i > 1
  end
  class Scope
    attr_reader :calls

    def initialize(rows)
      @rows = rows
      @calls = []
    end

    def where(*args)
      calls << [:where, args]
      @rows = @rows.select { |row| args.first.fetch(:komsiluk_id).include?(row.komsiluk&.id) } if args.first.is_a?(Hash) && args.first.has_key?(:komsiluk_id)
      self
    end

    [:publicly_visible, :includes, :order].each do |method|
      define_method(method) do |*args|
        calls << [method, args]
        self
      end
    end

    def limit(number)
      calls << [:limit, [number]]
      @rows = @rows.first(number)
      self
    end

    def to_a = @rows
  end

  def setup
    @prior_backend = I18n.backend
    @prior_locales = I18n.available_locales
    @prior_locale = I18n.locale
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = Dialogue::Contracts::LOCALES
    I18n.locale = :sr
    engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
    I18n.backend.load_translations(*%w(sr sr-Cyrl bs hr en).map { |locale| File.join(engine, "config/locales/#{locale}.yml") },
                                   File.join(engine, "config/locales/decidim_bih_dialogue.yml"),
                                   File.expand_path("../../config/locales/milica_activity.yml", __dir__))
    @organization = Data.define(:id, :host).new(71, "mi.example.test")
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "e" * 64,
                                                       now: Time.utc(2026, 9, 10, 18), capabilities: ["public_reads"])
    @row = Row.new(id: 2, title: "Public online volunteering", description: "Reviewed public description", komsiluk: nil,
                   starts_at: Time.utc(2026, 9, 13, 18, 23), ends_at: Time.utc(2027, 1, 7, 19, 23),
                   category: "digital_media", day_keys: %w(monday sunday), month_keys: %w(september january),
                   time_slot_keys: %w(day afternoon), opportunity_kind: "volunteer", location_label: "ONline",
                   requirements: "", capacity: 5, updated_at: @context.now, series_key: "private-series-key",
                   series_position: 1, series_total: 5)
    @areas = []
    @old_public_path = Decidim::Bih.method(:public_path) if Decidim::Bih.respond_to?(:public_path)
    Decidim::Bih.define_singleton_method(:public_path) { |suffix| "/biceriseno/#{suffix}" }
    @constants = []
    owner = self
    install(:VolunteerOpportunity, Class.new do
      define_singleton_method(:table_name) { "decidim_bih_volunteer_opportunities" }
      define_singleton_method(:publicly_visible) { owner.instance_variable_get(:@scope).publicly_visible }
    end)
    install(:VolunteerSignup, Class.new do
      [:going, :where, :group].each { |method| define_singleton_method(method) { |*| self } }
      define_singleton_method(:count) { {} }
    end)
  end

  def teardown
    @constants.reverse_each do |name, previous|
      Decidim::Bih.send(:remove_const, name)
      Decidim::Bih.const_set(name, previous) if previous
    end
    Decidim::Bih.singleton_class.send(:remove_method, :public_path)
    Decidim::Bih.define_singleton_method(:public_path, @old_public_path) if @old_public_path
    I18n.backend = @prior_backend
    I18n.available_locales = @prior_locales
    I18n.locale = @prior_locale
  end

  def test_source_online_label_series_and_exact_dst_aware_dates_reach_final_answers_in_all_locales
    original = @row.to_h
    Dialogue::Contracts::LOCALES.each do |locale|
      result = read(locale:)
      fact = result.fetch(:facts).first
      assert_equal "unknown", fact.dig("coverage", "geographic_scope")
      assert_empty fact.dig("coverage", "area_slugs")
      assert_equal "online", fact.dig("activity_location", "participation_mode")
      assert_equal false, fact.dig("activity_location", "physical_area_verified")
      assert_equal({ "position" => 1, "total" => 5 }, fact.fetch("series"))
      assert_equal "2026-09-13T20:23:00+02:00", fact.dig("validity", "starts_at")
      assert_equal "2027-01-07T20:23:00+01:00", fact.dig("validity", "ends_at")
      assert_equal "dated_interval", fact.dig("schedule", "kind")
      assert_equal @row.day_keys, fact.dig("schedule", "day_keys")
      assert_equal true, fact.dig("validity", "long_interval")
      assert_includes fact["warning_codes"], "volunteer_long_interval_requires_confirmation"
      refute_includes result.fetch(:warnings), "volunteer_long_interval_requires_confirmation"
      assert_equal "/biceriseno/volontiranje#volunteer-opportunity-2", fact.fetch("destination")
      answer = render(result, locale:)
      assert_includes answer.reply.text, I18n.t("decidim_app.milica.activity.online_notice", locale:)
      assert_includes answer.reply.text, I18n.t("decidim_app.milica.activity.long_interval_notice", locale:)
      assert_includes answer.reply.text, I18n.t("decidim.bih.volunteer.index.series_position", locale:, position: 1, total: 5)
      assert_includes answer.reply.text, "#volunteer-opportunity-2"
      assert_includes answer.reply.text, "13.09.2026. 20:23 – 07.01.2027. 20:23 (Europe/Sarajevo)"
      refute_match(/translation missing|%\{|private-series-key/, answer.reply.text)
      assert_equal "answered", answer.resolution
    end
    assert_equal original, @row.to_h
  end

  def test_unknown_or_mixed_location_is_never_reclassified_as_online_or_a_physical_neighborhood
    ["", "Online ili u kancelariji", "Near the public park"].each do |label|
      @row.location_label = label
      fact = read.fetch(:facts).first
      assert_equal "unspecified", fact.dig("activity_location", "participation_mode")
      assert_equal "unknown", fact.dig("coverage", "geographic_scope")
      refute_includes fact.fetch("text"), I18n.t("decidim_app.milica.activity.online_notice", locale: :sr)
    end
  end

  # Owner decision of 2026-09-13: a record with no komšiluk covers the whole
  # city, so an explicit local filter admits it. It is never presented as a
  # local match: its coverage and its own text both say it is city-wide.
  def test_explicit_local_filter_admits_the_unlocated_record_labelled_for_the_whole_city
    area = Data.define(:id, :slug, :kind) do
      def translated_name = "Dvorovi"
    end.new(12, "komsiluk-12", "komsiluk")
    @areas = [area]
    Dialogue::Contracts::LOCALES.each do |locale|
      result = read(locale:, entities: { "area_query" => "Komšiluk Dvorovi" })
      assert_equal "ok", result.fetch(:status)
      fact = result.fetch(:facts).first
      label = I18n.t("decidim_app.milica.activity.citywide", locale:)
      assert_equal "citywide", fact.dig("coverage", "geographic_scope")
      assert_equal "covers_city", fact.dig("coverage", "relation")
      assert_empty fact.dig("coverage", "area_slugs")
      assert fact.fetch("text").end_with?("\n#{label}"), fact.fetch("text")
      assert_operator fact.fetch("text").length, :<=, 1_000
      refute_match(/translation missing/i, fact.fetch("text"))
      assert_includes render(result, locale:).reply.text, label
    end
    assert_includes @scope.calls, [:where, [{ komsiluk_id: [12, nil] }]]
    assert_includes @scope.calls, [:order, [{ komsiluk_id: :asc }]]
  end

  def test_recurring_availability_preserves_calendar_without_fabricated_occurrence_dates
    @row.starts_at = @row.ends_at = nil
    @row.series_key = nil
    fact = read.fetch(:facts).first
    assert_equal "recurring_availability", fact.dig("schedule", "kind")
    assert_nil fact.dig("validity", "starts_at")
    assert_nil fact.dig("validity", "ends_at")
    assert_equal false, fact.dig("validity", "long_interval")
    assert_nil fact["series"]
    @row.day_keys = []
    assert_equal "unknown", read.fetch(:facts).first.dig("schedule", "kind")
  end

  def test_short_shift_omits_long_interval_warning_and_invalid_series_is_not_invented
    @row.ends_at = @row.starts_at + 1.hour
    @row.series_position = 7
    fact = read.fetch(:facts).first
    assert_nil fact["series"]
    assert_equal false, fact.dig("validity", "long_interval")
    assert_empty fact["warning_codes"]
    refute_includes fact["text"], I18n.t("decidim_app.milica.activity.long_interval_notice", locale: :sr)
  end

  def test_public_description_stays_bounded_and_cannot_hide_online_or_long_interval_qualifiers
    @row.description = "Public detail " * 150
    fact = read.fetch(:facts).first
    assert_operator fact["text"].length, :<=, 1_000
    assert_includes fact["text"], I18n.t("decidim_app.milica.activity.online_notice", locale: :sr)
    assert_includes fact["text"], I18n.t("decidim_app.milica.activity.long_interval_notice", locale: :sr)
    assert_equal "answered", render(read, locale: "sr").resolution
    template = File.read(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "app/views/decidim/bih/volunteer/index.html.erb"))
    assert_includes template, 'id="volunteer-opportunity-<%= opportunity.id %>"'
  end

  def test_same_series_shifts_share_only_common_prose_without_losing_any_fact_or_date
    @rows = (0...5).map do |index|
      @row.dup.tap do |row|
        row.id += index
        row.series_position += index
        row.starts_at += index.weeks
        row.ends_at += index.weeks
      end
    end
    Dialogue::Contracts::LOCALES.each do |locale|
      result = read(locale:)
      answer = render(result, locale:)
      assert_equal @rows.map { |row| "volunteer_opportunity:#{row.id}" }, answer.fact_ids
      assert_equal 1, answer.reply.text.scan(Decidim::Bih::Transliterator.localize("Reviewed public description", locale:)).length
      %w(online_notice long_interval_notice).each do |key|
        assert_equal 1, answer.reply.text.scan(I18n.t("decidim_app.milica.activity.#{key}", locale:)).length
      end
      result.fetch(:facts).zip(@rows).each do |fact, row|
        assert_includes fact.fetch("text"), Decidim::Bih::Transliterator.localize("Public online volunteering", locale:)
        assert_includes fact.fetch("text"), Decidim::Bih::Transliterator.localize("ONline", locale:)
        assert_equal row.starts_at, Time.iso8601(fact.dig("validity", "starts_at"))
        assert_equal row.ends_at, Time.iso8601(fact.dig("validity", "ends_at"))
        assert_includes fact.fetch("text"), row.ends_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. %H:%M")
      end

      # Every shift survives as a FACT with its own dates (asserted above and
      # by fact_ids). The rendered answer is composed to a budget, so it may
      # show fewer items than it holds - but it may never drop one silently:
      # what it shows carries its own link, and anything it holds back is
      # stated as a count with a way to reach the rest.
      shown = @rows.count { |row| answer.reply.text.include?("#volunteer-opportunity-#{row.id}") }

      assert_operator shown, :>=, 1, "the answer showed no shift at all"
      if shown < @rows.length
        assert_includes answer.reply.text,
                        I18n.t("decidim.bih.dialogue.more_items", shown:, total: @rows.length, locale:),
                        "held back #{@rows.length - shown} shift(s) without saying so"
        assert_includes answer.reply.text, "/biceriseno/volontiranje"
      end
      refute_includes answer.reply.text, "private-series-key"
    end
  end

  def test_different_series_or_common_content_and_interleaved_events_are_never_compacted_together
    second = @row.dup
    second.id = 3
    second.series_position = 2
    third = second.dup
    third.id = 4
    third.series_position = 3
    [:series_key, :partner_profile_id, :title, :description, :location_label, :category, :requirements].each do |key|
      other = second.dup
      other.public_send("#{key}=", "Different #{key}")
      @rows = [@row, other, third]
      facts = read.fetch(:facts)
      assert_equal 3, facts.length
      assert(facts.all? { |fact| fact.fetch("text").include?(I18n.t("decidim_app.milica.activity.long_interval_notice", locale: :sr)) })
    end
    @rows = [@row, third] # A filtered-out position2 is not silently restored.
    result = read
    assert_equal([1, 3], result.fetch(:facts).map { |fact| fact.dig("series", "position") })
    assert_equal ["volunteer_opportunity:2", "volunteer_opportunity:4"], render(result, locale: "sr").fact_ids
  end

  private

  def install(name, value)
    # Full Rails runs may have already loaded these models. Restore their
    # exact objects after the synthetic read, as other catalog fixtures do.
    previous = Decidim::Bih.const_get(name, false) if Decidim::Bih.const_defined?(name, false)
    Decidim::Bih.send(:remove_const, name) if previous
    Decidim::Bih.const_set(name, value)
    @constants << [name, previous]
  end

  def read(locale: "sr", entities: {})
    @scope = Scope.new(@rows || [@row])
    areas = @areas
    matcher = Object.new
    matcher.define_singleton_method(:resolve) { |**| Data.define(:status, :areas).new(:ok, areas) }
    reader = Reader.new(organization: @organization, area_matcher: matcher)
    reader.define_singleton_method(:volunteer_time_filter) { |scope, _now, _date| scope }
    reader.call(topic: "volunteer", entities:, context: @context, locale:)
  end

  def render(result, locale:)
    runner = Dialogue::ProcedureRunner.new(read_port: ->(**) { Dialogue::Contracts::ReadResult.new(**result) }, registration_port: Object.new,
                                           destinations: { support: "/help", account: "/account", neighborhood: "/board", report: "/report" })
    input = Dialogue::Contracts::Understanding.parse(action: "ask_information", topic: "volunteer", entities: { "query" => "Volonterske prilike" },
                                                     operation: "start", needs_clarification: false, secondary: nil, locale:)
    runner.call(understanding: input, state: Dialogue::StateStore.new.empty_state(@context), context: @context, message: "Volonterske prilike")
  end
end

# rubocop:enable Rails/I18nLocaleAssignment, Rails/RefuteMethods
