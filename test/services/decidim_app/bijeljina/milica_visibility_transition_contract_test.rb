# frozen_string_literal: true

require "test_helper"
require "capybara"

module DecidimApp
  module Bijeljina
    class MilicaVisibilityTransitionContractTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers
      Dialogue = Decidim::Bih::Concierge::Dialogue
      NOW = Time.utc(2026, 9, 9, 12)

      setup do
        travel_to NOW
        @organization = create_organization
        @port = Milica::ReadPort.new(organization: @organization)
        @runner = Dialogue::ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "Unexpected registration" },
                                                destinations: { account: "/nalog", report: "/prijavi", neighborhood: "/komsiluk", support: "/pomoc" })
      end

      teardown { travel_back }

      test "publishing hiding and expiring an opportunity changes repeated public reads and replaces retained discovery evidence" do
        opportunity = Decidim::Bih::VolunteerOpportunity.create!(organization: @organization, title: "Transition opportunity",
                                                                 description: "Public fixture description", active: false, review_status: "pending",
                                                                 starts_at: NOW - 10.minutes, ends_at: NOW + 1.minute)
        trusted = context(capabilities: ["public_reads"])
        assert_equal "empty", read(topic: "volunteer", trusted:).status

        opportunity.update!(active: true, review_status: "approved")
        shown = answer(topic: "volunteer", trusted:, message: "Volontiranje")
        identifier = "volunteer_opportunity:#{opportunity.id}"
        assert_equal [identifier], shown.fact_ids
        assert_includes shown.reply.text, opportunity.title
        assert_equal([identifier], shown.state.fetch("prior_evidence").fetch("facts").map { |fact| fact.fetch("id") })

        opportunity.update!(active: false)
        assert_equal "empty", read(topic: "volunteer", trusted:).status
        hidden = answer(topic: "volunteer", trusted:, state: shown.state, message: "Volontiranje")
        assert_empty hidden.fact_ids
        assert_nil hidden.state["prior_evidence"]
        assert_not_includes hidden.reply.text, opportunity.title

        opportunity.update!(active: true)
        reshown = answer(topic: "volunteer", trusted:, state: hidden.state, message: "Volontiranje")
        assert_equal [identifier], reshown.fact_ids
        travel_to NOW + 1.minute
        expired_context = trusted.with(now: Time.current)
        assert_equal "empty", read(topic: "volunteer", trusted: expired_context).status
        expired = answer(topic: "volunteer", trusted: expired_context, state: reshown.state, message: "Volontiranje")
        assert_empty expired.fact_ids
        assert_nil expired.state["prior_evidence"]
        assert_not_includes expired.reply.text, opportunity.title
      end

      test "revoked board membership blocks rereads and every retained evidence followup on the same adapter" do
        original = area("original")
        replacement = area("replacement")
        actor = FactoryBot.create(:user, :confirmed, organization: @organization)
        profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
        profile.assign_komsiluk!(original, source: "dropdown")
        post = Decidim::Bih::KomsilukPost.create!(organization: @organization, komsiluk: original, category: "general",
                                                  title: "Retained original board title", body: "Private original board fixture body")
        trusted = context(actor:, capabilities: %w(public_reads neighborhood_reads))
        shown = answer(action: "neighborhood_information", topic: "neighborhood", trusted:, message: "Objave iz mog komšiluka")
        assert_equal ["komsiluk_post:#{post.id}"], shown.fact_ids
        assert_equal "member_board", shown.state.fetch("prior_evidence").fetch("kind")
        assert_not_includes shown.state.fetch("prior_evidence").to_json, post.title

        # Changing the verified assignment revokes access to the old board even
        # though the caller's broad neighborhood-read capability is unchanged.
        profile.assign_komsiluk!(replacement, source: "dropdown")
        denied = read(action: "neighborhood_information", topic: "neighborhood", trusted:, entities: { "area_slug" => original.slug })
        assert_equal "not_authorized", denied.status
        assert_empty denied.facts
        %w(source date disagreement).each do |kind|
          result = @runner.prior_evidence_follow_up(kind:, state: shown.state.deep_dup, context: trusted, message: "Odakle ti to?")
          assert_equal "clarification", result.resolution, kind
          assert_empty result.fact_ids, kind
          assert_nil result.state["prior_evidence"], kind
          assert_not_includes result.reply.text, post.title, kind
          assert_not_includes result.reply.text, post.body, kind
          assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.prior_evidence_private_unavailable", locale: "sr"), kind
        end
      end

      private

      def context(capabilities:, actor: nil)
        Dialogue::Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "d" * 64,
                                                actor_id: actor&.id, account_state: actor ? "registered" : "anonymous",
                                                capabilities:, now: Time.current)
      end

      def read(topic:, trusted:, action: "ask_information", entities: {})
        @port.call(action:, topic:, entities:, context: trusted, locale: "sr")
      end

      def answer(topic:, trusted:, message:, action: "ask_information", state: nil)
        understanding = Dialogue::Contracts::Understanding.parse(action:, topic:, entities: {}, operation: state ? "continue" : "start",
                                                                 locale: "sr", needs_clarification: false, secondary: nil)
        @runner.call(understanding:, context: trusted, state: state || Dialogue::StateStore.new.empty_state(trusted), message:)
      end

      def area(name)
        Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "komsiluk-#{name}", name: { "sr" => name })
      end
    end
  end
end
