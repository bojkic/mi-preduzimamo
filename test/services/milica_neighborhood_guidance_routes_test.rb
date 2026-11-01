# frozen_string_literal: true

require "test_helper"

class MilicaNeighborhoodGuidanceRoutesTest < ActiveSupport::TestCase
  Dialogue = Decidim::Bih::Concierge::Dialogue

  setup do
    @organization = Decidim::Organization.first || create(:organization, available_locales: ["sr"], default_locale: "sr")
    @context = Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "a" * 64,
                                                       capabilities: ["public_reads"], now: Time.utc(2026, 9, 16, 6), deadline: Dialogue::TurnBudget.new)
    @tools = DecidimApp::Bijeljina::Milica::ConversationTools.new(organization: @organization, clock: -> { @context.now })
    @result = @tools.registry.call(name: "read_platform_guidance", arguments: { "subject" => "neighborhood" },
                                   context: @context, eligibility: @tools.eligibility)
    @envelope = @result.for_prompt(context: @context, eligibility: @tools.eligibility)
  end

  test "reviewed neighborhood routes use actual helpers and preserve authorization boundaries" do
    policy = @result.evidence.first.dig("facts", "source_fact", "policy")
    routes = Decidim::Bih::Engine.routes.url_helpers
    assert_equal({ "neighborhood_picker" => "https://#{@organization.host}#{routes.edit_komsiluk_path}",
                   "platform_guide" => "https://#{@organization.host}#{routes.onboarding_guide_path}",
                   "neighborhood_board" => "https://#{@organization.host}#{routes.komsiluk_board_index_path}",
                   "neighborhood_post_form" => "https://#{@organization.host}#{routes.komsiluk_board_index_path(anchor: "komsiluk-post-form")}" }, policy.fetch("public_routes"))
    assert_equal true, policy.fetch("neighborhood_picker_requires_authentication")
    assert_equal false, policy.fetch("opening_picker_changes_assignment")
    assert_equal false, policy.fetch("guide_requires_authentication")
    assert_equal true, policy.fetch("posting_requires_authorization")
    assert_match(/authenticated membership/, policy.fetch("private_board_visibility"))
  end

  test "both supported absolute and relative destinations pass the actual answer contract" do
    routes = @result.evidence.first.dig("facts", "source_fact", "policy", "public_routes")
    routes.each_value do |url|
      assert accepted?(url)
      assert accepted?(URI.parse(url).request_uri)
    end
  end

  test "invented neighborhood instructions and suffixed source paths are rejected" do
    ["/biceriseno/uputstva/komsiluk", "https://#{@organization.host}/biceriseno/uputstva/komsiluk",
     "#{Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path}/invented"].each do |url|
      assert_raises(Dialogue::Contracts::Invalid) { accepted?(url) }
    end
  end

  private

  def accepted?(url)
    payload = { "kind" => "answer", "answer" => "Otvori: #{url}", "evidence_ids" => [@result.evidence.first.fetch("id")] }
    Dialogue::AnswerContract.new.call(payload:, evidence: [@envelope], message: "Gdje biram komšiluk?", context: @context)
  end
end
