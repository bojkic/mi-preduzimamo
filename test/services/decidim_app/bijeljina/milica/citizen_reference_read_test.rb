# frozen_string_literal: true

require_relative "../citizen_reference_catalog_test"
require "decidim/bih/concierge/dialogue/contracts"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/citizen_reference_read"

class CitizenReferenceReadTest < ActiveSupport::TestCase
  Reader = DecidimApp::Bijeljina::Milica::CitizenReferenceRead
  Context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext

  def setup
    @data = SyntheticCitizenReferences.data
    @catalog = DecidimApp::Bijeljina::CitizenReferenceCatalog.new(data: @data)
    @prior_default = DecidimApp::Bijeljina::CitizenReferenceCatalog.instance_variable_get(:@default)
    DecidimApp::Bijeljina::CitizenReferenceCatalog.instance_variable_set(:@default, @catalog)
    @reader = Reader.new(organization: Struct.new(:id).new(42), catalog: @catalog)
  end

  def teardown
    DecidimApp::Bijeljina::CitizenReferenceCatalog.instance_variable_set(:@default, @prior_default)
  end

  def test_biro_contact_and_job_search_do_not_invent_workplace_or_vacancy_counts
    contact = ask("city_service", "Koji je telefon biroa za zaposljavanje?")
    assert_equal "ok", contact.fetch(:status)
    contact = ask("city_service", "Koji je telefon Biro Bijeljina?")
    assert_equal "ok", contact.fetch(:status)
    assert_includes text(contact), "SINTETIČKI KONTAKT BIROA"
    jobs = ask("city_service", "Gdje su oglasi Zavoda za zaposljavanje?")
    assert_equal "ok", jobs.fetch(:status)
    assert_equal(["vacancy_search"], jobs.fetch(:facts).map { |row| row.fetch("facet") })
    jobs = ask("city_service", "Zavod za zaposljavanje, oglasi za posao")
    assert_equal(["vacancy_search"], jobs.fetch(:facts).map { |row| row.fetch("facet") })
    assert_includes text(jobs), "mjesto rada"
    assert_not_includes text(jobs), "23"
  end

  def test_health_service_is_precise_and_unknown_price_does_not_get_hours
    hours = ask("health", "Rade li stomatolozi u domu zdravlja nedjeljom?")
    assert_equal "ok", hours.fetch(:status)
    assert_includes text(hours), "nedjelja 09–11"
    assert_nil hours.fetch(:facts).first.fetch("source_published_on")
    unknown = ask("health", "Koliko kosta pregled stomatologa u domu zdravlja?")
    assert_equal "unavailable", unknown.fetch(:status)
    assert_empty unknown.fetch(:facts)
    assert_includes unknown.fetch(:warnings), "requested_reference_feature_unknown"
  end

  def test_intercity_contact_does_not_answer_a_departure_or_city_bus_question
    assert_equal "ok", ask("transport", "Telefon Izmišljeni prevoz")[:status]
    %w(polazi autobus).each do |word|
      result = ask("transport", "Kada #{word} Izmišljeni prevoz?")
      assert_empty result.fetch(:facts)
      assert_equal "not_ready", result.fetch(:coverage).fetch("status")
    end
    assert_not Reader.handles?(topic: "transport", entities: { "query" => "Gradski autobus 1 raspored" })
  end

  def test_expired_fuel_window_is_not_answerable_and_expiry_uses_sarajevo_midnight
    before = ask("agriculture", "Do kada obrasci za gorivo?", now: "2040-11-15T22:59:59Z")
    after = ask("agriculture", "Do kada obrasci za gorivo?", now: "2040-11-15T23:00:00Z")
    assert_equal "ok", before.fetch(:status)
    assert_equal "unavailable", after.fetch(:status)
    assert_empty after.fetch(:facts)
    assert_includes after.fetch(:warnings), "reference_expired"
    wrong_year = ask("agriculture", "Do kada obrasci za gorivo za 2041?")
    assert_empty wrong_year.fetch(:facts)
  end

  def test_calendar_levels_and_breaks_are_distinct_and_do_not_prove_local_closure
    result = ask("education", "Kada je zimski raspust za osnovne skole?")
    assert_equal 1, result.fetch(:facts).size
    assert_equal "synthetic:calendar:primary:2040-2041", result.fetch(:facts).first.fetch("subject_id")
    assert_includes text(result), "8–19. januara 2041"
    assert_includes text(result), "ne potvrđuje promjenu gradskog prevoza"
    assert_empty ask("education", "Ima li nastave danas u osnovne skole?").fetch(:facts)
    assert_empty ask("education", "Je li zimski raspust danas?").fetch(:facts)
    assert_empty ask("education", "Kada je zimski raspust 2042?").fetch(:facts)
  end

  def test_event_is_an_announcement_and_disappears_after_its_local_date
    result = ask("community", "Kada je predstava Izmišljena predstava?")
    assert_equal "announced_event", result.fetch(:facts).first.fetch("kind")
    assert_equal "owner_attributed_press", result.fetch(:source).fetch("authority")
    assert_includes result.fetch(:warnings), "announced_event_not_current_programme"
    assert_empty ask("community", "Je li predstava Izmišljena predstava veceras?").fetch(:facts)
    assert_equal "ok", ask("community", "Je li predstava Izmišljena predstava sutra?").fetch(:status)
    expired = ask("community", "Kada je predstava Izmišljena predstava?", now: "2040-09-16T22:00:00Z")
    assert_empty expired.fetch(:facts)
    assert_includes expired.fetch(:warnings), "reference_expired"
    assert_empty ask("community", "Ima li slobodnih ulaznica za Izmišljena predstava?").fetch(:facts)
    assert_empty ask("community", "Koliko je karta za Izmišljena predstava?").fetch(:facts)
  end

  def test_named_other_city_and_specific_workplace_do_not_get_host_office_details
    assert_empty ask("city_service", "Telefon Zavoda za zaposljavanje u Brckom?").fetch(:facts)
    assert_empty ask("city_service", "Gdje je mjesto rada iz oglasa Zavoda za zaposljavanje?").fetch(:facts)
    assert_empty ask("education", "Kada je zimski raspust osnovne skole u Tuzli?").fetch(:facts)
  end

  def test_revoked_and_document_changed_references_have_no_publishable_text
    data = SyntheticCitizenReferences.data
    data.fetch("facts").find { |row| row["id"] == "health:dentistry-hours" }["review_status"] = "revoked"
    @reader = Reader.new(organization: Struct.new(:id).new(42), catalog: DecidimApp::Bijeljina::CitizenReferenceCatalog.new(data:))
    result = ask("health", "Rade li stomatolozi u domu zdravlja nedjeljom?")
    assert_empty result.fetch(:facts)
    assert_includes result.fetch(:warnings), "reference_revoked"
    data.fetch("documents").find { |row| row["id"] == "intercity" }["url"] = "https://example.com/unreviewed"
    result = ask("transport", "Telefon Izmišljeni prevoz")
    assert_empty result.fetch(:facts)
    assert_includes result.fetch(:warnings), "reference_unreviewed"
  end

  def test_untrusted_context_and_wrong_tenant_are_refused
    assert_equal "not_authorized", @reader.call(topic: "health", entities: {}, context: {}, locale: "sr")[:status]
    context = Context.new(organization_id: 43, conversation_key: "a" * 64, capabilities: ["public_reads"])
    assert_equal "not_authorized", @reader.call(topic: "health", entities: {}, context:, locale: "sr")[:status]
  end

  def test_cyrillic_alias_and_reply_script_preserve_the_same_fact_identity
    latin = ask("health", "Radno vrijeme stomatologije doma zdravlja")
    cyrillic = ask("health", "Радно вријеме стоматологије дома здравља", locale: "sr-Cyrl")
    assert_equal latin.fetch(:facts).first.fetch("id"), cyrillic.fetch(:facts).first.fetch("id")
    assert_includes text(cyrillic), "Дома здравља"
  end

  private

  def ask(topic, query, now: "2040-09-15T10:00:00Z", locale: "sr")
    context = Context.new(organization_id: 42, conversation_key: "a" * 64, capabilities: ["public_reads"], now: Time.iso8601(now))
    @reader.call(topic:, entities: { "query" => query }, context:, locale:)
  end

  def text(result)
    result.fetch(:facts).map { |row| row.fetch("text") }.join(" ")
  end
end
