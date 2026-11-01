# frozen_string_literal: true
require "test_helper"

class UnconfiguredFoundationTest < ActiveSupport::TestCase
  Reader = DecidimApp::Bijeljina::Milica::FoundationRead

  setup do
    @organization = create_organization
    @context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
      organization_id: @organization.id, conversation_key: "c" * 64, capabilities: ["public_reads"], now: Time.utc(2040, 4, 9, 12)
    )
  end

  test "without reviewed community metadata the reference has no facts or call status" do
    reader = Reader.new(organization: @organization, status_override: nil)
    [:identity, :contact, :funding, :apply].each do |facet|
      answer = reader.read_facet(facet:, context: @context, locale: "sr")
      assert_equal "unavailable", answer.fetch(:status)
      assert_includes answer.fetch(:warnings), "foundation_reference_not_configured"
      assert_empty answer.fetch(:facts, [])
      assert_nil answer[:source]
    end
    assert_equal "not_authorized", reader.read_facet(facet: :identity, context: nil, locale: "sr").fetch(:status)
  end

  test "unconfigured institutional reader does not create a review expiry reminder" do
    assert_empty DecidimApp::Bijeljina::ContentReviewReminders.call(organization: @organization, today: Date.new(2040, 4, 9))
  end

  test "explicit synthetic review does not turn an unverified call into available funding" do
    metadata = { "reviewed_on" => "2040-04-01", "reviewed_at" => "2040-04-01T12:00:00Z", "review_expires_on" => "2040-05-01",
                 "sources" => { "about" => { "id" => "synthetic:about", "url" => "https://community.example.invalid/about" },
                                "idea_call" => { "id" => "synthetic:call", "url" => "https://community.example.invalid/call", "current_open_status" => "unverified" } } }
    reader = Reader.new(organization: @organization, metadata:, status_override: nil)
    answer = reader.read_facet(facet: :funding, context: @context, locale: "sr")
    assert_equal "ok", answer.fetch(:status)
    assert_equal "unverified", answer.fetch(:validity).fetch("current_call_status")
    assert_nil answer.fetch(:validity).fetch("funds_available")
    assert_equal false, answer.fetch(:coverage).fetch("current_call_verified")
    assert_equal "https://community.example.invalid/call", answer.fetch(:source).fetch("url")
  end
end
