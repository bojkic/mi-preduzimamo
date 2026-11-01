# frozen_string_literal: true

# rubocop:disable Rails/RefuteMethods -- standalone Minitest, not Rails assertions

require "bundler/setup"
require "minitest/autorun"
require "i18n"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/access"
require "active_support/core_ext/string/exclude"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/enumerable"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/text")
require File.join(engine_root, "app/services/decidim/bih/city/matching")
require File.join(engine_root, "app/services/decidim/bih/city/service_directory")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/contracts")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/procedure_runner")
require_relative "../../app/services/decidim_app/bijeljina/city_services_data"
require_relative "../../app/services/decidim_app/bijeljina/city_service_sources"
require_relative "../../app/services/decidim_app/bijeljina/city_service_notice_collector"
require_relative "../../app/services/decidim_app/bijeljina/service_procedures"
require_relative "../../app/services/decidim_app/bijeljina/city_directory"
require_relative "../../app/services/decidim_app/bijeljina/parking_zones"
require_relative "../../app/services/decidim_app/bijeljina/milica/directory_answer"
require_relative "../../app/services/decidim_app/bijeljina/milica/reference_read"
require_relative "../../app/services/decidim_app/bijeljina/milica/read_port"
require_relative "../../app/services/decidim_app/bijeljina/milica/registration_port"

# Authored synthetic directory selection and its actual read-result boundary: no Rails boot,
# domain models, provider, database, network, or replaced source-url validator.
require_relative "../support/synthetic_service_directory"

