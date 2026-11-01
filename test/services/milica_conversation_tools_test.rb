# frozen_string_literal: true

require "test_helper"
require_relative "../support/synthetic_conversation_data"

class MilicaConversationToolsTest < ActiveSupport::TestCase
  include SyntheticConversationData
  Host = DecidimApp::Bijeljina
  Dialogue = Decidim::Bih::Concierge::Dialogue

  setup do
    @organization = Decidim::Organization.first || create(:organization, available_locales: ["sr"], default_locale: "sr")
    @now = Time.utc(2040, 9, 16, 6)
    install_synthetic_conversation_data(day: @now.to_date)
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, clock: -> { @now })
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "a" * 64,
                                                       actor_id: nil, account_state: "anonymous", capabilities: ["public_reads"],
                                                       now: @now, deadline: Dialogue::TurnBudget.new)
  end

  teardown { restore_synthetic_service_directory }

  test "public breadth returns typed bounded evidence through real readers" do
    requests = [
      ["read_parking_tariffs", { "zone" => "red" }],
      ["read_platform_guidance", { "subject" => "feedback" }],
      ["read_platform_guidance", { "subject" => "points" }],
      ["read_platform_guidance", { "subject" => "platform" }],
      ["read_platform_guidance", { "subject" => "account" }],
      ["read_platform_guidance", { "subject" => "launch" }],
      ["read_platform_guidance", { "subject" => "race" }],
      ["read_platform_guidance", { "subject" => "proposals" }],
      ["read_foundation", { "facet" => "contact" }],
      ["read_public_notice", { "source" => "pio_notices" }],
      ["read_public_notice", { "source" => "bihamk_border" }],
      ["read_directory", { "query" => "voda" }],
      ["read_procedure", {}],
      ["search_public_knowledge", { "query" => "dozvola" }],
      ["read_civic_guidance", { "domain" => "recycling" }]
    ]
    requests.each do |name, arguments|
      result = call(name, arguments)
      assert_instance_of Dialogue::EvidenceEnvelope, result, name
      assert_includes %w(ok ambiguous unsupported unavailable expired), result.status, name
      assert result.for_prompt(context: @context, eligibility: @bundle.eligibility), name
      assert_equal false, result.coverage_complete
    end
  end

  test "provider contact evidence remains available independently of live outages" do
    result = call("read_civic_guidance", { "domain" => "billing", "biller" => "electricity" })
    assert_equal "ok", result.status
    contact = result.evidence.find { |row| row.fetch("text").include?("IZMIŠLJENI KONTAKT KVAROVA") && row.fetch("text").include?("opcija TEST") }
    assert contact, "Reviewed provider fault contact must reach the model"
    assert_includes contact.fetch("text"), "09–12"
    assert_includes contact.fetch("text"), "00–24"
    assert_equal "https://civic.example.invalid/electricity-fault", contact.fetch("source_url")
    assert_equal false, contact.dig("facts", "validity", "live_status")
    assert result.for_prompt(context: @context, eligibility: @bundle.eligibility)
  end

  test "derived billing boundaries and complaint routes have no invented publication date" do
    result = call("read_civic_guidance", { "domain" => "billing", "biller" => "electricity", "focus" => "personal" })
    facts = result.evidence.map { |row| row.dig("facts", "source_fact") }
    derived = facts.select { |fact| %w(billing_boundary billing_next_step).include?(fact["kind"]) }
    assert_equal 2, derived.size
    derived.each do |fact|
      assert_nil fact["source_published_on"]
      assert fact["reviewed_on"]
    end
  end

  test "self haul recycling facts are reachable through the declared public tool" do
    result = call("read_civic_guidance", { "domain" => "recycling", "focus" => "self_haul" })
    assert_equal "ok", result.status
    assert_includes result.evidence.map { |row| row.fetch("text") }.join(" "), "IZMIŠLJENA DEPONIJA"
  end

  test "parking review date is not promoted to publisher update or publication" do
    result = call("read_parking_tariffs", { "zone" => "white" })
    fact = result.evidence.first.dig("facts", "source_fact")
    assert_equal Host::ParkingZones::TARIFF_VERIFIED_ON.iso8601, fact.fetch("reviewed_on")
    assert_nil fact.fetch("published_at")
    assert_nil fact.fetch("updated_at")
    assert_includes result.warnings, "review_date_is_not_publication_or_update_date"
  end

  test "every public service capability has a direct reader and honest empty boundary" do
    Host::Milica::ConversationTools::CAPABILITIES.each do |capability, topics|
      topics.each do |topic|
        arguments = topics.one? ? {} : { "topic" => topic }
        properties = @bundle.registry.declarations.find { |row| row.fetch("name") == "read_#{capability}" }.dig("parameters", "properties")
        arguments["date"] = "2040-09-16" if properties.has_key?("date") && topic != "budget"
        result = call("read_#{capability}", arguments)
        assert_instance_of Dialogue::EvidenceEnvelope, result, "#{capability}/#{topic}"
        assert_equal false, result.coverage_complete
      end
    end
  end

  test "waste reads keep a specific street ahead of a broader city scope" do
    base = { "area_query" => "Bijeljina" }
    [{ "query" => "Izmišljena breza" }, { "street" => "Izmišljena breza", "query" => "Bijeljina" },
     { "address" => "Izmišljena breza", "street" => "Bijeljina" }].each do |specific|
      result = call("read_waste_schedule", base.merge(specific))
      assert_equal "ok", result.status
      fact = result.evidence.first.fetch("facts").fetch("source_fact")
      assert_equal "Izmišljena breza, Bijeljina", fact.dig("coverage", "query")
      assert_equal ["ponedjeljak"], fact.dig("coverage", "collection_days")
      assert result.for_prompt(context: @context, eligibility: @bundle.eligibility)
    end
    city = call("read_waste_schedule", base)
    assert_equal "ambiguous", city.status
    assert_empty city.evidence
    assert_includes city.warnings, "waste_named_street_or_settlement_required"
  end

  test "unknown specific waste place never falls back to the city and date limits stay enforced" do
    base = { "area_query" => "Bijeljina" }
    missing = call("read_waste_schedule", base.merge("street" => "Nepostojeca ulica 9981"))
    assert_empty missing.evidence
    assert_not_equal "ok", missing.status
    future = call("read_waste_schedule", base.merge("street" => "Izmišljena breza", "date" => "2041-01-05"))
    assert_equal "expired", future.status
    assert_empty future.evidence
  end

  test "named capability tools eliminate capability topic cross products and retain closed schemas" do
    declarations = @bundle.registry.declarations.index_by { |row| row.fetch("name") }
    assert_equal 29, declarations.size
    boarding = declarations.fetch("published_boarding_points").fetch("parameters")
    assert_equal %w(destination_query origin_query), boarding.fetch("required").sort
    assert_equal false, boarding.fetch("additionalProperties")
    assert_equal %w(destination_query origin_query), boarding.fetch("properties").keys.sort
    assert_not declarations.has_key?("read_public_service")
    Host::Milica::ConversationTools::CAPABILITIES.each do |capability, topics|
      parameters = declarations.fetch("read_#{capability}").fetch("parameters")
      assert_equal false, parameters.fetch("additionalProperties")
      assert_not parameters.fetch("properties").has_key?("capability")
      if topics.one?
        assert_not parameters.fetch("properties").has_key?("topic")
      else
        assert_equal topics, parameters.dig("properties", "topic", "enum")
        assert_includes parameters.fetch("required"), "topic"
      end
    end
    assert_raises(Dialogue::Contracts::Invalid) { call("read_public_service", {}) }
    assert_raises(Dialogue::Contracts::Invalid) { call("read_waste_schedule", { "capability" => "environment" }) }
    assert_raises(Dialogue::Contracts::Invalid) { call("read_waste_schedule", { "topic" => "bulky_waste" }) }
    actual = call("read_environment", { "topic" => "bulky_waste" })
    assert_instance_of Dialogue::EvidenceEnvelope, actual
  end

  test "typed area kind separates equal names and cannot be overridden by another kind slug" do
    mz = public_test_area("mz-mirna", 19.0, 44.5, kind: "mz", name: "Mirna")
    neighborhood = public_test_area("komsiluk-mirna", 19.0, 44.5, name: "Mirna")
    before = Decidim::Bih::CitizenProfile.count
    assert_equal "ambiguous", call("read_area", { "area_query" => "Mirna" }).status
    selected = call("read_area", { "area_query" => "Mirna", "place_kind" => "mz" })
    fact = selected.evidence.first.dig("facts", "source_fact")
    assert_equal "mz", fact.fetch("area_kind")
    assert_equal mz.slug, fact.fetch("area_slug")
    assert_includes fact.fetch("destination"), "/mjesne-zajednice/#{mz.slug}"
    assert selected.for_prompt(context: @context, eligibility: @bundle.eligibility)
    mismatch = call("read_area", { "area_slug" => neighborhood.slug, "place_kind" => "mz" })
    assert_empty mismatch.evidence
    assert_equal "unsupported", mismatch.status
    contact = call("read_mz_contact", { "area_query" => "Mirna", "query" => "telefon" })
    assert_equal "public_mz_contact", contact.evidence.first.dig("facts", "source_fact", "kind")
    assert_includes contact.evidence.first.dig("facts", "source_fact", "destination"), mz.slug
    assert_equal before, Decidim::Bih::CitizenProfile.count
    assert_raises(Dialogue::Contracts::Invalid) { call("read_mz_contact", { "place_kind" => "komsiluk" }) }
    assert_raises(Dialogue::Contracts::Invalid) { call("read_area", { "place_kind" => "private_board" }) }
  end

  test "typed area kind constrains consented location while default still exposes both public kinds" do
    public_test_area("mz-located", 19.0, 44.5, kind: "mz")
    public_test_area("located-neighborhood", 19.0, 44.5)
    location = { latitude: 44.505123, longitude: 19.005321, accuracy: 5, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, location:, clock: -> { @now })
    both = call("read_area", {})
    assert_equal %w(komsiluk mz), both.evidence.map { |row| row.dig("facts", "source_fact", "area_kind") }.sort
    selected = call("read_area", { "place_kind" => "mz" })
    assert_equal(["mz"], selected.evidence.map { |row| row.dig("facts", "source_fact", "area_kind") })
    assert_not_includes JSON.generate(selected.for_prompt(context: @context, eligibility: @bundle.eligibility)), location[:latitude].to_s
    denied = @context.with(capabilities: [])
    assert_raises(Dialogue::Contracts::Invalid) do
      @bundle.registry.call(name: "read_area", arguments: { "place_kind" => "mz" }, context: denied, eligibility: @bundle.eligibility)
    end
  end

  test "public area tools never infer a signed in citizen place from private profile" do
    mz = public_test_area("mz-profile-private", 19.0, 44.5, kind: "mz")
    neighborhood = public_test_area("komsiluk-profile-private", 19.0, 44.5)
    citizen = create(:user, :confirmed, organization: @organization)
    profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: citizen)
    profile.assign_komsiluk!(neighborhood, source: "dropdown", resolved_mz: mz)
    @context = @context.with(actor_id: citizen.id, account_state: "registered", capabilities: %w(public_reads neighborhood_reads))
    before = profile.reload.attributes
    Decidim::Bih::CitizenProfile.stub(:find_by, ->(*) { flunk "Public model tool read a private profile" }) do
      %w(read_area read_mz_contact read_public_activity).each do |name|
        result = call(name, {})
        assert_equal "ambiguous", result.status, name
        assert_empty result.evidence, name
        assert_empty result.candidates, name
        assert_includes result.warnings, "area_required", name
        assert_not_includes JSON.generate(result.for_prompt(context: @context, eligibility: @bundle.eligibility)), mz.slug
      end
      named = call("read_area", { "area_query" => mz.translated_name, "place_kind" => "mz" })
      assert_equal "ok", named.status
      assert_equal mz.slug, named.evidence.first.dig("facts", "source_fact", "area_slug")
    end
    assert_equal before, profile.reload.attributes
  end

  test "tools reject authority arguments and mismatched capability topic" do
    assert_raises(Dialogue::Contracts::Invalid) { call("read_directory", { "organization_id" => @organization.id }) }
    assert_raises(Dialogue::Contracts::Invalid) { call("read_service_events", { "topic" => "transport" }) }
    foreign = @context.with(organization_id: @organization.id + 100)
    assert_raises(Dialogue::Contracts::Invalid) { @bundle.registry.call(name: "read_directory", arguments: {}, context: foreign, eligibility: @bundle.eligibility) }
  end

  test "changed and invented records are denied at prompt and send" do
    result = call("read_parking_tariffs", { "zone" => "red" })
    original = result.evidence.first
    assert_not @bundle.eligibility.call(record: original.merge("text" => "invented"), organization_id: @organization.id,
                                        registry_epoch: @bundle.registry_epoch, now: @now, query_scope: result.query_scope)
    changed = result.query_scope.merge("operation" => "read_directory")
    assert_not @bundle.eligibility.call(record: nil, organization_id: @organization.id, registry_epoch: @bundle.registry_epoch, now: @now, query_scope: changed)
  end

  test "fresh source revocation invalidates an issued public result and empty scopes" do
    reader = Object.new
    value = { status: "ok", facts: [{ "id" => "published:1", "source_id" => "published", "text" => "Reviewed public notice" }], warnings: [] }
    reader.define_singleton_method(:public_capability) { |**| value }
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, read_port: reader, clock: -> { @now })
    result = call("read_service_events", { "topic" => "water" })
    assert_equal "ok", result.status
    value.replace(status: "unreviewed", warnings: ["review_revoked"])
    assert_raises(Dialogue::Contracts::Invalid) { result.for_prompt(context: @context, eligibility: @bundle.eligibility) }
    missing = call("read_service_events", { "topic" => "water" })
    assert_equal "unreviewed", missing.status
    value.replace(status: "empty", warnings: ["source_scope_changed"])
    assert_raises(Dialogue::Contracts::Invalid) { missing.for_prompt(context: @context, eligibility: @bundle.eligibility) }
  end

  test "procedure refresh review block prevents old knowledge and old evidence reuse" do
    card = Host::ServiceProcedures.all.first # rubocop:disable Rails/RedundantActiveRecordAllMethod -- public filesystem module, not ActiveRecord
    payload = { "status" => "ok" }
    row = Struct.new(:check_payload).new(payload)
    checker = Object.new
    checker.define_singleton_method(:snapshot) { |**| row }
    knowledge = synthetic_conversation_knowledge(organization: @organization, source_checker: checker)
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, source_checker: checker, knowledge:, clock: -> { @now })
    result = call("read_procedure", { "key" => card.fetch(:key).to_s })
    assert_equal "ok", result.status
    before = call("search_public_knowledge", { "document_id" => "bijeljina:procedure:#{card.fetch(:key)}" })
    assert_equal "ok", before.status, "The reviewed procedure must be searchable before its source review is revoked"
    assert_not_empty before.evidence
    payload.replace("status" => "unreviewed")
    assert_raises(Dialogue::Contracts::Invalid) { result.for_prompt(context: @context, eligibility: @bundle.eligibility) }
    current = call("read_procedure", { "key" => card.fetch(:key).to_s })
    assert_equal "unreviewed", current.status
    knowledge = call("search_public_knowledge", { "document_id" => "bijeljina:procedure:#{card.fetch(:key)}" })
    assert_empty knowledge.evidence
    assert_equal "unsupported", knowledge.status
  end

  test "fixed source qualifiers remain beside numeric values and voluntary feedback" do
    tariff = call("read_parking_tariffs", { "zone" => "red" }).evidence.first.fetch("facts").fetch("source_fact")
    assert_equal 185, tariff.dig("tariff", "hourly_fening")
    assert_equal "TEST-R", tariff.dig("tariff", "sms")
    assert_equal "fening", tariff.fetch("amount_unit")
    feedback = call("read_platform_guidance", { "subject" => "feedback" }).evidence.first.fetch("facts").fetch("source_fact").fetch("policy")
    assert_equal true, feedback.fetch("voluntary")
    assert_equal true, feedback.fetch("can_change")
    assert_match(/same session/, feedback.fetch("change_method"))
  end

  test "overview stays compact while every public guidance subject remains discoverable" do
    overview = nil
    Host::Milica::FoundationRead.stub(:new, ->(*) { flunk "overview must not read foundation records" }) do
      overview = policy("overview")
    end
    assert_equal Host::Milica::PlatformGuidanceTools::SUBJECTS.sort, overview.fetch("subjects").keys.sort
    assert_operator JSON.generate(overview).bytesize, :<, 8_000
    assert_equal false, overview.dig("subjects", "points", "personal_balance_included")
    assert_match(/exact map point is public/, overview.dig("subjects", "reports", "location_boundary"))
    assert_match(/same session/, overview.dig("subjects", "feedback", "rating"))
    assert_match(/Read the named guidance subject/, overview.fetch("detail_reader"))
    assert overview.dig("subjects", "reports", "public_routes", "report_form").start_with?("https://")
    assert_not overview.dig("subjects", "race").has_key?("standings")
    assert policy("reports").has_key?("statuses"), "targeted details remain readable"
  end

  test "report policy distinguishes exact public location private content and forwarding" do
    facts = policy("reports")
    assert_includes facts.fetch("public_fields"), "map_point"
    assert_equal %w(description photo contact), facts.fetch("private_fields")
    assert_match(/exact.*not blurred/, facts.fetch("public_map_point"))
    assert_match(/does not establish forwarding/, facts.fetch("statuses").fetch("Primljeno"))
    assert_match(/forwarding accepted/, facts.fetch("statuses").fetch("Poslato službi"))
    assert_equal false, facts.fetch("resolution_deadline_guaranteed")
    assert_equal "https://#{@organization.host}#{Decidim::Bih::Engine.routes.url_helpers.recover_report_path}", facts.fetch("public_routes").fetch("report_recovery")
    assert_equal "https://#{@organization.host}#{Decidim::Bih::Engine.routes.url_helpers.new_report_path}", facts.fetch("public_routes").fetch("report_form")
  end

  test "canonical report form URL survives current evidence answer validation" do
    result = call("read_platform_guidance", { "subject" => "reports" })
    envelope = result.for_prompt(context: @context, eligibility: @bundle.eligibility)
    url = "https://#{@organization.host}#{Decidim::Bih::Engine.routes.url_helpers.new_report_path}"
    payload = { "kind" => "answer", "answer" => "Obrazac za prijavu: #{url}", "evidence_ids" => [result.evidence.first.fetch("id")] }
    assert_equal payload, Dialogue::AnswerContract.new.call(payload:, evidence: [envelope], message: "Gdje je obrazac?", context: @context)
  end

  test "public recovery and feedback guidance never imply a send or absent personal text" do
    account = policy("account")
    recovery = account.fetch("missing_verification_message")
    assert_equal false, recovery.fetch("guidance_sends_message_or_authenticates")
    assert_match(/never chat/, recovery.fetch("code_entry"))
    assert_equal "https://#{@organization.host}#{Decidim::Bih::Engine.routes.url_helpers.phone_verification_path}", account.fetch("public_routes").fetch("verification")
    capture = policy("feedback").fetch("transcript_capture")
    assert_equal "explicit feedback click", capture.fetch("trigger")
    assert_equal Decidim::Bih::Concierge::WebChatController::MAX_MESSAGE_LENGTH, capture.fetch("question_max_characters")
    assert_equal Decidim::Bih::Concierge::WebChatController::MAX_FEEDBACK_REPLY_TEXT_LENGTH, capture.fetch("reply_max_characters")
    assert_equal false, capture.fetch("all_personal_text_absent_guaranteed")
  end

  test "topic and volunteering policy keeps choice attendance and points separate" do
    notifications = policy("notifications")
    assert_equal Decidim::Bih::TopicPreferences::TOPICS.sort, notifications.fetch("topics").keys.sort
    assert_equal false, notifications.fetch("topic_choice_is_all_channel_subscription")
    points = policy("points")
    assert_equal false, points.fetch("volunteer_signup_awards_points")
    assert_equal false, points.fetch("attendance_automatically_approves_reported_hours")
    assert_equal ["Citizen records actual hours", "Authorized hours reviewer approves work",
                  "Base points once per approved Sarajevo calendar day; organization hourly bonus remains separate"],
                 points.fetch("volunteer_hours_sequence")
    %w(reports feedback account notifications points).each do |subject|
      policy(subject).fetch("source_refs").each do |reference|
        owner, path = reference.split(":", 2)
        root = owner == "engine" ? Gem.loaded_specs.fetch("decidim-bih").full_gem_path : Rails.root
        assert File.file?(File.join(root, path)), reference
      end
    end
  end

  test "consented GIS resolves public area without leaking citizen coordinates or retaining location" do
    located = public_test_area("gps-area", 19.0, 44.5)
    named = public_test_area("named-area", 19.2, 44.7)
    location = { latitude: 44.505123, longitude: 19.005321, accuracy: 5, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, location:, clock: -> { @now })
    arguments = {}
    resolved = call("read_area", arguments)
    assert_equal "ok", resolved.status
    assert_includes JSON.generate(resolved.evidence), located.slug
    assert_not_includes JSON.generate(resolved.for_prompt(context: @context, eligibility: @bundle.eligibility)), location.fetch(:latitude).to_s
    assert_not_includes JSON.generate(@bundle.registry.declarations), location.fetch(:longitude).to_s
    explicit = call("read_area", arguments.merge("area_slug" => named.slug))
    assert_equal "ok", explicit.status
    assert_includes JSON.generate(explicit.evidence), named.slug
    assert_not_includes JSON.generate(explicit.evidence), located.slug
    @bundle = Host::Milica::ConversationTools.new(organization: @organization, clock: -> { @now })
    assert_equal "ambiguous", call("read_area", arguments).status
  end

  test "public GIS refuses unconsented or model location and model coordinate arguments" do
    arguments = {}
    location = { latitude: 44.5, longitude: 19.0, accuracy: 5, consent: true,
                 purpose: "current_location", provenance: "browser_geolocation" }
    [location.merge(consent: false), location.merge(provenance: "model"), location.merge(purpose: "unrelated_turn")].each do |invalid|
      @bundle = Host::Milica::ConversationTools.new(organization: @organization, location: invalid, clock: -> { @now })
      assert_raises(Dialogue::Contracts::Invalid) { call("read_area", arguments) }
    end
    assert_raises(Dialogue::Contracts::Invalid) { call("read_area", arguments.merge("latitude" => 44.5)) }
  end

  test "race guidance distinguishes excluded reports and contact privacy through the public evidence response" do
    result = call("read_platform_guidance", { "subject" => "race" })
    assert_equal "ok", result.status
    facts = result.evidence.first.dig("facts", "source_fact", "policy", "report_policy")
    assert_equal 2, facts.fetch("eligible_ordinary_points")
    %w(duplicate_points rejected_points corroboration_points).each { |key| assert_equal 0, facts.fetch(key) }
    assert_equal %w(trusted_registered_author verified_phone race_membership competition_window report_cap), facts.fetch("requirements")
    assert_equal true, facts.fetch("anonymous_contact_uses_same_eligibility")
    assert_equal false, facts.fetch("anonymous_contact_changes_points")
    prompt = JSON.generate(result.for_prompt(context: @context, eligibility: @bundle.eligibility))
    assert_includes prompt, '"duplicate_points":0'
    assert_includes prompt, '"anonymous_contact_uses_same_eligibility":true'
    assert_includes prompt, '"verified_phone"'

    Decidim::Bih::Setting.put(@organization, Decidim::Bih::Race::Config::NAMESPACE, "weights", { "report" => 7 })
    changed = policy("race").fetch("report_policy")
    assert_equal 7, changed.fetch("eligible_ordinary_points"), "the public rule follows the configured ordinary report weight"
    %w(duplicate_points rejected_points corroboration_points).each { |key| assert_equal 0, changed.fetch(key) }
  end

  test "race policy exposes cached public leaders without recomputation or citizen counts" do
    area = public_test_area("race-area", 19.0, 44.5)
    standing = Decidim::Bih::Race::Standing.create!(organization: @organization, komsiluk: area, zona: "grad",
                                                    score: 17, rank_overall: 1, rank_in_zone: 1, registered: 999,
                                                    computed_at: @now - 600, final: false)
    before = standing.attributes
    cached = policy("race").fetch("standings")
    assert_equal true, cached.fetch("available")
    assert_equal false, cached.fetch("refreshed_by_this_read")
    assert_equal false, cached.fetch("live")
    assert_equal 17, cached.fetch("top_rows").first.fetch("score")
    assert_equal @now - 600, Time.iso8601(cached.fetch("computed_at"))
    assert_equal "race-area", cached.fetch("zone_leaders").first.fetch("area_label")
    assert_not_includes JSON.generate(cached), "999"
    assert_equal before, standing.reload.attributes
    standing.update!(computed_at: @now + 1)
    assert_equal false, policy("race").fetch("standings").fetch("available")
  end

  test "public data scope excludes operational source health inventory" do
    scope = policy("platform").fetch("data_scope")
    assert_includes scope.fetch("reviewed_domains"), "local_areas"
    assert_equal "cached public donation data", scope.fetch("integrations").fetch("Odoo")
    assert_equal false, scope.fetch("operational_source_health_included")
    assert_equal false, scope.fetch("coverage_complete")
    assert_not_includes JSON.generate(scope), "failed_source"
  end

  private

  def public_test_area(slug, longitude, latitude, kind: "komsiluk", name: nil)
    points = [[longitude, latitude], [longitude + 0.01, latitude], [longitude + 0.01, latitude + 0.01],
              [longitude, latitude + 0.01], [longitude, latitude]]
    Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug:, name: { "sr" => name || slug },
                                    boundary: { "type" => "Polygon", "coordinates" => [points] })
  end

  def policy(subject)
    call("read_platform_guidance", { "subject" => subject }).evidence.first.fetch("facts").fetch("source_fact").fetch("policy")
  end

  def call(name, arguments)
    @bundle.registry.call(name:, arguments:, context: @context, eligibility: @bundle.eligibility)
  end
end