class MilicaDirectoryAnswerTest < Minitest::Test
  include SyntheticServiceDirectory
  Directory = DecidimApp::Bijeljina::CityDirectory
  Answer = DecidimApp::Bijeljina::Milica::DirectoryAnswer
  ReadPort = DecidimApp::Bijeljina::Milica::ReadPort
  Dialogue = Decidim::Bih::Concierge::Dialogue
  LOCALES = %w(sr sr-Cyrl bs hr en).freeze

  def setup
    super
    install_synthetic_service_directory
    @previous_backend = I18n.backend
    @previous_locales = I18n.available_locales
    I18n.available_locales = LOCALES
    I18n.backend = I18n::Backend::Simple.new
    I18n.backend.load_translations(File.expand_path("../../config/locales/milica_directory_answers.yml", __dir__))
    I18n.backend.load_translations(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue.yml"))
    @entry = Directory.find(:parking)
  end

  def teardown
    restore_synthetic_service_directory
    I18n.backend = @previous_backend
    I18n.available_locales = @previous_locales
    super
  end

  def test_ordinal_zone_correction_selects_only_reviewed_first_zone_payment
    ["Nije korisno: treba mi broj za prvu zonu.", "Није корисно: треба ми број за прву зону."].each do |query|
      selected = answer(query)
      assert_includes selected, "TEST-R"
      refute_includes selected, "TEST-B"
      refute_includes selected, "TEST-W"
      refute_includes selected, "Izmišljeni javor"
      refute_includes selected, "Izmišljena breza"
    end
  end

  def test_general_answer_preserves_reviewed_sections_and_canonical_tariffs
    tariffs = DecidimApp::Bijeljina::ParkingZones
    assert_equal tariffs.payment_description, @entry.fetch(:answer_sections).fetch(:payment)
    assert_equal tariffs.monthly_description, @entry.fetch(:answer_sections).fetch(:monthly)
    assert_equal tariffs::SOURCE_URL, @entry.fetch(:source_url)
    assert_equal [:operator, :payment, :monthly, :zones], @entry.fetch(:answer_sections).keys
    assert_equal @entry.fetch(:answer_sections).values.join(" "), answer("Opšte informacije o parkingu")
    assert_predicate @entry.fetch(:answer_sections), :frozen?
    assert @entry.fetch(:answer_sections).values.all?(&:frozen?)
  end

  def test_payment_questions_select_only_the_existing_sms_facts
    [
      "Kako da platim parking?", "Koji je SMS broj za parking?", "Plaćanje parkinga",
      "Koliko košta parking?", "Који је СМС број за паркинг?", "Kako se placa parking?",
      "How do I pay for parking?"
    ].each do |question|
      assert_equal @entry.fetch(:answer_sections).fetch(:payment), answer(question), question
    end

    payment = answer("SMS parking")
    assert_operator payment.length, :<, @entry.fetch(:answer).length
    assert_includes @entry.fetch(:answer), payment
    %w(mjesečna Izmišljena breza Izmišljeni javor).each { |unrequested| refute_includes payment, unrequested }
  end

  def test_single_zone_sms_questions_copy_only_that_reviewed_hourly_clause
    {
      "Na koji SMS broj se plaća crvena parking zona?" => "crvena / I zona TEST-R (1,85 KM/h)",
      "На који СМС број се плаћа црвена паркинг зона?" => "crvena / I zona TEST-R (1,85 KM/h)",
      "SMS za bijelu zonu?" => "bijela / zona centar TEST-W (2,35 KM/h)",
      "Koji je SMS broj za plavu zonu?" => "plava / II zona TEST-B (0,95 KM/h)",
      "What is the SMS number for the blue parking zone?" => "plava / II zona TEST-B (0,95 KM/h)"
    }.each do |question, clause|
      assert_includes @entry.fetch(:answer_sections).fetch(:payment), clause
      assert_equal "Plaćanje SMS-om: #{clause}.", answer(question), question
    end
  end

  def test_broader_zone_payment_questions_keep_the_complete_payment_section
    [
      "SMS za crvenu i plavu zonu?", "SMS za crvenu i ostale zone?",
      "SMS za crvenu zonu i dnevnu kartu?", "SMS za dnevnu kartu u plavoj zoni?",
      "SMS za I zonu?", "SMS za crvenu II zonu?",
      "SMS za crveni automobil?"
    ].each do |question|
      assert_equal @entry.fetch(:answer_sections).fetch(:payment), answer(question), question
    end
    expected = @entry.fetch(:answer_sections).values_at(:payment, :monthly).join("\n\n")
    assert_equal expected, answer("Koliko košta crvena zona po satu i mjesečna karta?")
    assert_includes answer("SMS za crvenu zonu i radno vrijeme?"), answer("radno vrijeme")
    assert_includes answer("SMS za crvenu zonu i mapa?"), "uvijek provjeri znak zone na ulici"
  end

  def test_changed_payment_structure_or_added_caveat_falls_back_without_losing_text
    payment = @entry.fetch(:answer_sections).fetch(:payment)
    ["#{payment} Provjeri znak zone prije plaćanja.", payment.sub("crvena / I zona", "crvena zona")].each do |text|
      entry = @entry.merge(answer_sections: @entry.fetch(:answer_sections).merge(payment: text))
      assert_equal text, answer("SMS za crvenu zonu?", entry:)
    end
  end

  def test_hours_questions_explicitly_report_the_missing_reviewed_schedule
    [
      "Koje je radno vrijeme parkinga?", "Do koliko sati se plaća parking?",
      "Kada se naplaćuje parking?", "Da li se nedjeljom plaća parking?",
      "Које је радно вријеме паркинга?", "Parking opening hours?"
    ].each do |question|
      reply = answer(question)
      assert_includes reply, "Pregledani podaci ne sadrže radno vrijeme ni termine naplate parkinga."
      assert_includes reply, "službenoj stranici Parking servisa"
      refute_match(/\d|KM|SMS/, reply)
    end
    refute @entry.fetch(:answer_sections).has_key?(:hours)
  end

  def test_missing_schedule_copy_exists_for_every_supported_locale
    LOCALES.each do |locale|
      reply = answer("radno vrijeme", locale:)
      assert_equal I18n.t("decidim_app.milica.directory_answers.parking_hours_unavailable", locale:, raise: true), reply
      refute_empty reply
      refute_match(/\d|translation missing/, reply)
    end
    assert_includes answer("радно вријеме", locale: "sr-Cyrl"), "Прегледани подаци не садрже"
    assert_includes answer("opening hours", locale: "en"), "does not include opening hours or charging hours"
  end

  def test_payment_and_hours_questions_include_both_facts_and_the_missing_schedule
    LOCALES.each do |locale|
      expected = [@entry.fetch(:answer_sections).fetch(:payment),
                  I18n.t("decidim_app.milica.directory_answers.parking_hours_unavailable", locale:, raise: true)].join("\n\n")
      ["Kako da platim parking i do koliko sati se plaća?", "SMS i radno vrijeme",
       "СМС и радно вријеме", "Parking payment and opening hours?"].each do |question|
        assert_equal expected, answer(question, locale:), question
      end
    end
  end

  def test_monthly_price_questions_use_only_reviewed_monthly_facts
    ["Koliko košta mjesečna karta?", "Koliko kosta mesecna karta?", "Parking pretplata",
     "Мјесечна паркинг карта", "Monthly parking prices?", "How much is a monthly parking pass?"].each do |question|
      assert_equal @entry.fetch(:answer_sections).fetch(:monthly), answer(question), question
    end
    refute_includes answer("Mjesečna karta"), "SMS"
    refute_includes answer("Mjesečna karta"), "Izmišljena breza"
  end

  def test_zone_lists_include_the_white_zone_and_explicit_maps_keep_the_reviewed_map_section
    overview = @entry.fetch(:answer_sections).values_at(:payment, :zones).join("\n\n")
    ["Parking zone?", "Koje su parking zone?", "Koje parking zone postoje?", "Паркинг зоне", "Parking zones?"].each do |question|
      assert_equal overview, answer(question), question
      assert_includes answer(question), "bijela / zona centar"
    end
    ["Mapa parking zona", "Parking map", "Мапа паркинг зона"].each do |question|
      assert_equal @entry.fetch(:answer_sections).fetch(:zones), answer(question), question
    end
    assert_includes answer("Parking zone"), "uvijek provjeri znak zone na ulici"
    assert_equal "Plaćanje SMS-om: plava / II zona TEST-B (0,95 KM/h).", answer("Koji je SMS broj za plavu zonu?")
  end

  def test_explicit_combinations_keep_only_requested_reviewed_sections
    {
      "Koliko košta parking po satu i mjesečna karta?" => [:payment, :monthly],
      "SMS i parking zone" => [:payment, :zones],
      "Parking zone i SMS" => [:payment, :zones],
      "Mjesečna cijena i mapa parkinga" => [:monthly, :zones]
    }.each do |question, keys|
      assert_equal @entry.fetch(:answer_sections).values_at(*keys).join("\n\n"), answer(question), question
    end

    missing_hours = answer("radno vrijeme")
    assert_equal [@entry.fetch(:answer_sections).fetch(:monthly), missing_hours].join("\n\n"), answer("Mjesečna karta i radno vrijeme")
    assert_equal [*@entry.fetch(:answer_sections).values_at(:payment, :zones), missing_hours].join("\n\n"),
                 answer("SMS, mapa zona i radno vrijeme")
  end

  def test_unsupported_and_ambiguous_questions_keep_the_full_answer
    [
      nil, "", "parking", "Gdje se nalazi Parking servis?",
      "Mogu li platiti karticom?", "Kako platiti preko aplikacije?",
      "Mogu li platiti gotovinom na automatu?", "Kako platiti parking kaznu?",
      "Koji je SMS broj u mojoj ulici?", "Ne pitam za SMS, zanima me nešto drugo",
      "Ne pitam za mjesečnu kartu", "Ne zanimaju me parking zone", "Not monthly parking prices",
      "Kako platiti mjesečnu kartu?", "SMS broj za mjesečnu kartu?", "Where can I buy a monthly pass?",
      "Koja je moja parking zona?", "U kojoj sam zoni?", "Parking zone u Izmišljenoj ulici?",
      "Where can I pay cash?", "Is parking free on holidays?"
    ].each do |question|
      assert_equal @entry.fetch(:answer), answer(question), question.inspect
    end
  end

  def test_other_entries_and_unstructured_parking_data_remain_unchanged
    Directory.all.reject { |entry| entry.fetch(:key) == :parking }.each do |entry|
      assert_equal entry.fetch(:answer), answer("SMS i radno vrijeme", entry:)
    end
    entry = @entry.except(:answer_sections)
    assert_equal entry.fetch(:answer), answer("SMS parking", entry:)
    assert_equal entry.fetch(:answer), answer("radno vrijeme", entry:)
    incomplete = @entry.merge(answer_sections: @entry.fetch(:answer_sections).except(:monthly))
    assert_equal @entry.fetch(:answer), answer("Mjesečna karta i radno vrijeme", entry: incomplete)
  end

  def test_directory_read_preserves_source_date_coverage_and_not_live_flags_for_each_facet
    ["parking", "Kako platiti parking?", "Do kada se naplaćuje parking?", "Mjesečna karta", "Parking zone",
     "SMS i radno vrijeme", "Na koji SMS broj se plaća crvena parking zona?"].each do |query|
      LOCALES.each do |locale|
        result = directory_read(query, locale:)
        fact = result.facts.fetch(0)
        assert_equal "ok", result.status
        assert_equal 1, result.facts.length
        assert_equal "service:parking", fact.fetch("id")
        assert_equal "service_directory", fact.fetch("kind")
        assert_equal "city_services:parking", fact.fetch("source_id")
        assert_equal "Izmišljeni parking", fact.fetch("source_label")
        assert_equal "https://community.example.invalid/parking", fact.fetch("source_url")
        assert_equal "2040-09-14", fact.fetch("observed_at")
        assert_equal({ "reviewed_on" => "2040-09-14", "live_status" => false }, result.validity)
        assert_equal({ "organization_id" => 71, "scope" => "reviewed_static_directory" }, result.coverage)
        assert_equal result.coverage, fact.fetch("coverage")
        assert_equal ["snapshot_not_live_status"], result.warnings
        assert_equal result.warnings, fact.fetch("warning_codes")
        assert_equal({ "id" => "city_services:parking", "label" => @entry.fetch(:title), "url" => @entry.fetch(:source_url) }, result.source)
        assert_nil result.checked_at
        assert_empty result.candidates
        assert_equal Decidim::Bih::Transliterator.localize(answer(query, locale:), locale:).squish, fact.fetch("text")
      end
    end
  end

  def test_parking_answer_survives_account_explanation_and_explicit_resume
    start_conversation
    first = conversation_turn("Kako platiti parking?", action: "ask_information", topic: "parking", operation: "start")
    assert_equal "answered", first.resolution
    assert_includes first.reply.text, @entry.fetch(:answer_sections).fetch(:payment)
    refute_includes first.reply.text, "mjesečna"

    registration = conversation_turn("Želim registraciju", action: "registration", topic: "account", operation: "switch")
    assert_equal "handoff", registration.resolution
    refute registration.handoff_completed
    explanation = conversation_turn("Da li je bilten obavezan?", action: "ask_information", topic: "account", operation: "continue")
    assert_equal "answered", explanation.resolution
    assert_includes explanation.reply.text, "Izbor je dobrovoljan"
    assert_includes explanation.reply.text, "sve četiri teme"
    refute explanation.handoff_completed
    assert_equal "registration", @dialogue_state.fetch("active_task")
    assert_equal "parking", @dialogue_state.dig("suspended_task", "topic")

    phone = conversation_turn("Zašto vam treba moj telefon?", action: "ask_information", topic: "account", operation: "continue")
    assert_equal "answered", phone.resolution
    assert_includes phone.reply.text, "potvrdu pristupa"
    assert_includes phone.reply.text, "nisam poslala kod"
    refute phone.handoff_completed
    assert_equal "registration", @dialogue_state.fetch("active_task")
    assert_equal "parking", @dialogue_state.dig("suspended_task", "topic")

    # Explicit resume uses the coordinator's canonical no-model understanding.
    resumed = conversation_turn("nastavi", understanding: Dialogue::Contracts::Understanding.clarify)
    assert_equal "answered", resumed.resolution
    assert_equal "parking", @dialogue_state.fetch("topic")
    assert_nil @dialogue_state["suspended_task"]
    assert_includes resumed.reply.text, @entry.fetch(:answer_sections).fetch(:payment)
    assert_includes resumed.reply.text, @entry.fetch(:source_url)
    refute_includes resumed.reply.text, "mjesečna"
    refute_includes resumed.reply.text, "bilten"
  end

  def test_final_parking_hours_answer_keeps_missing_data_and_official_source
    start_conversation
    result = conversation_turn("Do koliko sati se plaća parking?", action: "ask_information", topic: "parking", operation: "start")

    assert_equal "answered", result.resolution
    assert_includes result.reply.text, "Pregledani podaci ne sadrže radno vrijeme ni termine naplate parkinga."
    assert_equal 1, result.reply.text.scan(@entry.fetch(:source_url)).length
    refute_includes result.reply.text, "SMS"
    refute_includes result.reply.text, "KM"
    refute result.handoff_completed
    assert_equal ["service:parking"], result.fact_ids
  end

  def test_final_single_zone_sms_answer_keeps_the_source_without_other_zone_numbers
    start_conversation
    result = conversation_turn("Na koji SMS broj se plaća crvena parking zona?", action: "ask_information", topic: "parking", operation: "start")

    assert_equal "answered", result.resolution
    assert_includes result.reply.text, "Plaćanje SMS-om: crvena / I zona TEST-R (1,85 KM/h)."
    refute_match(/TEST-[WBD]/, result.reply.text)
    assert_equal 1, result.reply.text.scan(@entry.fetch(:source_url)).length
    refute result.handoff_completed
    assert_equal ["service:parking"], result.fact_ids
  end

  def test_final_mixed_parking_answer_preserves_both_facets_and_one_source
    start_conversation
    result = conversation_turn("Kako da platim parking i do koliko sati se plaća?", action: "ask_information", topic: "parking", operation: "start")

    assert_equal "answered", result.resolution
    assert_includes result.reply.text, @entry.fetch(:answer_sections).fetch(:payment)
    assert_includes result.reply.text, "Pregledani podaci ne sadrže radno vrijeme ni termine naplate parkinga."
    assert_equal 1, result.reply.text.scan(@entry.fetch(:source_url)).length
    refute_includes result.reply.text, "mjesečna"
    refute_includes result.reply.text, "Izmišljena breza"
    refute result.handoff_completed
    assert_equal ["service:parking"], result.fact_ids
  end

  # Authored keyword collisions retain numeric/generic-word rejection.

  def test_a_bare_number_in_the_question_no_longer_elects_the_sistem_48_entry
    assert_empty selected("Da li odgovor stiže za 24 ili za 48 sati?")
    assert_equal [:prijava_problema], selected("Šta je Sistem 48?")
    assert_equal [:prijava_problema], selected("Znači li Sistem 48 da moraju riješiti za 48 sati?")
  end

  def test_uslov_no_longer_elects_the_building_permits_entry
    assert_empty selected("Da li je potvrda dolaska uslov za ulaz ili samo molba?")
    assert_equal [:gradjevinske_dozvole_legalizacija], selected("Koji su lokacijski uslovi za gradnju?")
    assert_includes selected("Gdje se vadi građevinska dozvola?"), :gradjevinske_dozvole_legalizacija
  end

  # Authored stale-slot counterexample: a retained fictional street must
  # never override the zone explicitly named in the current question.
  def test_an_explicit_zone_is_never_answered_from_the_previous_subjects_street
    start_conversation
    @dialogue_state = @dialogue_state.merge(
      "active_task" => "ask_information", "topic" => "waste",
      "entities" => { "query" => "Kad se kupi smeće u Ulici Izmišljena lipa?", "street" => "Izmišljena lipa" },
      "entity_provenance" => { "query" => "citizen", "street" => "citizen" }
    )
    # What the model returns on such a turn: the new subject, and the retained
    # street handed straight back.
    result = conversation_turn(
      "A sada mi reci broj za SMS parking u plavoj zoni.",
      action: "ask_information", topic: "parking", operation: "switch",
      entities: { "query" => "broj za SMS parking u plavoj zoni", "street" => "Izmišljena lipa" }
    )

    assert_equal "answered", result.resolution
    assert_includes result.reply.text, "Plaćanje SMS-om: plava / II zona TEST-B (0,95 KM/h)."
    refute_includes result.reply.text, "TEST-W"
    refute_includes result.reply.text, "2,35 KM/h"
    refute_includes result.reply.text, "Izmišljena lipa"
  end

  # The street answer itself is unchanged and still correct: it is being
  # inherited that was wrong, not the rows. This also pins the two numbers the
  # citizen was given, so the case above cannot pass by both sides moving.
  def test_the_reviewed_street_rows_still_answer_a_street_the_citizen_names
    street = DecidimApp::Bijeljina::ParkingZones.default.lookup_named("Izmišljena lipa")
    summary = DecidimApp::Bijeljina::ParkingZones.default.street_summary(street)

    assert_equal "white", street.fetch(:zone)
    assert_includes summary, "TEST-W (2,35 KM/h)"
  end

  def test_contact_read_returns_individually_cited_phone_and_hours_facts
    port = ReadPort.allocate
    port.instance_variable_set(:@organization, Data.define(:id).new(71))
    port.instance_variable_set(:@directory, Directory)
    read = port.send(:directory_read, topic: "social_welfare", entities: { "query" => "Telefon i radno vrijeme Centra za socijalni rad" },
                                      locale: "sr", now: Time.utc(2040, 9, 16, 12))
    assert_equal "ok", read.status
    assert_equal(%w(phone hours), read.facts.map { |fact| fact["predicate"] })
    assert_equal "https://community.example.invalid/social-hours", read.facts.last["source_url"]
    assert_equal 2, read.source.size
    assert_equal false, read.validity["live_status"]
    assert_includes read.warnings, "snapshot_not_live_status"
    refute_includes read.facts.map { |fact| fact["text"] }.join(" "), "Uslove i iznose"
  end

  def test_approved_override_wins_over_phrase_and_bundled_procedure_matching
    entry = Directory.find(:maticar).merge(content_origin: "admin_override", description: "Odobreno uputstvo operatera.")
    directory = Object.new
    directory.define_singleton_method(:search) { |_query, **_options| [entry] }
    directory.define_singleton_method(:find) { |_key| entry }
    directory.define_singleton_method(:procedure_for) { |_key| raise "bundled procedure must not replace override" }
    port = ReadPort.allocate
    port.instance_variable_set(:@organization, Data.define(:id).new(71))
    port.instance_variable_set(:@directory, directory)

    ["e-matičar", "Matičar"].each do |query|
      read = port.send(:directory_read, topic: "city_service", entities: { "query" => query }, locale: "sr", now: Time.utc(2040, 9, 16))
      assert_equal "ok", read.status
      assert_equal "service:maticar", read.facts.first["id"]
      assert_equal "service_directory", read.facts.first["kind"]
    end
  end

  def test_selected_reference_questions_reach_reviewed_facts_before_generic_directory
    port = ReadPort.allocate
    unused_directory = Object.new
    unused_directory.define_singleton_method(:find) { |*| raise "reference must precede generic directory" }
    port.instance_variable_set(:@directory, unused_directory)
    port.instance_variable_set(:@organization, Data.define(:id).new(71))
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "d" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2040, 9, 16, 12))
    { "health" => ["Rade li stomatolozi u domu zdravlja nedjeljom?", "nedjelja 09–11"],
      "city_service" => ["Koji je kontakt Biroa?", "SINTETIČKI KONTAKT BIROA"],
      "education" => ["Kada je zimski raspust za osnovne skole?", "8–19. januara 2041"] }.each do |topic, (query, expected)|
      read = port.send(:information_read, topic:, entities: { "query" => query }, context:, locale: "sr", location: nil)
      assert_equal "ok", read.status
      assert_includes read.facts.map { |fact| fact["text"] }.join(" "), expected
      assert_equal false, read.validity["live_status"]
    end
  end

  def test_border_pilot_uses_prepared_store_without_network_or_generic_roads_fallback
    port = ReadPort.allocate
    store = Object.new
    store.define_singleton_method(:snapshot) { |**_args| nil }
    port.instance_variable_set(:@source_checker, store)
    context = Dialogue::Contracts::TrustedContext.new(organization_id: 71, conversation_key: "d" * 64,
                                                      capabilities: ["public_reads"], now: Time.utc(2040, 9, 16, 12))
    read = port.send(:information_read, topic: "roads", entities: { "query" => "Koliko je čekanje na GP Rača?" }, context:, locale: "sr", location: nil)
    assert_equal "unavailable", read.status
    assert_includes read.warnings, "public_notice_pilot_not_prepared"
    assert_empty read.facts
  end

  private

  def selected(query)
    Directory.directory.search(query).map { |entry| entry[:key] }
  end

  def start_conversation
    organization = Data.define(:id, :host).new(71, "milica.example.org")
    @dialogue_context = Dialogue::Contracts::TrustedContext.new(
      organization_id: organization.id, conversation_key: "d" * 64, now: Time.utc(2040, 9, 16, 12),
      capabilities: %w(public_reads registration_handoff)
    )
    # Only the anonymous directory/account branches run. Unused data adapters
    # are injected explicitly; no Rails routes, actor lookup or DB is booted.
    unused = Object.new.freeze
    reads = ReadPort.new(organization:, event_feed: unused, source_checker: DecidimApp::Bijeljina::CityServiceNoticeCollector,
                         timetable: unused, area_matcher: unused, directory: Directory, duplicate_finder: unused, waste_schedule: unused)
    registration = DecidimApp::Bijeljina::Milica::RegistrationPort.new(organization:)
    @dialogue_runner = Dialogue::ProcedureRunner.new(
      read_port: reads, registration_port: registration,
      destinations: { report: "/biceriseno/prijavi", account: "/biceriseno/moj-nalog", neighborhood: "/biceriseno/komsiluk", support: "/pages/pomoc" }
    )
    @dialogue_state = Dialogue::StateStore.new.empty_state(@dialogue_context)
  end

  def conversation_turn(text, understanding: nil, entities: nil, **classification)
    understanding ||= Dialogue::Contracts::Understanding.parse(
      **classification, entities: entities || { "query" => text }, locale: "sr", needs_clarification: false, secondary: nil
    )
    result = @dialogue_runner.call(understanding:, state: @dialogue_state, context: @dialogue_context, message: text)
    @dialogue_state = result.state
    result
  end

  def answer(query, locale: "sr", entry: @entry)
    Answer.call(entry:, query:, locale:)
  end

  def directory_read(query, locale:)
    # Exercise only the unchanged directory branch with the authored synthetic
    # catalog. All runtime adapter constructors are intentionally left unbooted.
    port = ReadPort.allocate
    port.instance_variable_set(:@organization, Data.define(:id).new(71))
    port.instance_variable_set(:@directory, Directory)
    port.send(:directory_read, topic: "parking", entities: { "query" => query }, locale:)
  end
end

# rubocop:enable Rails/RefuteMethods

# Fixture cleanup is part of isolation: later tests must see their original
# configuration and cache objects, including an originally absent cache.
class SyntheticServiceDirectoryRestorationTest < Minitest::Test
  include SyntheticServiceDirectory

  def test_fixture_restores_constants_and_caches_after_each_use
    host = DecidimApp::Bijeljina
    owners = [host::DirectoryServiceFacts, host::ParkingZones, host::CityServicesData, host::CityServiceSources]
    constants = owners.flat_map { |owner| owner.constants(false).map { |name| [owner, name, owner.const_get(name, false)] } }
    caches = [[host::CityDirectory, :@directory], [host::ParkingZones, :@default], [host::DirectoryServiceFacts, :@data],
              [host::ServiceProcedures, :@all], [host::CitizenReferenceCatalog, :@default]].map do |owner, name|
      [owner, name, owner.instance_variable_defined?(name), owner.instance_variable_get(name)]
    end
    2.times do
      begin
        install_synthetic_service_directory
        assert_equal "Izmišljeni parking", host::CityDirectory.find(:parking).fetch(:title)
        assert_equal 2, host::DirectoryServiceFacts.all(:socijalna_zastita).size
      ensure
        restore_synthetic_service_directory
      end
      constants.each { |owner, name, value| assert_same value, owner.const_get(name, false), "#{owner}::#{name}" }
      caches.each do |owner, name, present, value|
        assert_equal present, owner.instance_variable_defined?(name), "#{owner} #{name} presence"
        assert_same value, owner.instance_variable_get(name), "#{owner} #{name} value" if present
      end
    end
  end
end
