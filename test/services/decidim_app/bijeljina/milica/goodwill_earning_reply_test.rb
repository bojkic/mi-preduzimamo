# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # "Kako da zaradim bodove" through the REAL Responder#respond chain the
      # legacy read adapter uses (no classifier, keyword order). The answer must
      # come from the effective EarningRules schedule and reach anonymous chats.
      class GoodwillEarningReplyTest < ActiveSupport::TestCase
        Message = Struct.new(:text, :user, :image_url, :latitude, :longitude, keyword_init: true) do
          def initialize(text: nil, user: nil, image_url: nil, latitude: nil, longitude: nil)
            super
          end
        end

        class FakeDirectory
          def search(_query, **) = []
        end

        class FakeWaste
          def collection_days_for(_query) = nil
        end

        setup do
          @organization = create_organization
        end

        test "an anonymous citizen asking how to earn points gets the effective schedule and the rules link" do
          reply = respond("kako da zaradim bodove")
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)

          assert_equal "goodwill", reply.answer_intent
          assert_nil reply.report
          registration = rules.points_for(:verification) + rules.points_for(:komsiluk_selected)
          assert_includes reply.text, "#{I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: :sr)}: #{points(registration)}"
          assert_includes reply.text, "#{I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: :sr)}: #{points(rules.points_for(:volunteer_hour))}"
          assert reply.text.end_with?(I18n.t("decidim.bih.concierge.goodwill.earning.footer", locale: :sr, url: Decidim::Bih.public_path("zajednistvo?tab=kako")))
          assert_includes reply.text, "/biceriseno/zajednistvo?tab=kako"
          assert_not_includes reply.text, "poveži"
        end

        test "a per-organization schedule override changes the answer without any code change" do
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Goodwill::EarningRules::SCHEDULE_NAMESPACE, "volunteer_hour", 150)

          reply = respond("kako mogu da osvojim bodove")

          assert_includes reply.text, "#{I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: :sr)}: #{points(150)}"
        end

        test "an anonymous balance question gets sign-in guidance, never a zero and never the catalogue" do
          reply = respond("moji bodovi")

          assert_equal "goodwill", reply.answer_intent
          assert_includes reply.text, I18n.t("decidim.bih.concierge.goodwill.not_linked", locale: :sr,
                                                                                          url: Decidim::Bih::Engine.routes.url_helpers.wallet_path)
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", locale: :sr,
                                                                                     url: Decidim::Core::Engine.routes.url_helpers.new_user_session_path)
          assert_not_includes reply.text, "naljepnice"
        end

        # b4c01: eleven phrasings, one authenticated session, the same
        # 1.422-character reward catalogue every time — while the account held
        # 245 points. This drives the real Responder against the real ledger.
        test "a signed-in citizen is told the balance their own account page shows" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(user, 245, reason: "report")
          account = Decidim::Bih::Goodwill::Account.find_by(organization: @organization, owner_id: user.id, kind: "user")

          reply = respond("Koliko imam bodova?", user:)

          assert_equal "goodwill", reply.answer_intent
          assert_includes reply.text, account.balance.to_s
          assert_includes reply.text, I18n.t("decidim.bih.goodwill.levels.#{account.level.key}", locale: :sr)
          assert_includes reply.text, "##{Decidim::Bih::Goodwill::Account.rank_for(account)}"
          assert_not_includes reply.text, "naljepnice"
        end

        # "A read creates no ledger account, no award, no contribution and no
        # redemption" — asserted against the real tables, for a citizen who has
        # never earned anything and for an anonymous visitor.
        test "reading a balance writes nothing to the ledger" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          counts = lambda do
            [Decidim::Bih::Goodwill::Account.count, Decidim::Bih::Goodwill::Transaction.count,
             Decidim::Bih::Goodwill::RewardFulfillment.count]
          end
          before = counts.call

          ["Koliko imam bodova?", "moji bodovi", "Koji je moj rang?"].each { |text| respond(text, user:) }
          respond("koliko imam bodova")

          assert_equal before, counts.call
          assert_nil Decidim::Bih::Goodwill::Account.find_by(organization: @organization, owner_id: user.id, kind: "user")
        end

        test "a citizen with an account and no points is a genuine zero, not a missing account" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.account_for(user)

          reply = respond("moji bodovi", user:)

          assert_equal I18n.t("decidim.bih.concierge.goodwill.none", locale: :sr, url: Decidim::Bih::Engine.routes.url_helpers.wallet_path), reply.text
        end

        test "a citizen from another organization is told nothing about their points" do
          other = create_organization
          foreign = FactoryBot.create(:user, :confirmed, organization: other)
          Decidim::Bih::Goodwill::Ledger.new.award(foreign, 245, reason: "report")

          reply = respond("Koliko imam bodova?", user: foreign)

          assert_not_includes reply.text, "245"
          assert_includes reply.text, I18n.t("decidim.bih.dialogue.handoff_sign_in", locale: :sr,
                                                                                     url: Decidim::Core::Engine.routes.url_helpers.new_user_session_path)
        end

        # The proof the plan asked for: not that the route matched, but that
        # Responder#goodwill_reply is the code that RAN and produced the reply,
        # reached through the real Coordinator and the real secondary adapter,
        # with the understanding call forbidden.
        test "the balance reaches the goodwill handler through the coordinator without a model call" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(user, 245, reason: "report")
          executed = []
          responder = probed_responder(executed)
          dialogue = Decidim::Bih::Concierge::Dialogue
          coordinator = dialogue::Coordinator.new(
            understanding: ->(**) { raise "the understanding call must not be reached" },
            procedures: dialogue::ProcedureRunner.new(
              read_port: ->(**) { raise "no read port call for a secondary read" },
              registration_port: ->(**) { raise "no account operation" },
              destinations: { "report" => "/prijave/new", "account" => "/nalog", "neighborhood" => "/komsiluk", "support" => "/vodic" }
            ),
            state_store: dialogue::StateStore.new,
            runtime: dialogue::Coordinator::Runtime.new,
            legacy_secondary: dialogue::Coordinator::LegacyReadAdapter.new(responder:)
          )
          context = dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: SecureRandom.hex(32), actor_id: user.id,
            account_state: "verified", capabilities: %w(public_reads own_report_reads), now: Time.current
          )

          result = coordinator.call(message: message_for("Koliko imam bodova?", user:, context:), context:)

          assert_equal [:goodwill_reply], executed
          assert_equal "answered", result.resolution
          assert_equal "goodwill", result.reply.answer_intent
          assert_includes result.reply.text, "245"
        end

        test "a Cyrillic question is answered in Cyrillic with the same link" do
          reply = respond("како да зарадим бодове")

          assert_match(/\p{Cyrillic}/, reply.text)
          assert_includes reply.text, "zajednistvo?tab=kako"
          assert_includes reply.text, I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: :"sr-Cyrl")
        end

        # --- "what ARE the points" ---------------------------------------
        #
        # Measured on production on 14.09.2026 with the throttled chat client:
        # "Šta su bodovi zajedništva?" then "Ne tražim nagrade, nego
        # objašnjenje bodova." returned the rewards catalogue in 5 of 9 sends
        # and, in the other 4, the partner-organisation directory — carrying
        # the foundation's published donation account and IBAN. Points are
        # walled off from money; a donation account is not an answer to
        # "explain the points to me".
        EXPLANATION_PROMPTS = [
          "Šta su bodovi zajedništva?", "Ne tražim nagrade, nego objašnjenje bodova.",
          "Čemu služe bodovi?", "Objasni mi bodove.", "Kako funkcionišu bodovi zajedništva?"
        ].freeze

        test "a points explanation is answered from the effective schedule and the real rules page" do
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)
          registration = rules.points_for(:verification) + rules.points_for(:komsiluk_selected)

          EXPLANATION_PROMPTS.each do |prompt|
            reply = respond(prompt)

            assert_equal "goodwill", reply.answer_intent, prompt
            assert_nil reply.report, prompt
            assert_includes reply.text, "#{I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: :sr)}: #{points(registration)}", prompt
            assert_includes reply.text, I18n.t("decidim.bih.concierge.goodwill.earning.note", locale: :sr), prompt
            assert_includes reply.text, Decidim::Bih.public_path("zajednistvo?tab=kako"), prompt
            assert_not_includes reply.text, "naljepnice", prompt
            assert_no_match(/IBAN|\d{3}-\d{6,}/i, reply.text, prompt)
          end
        end

        # A citizen who HAS points and asks what they are wants the rules, not
        # their own number: before the explanation route existed the goodwill
        # keyword gate answered every one of these with the balance.
        test "a signed-in citizen asking what the points are gets the rules, not their balance" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(user, 245, reason: "report")

          reply = respond("Šta su bodovi zajedništva?", user:)

          assert_includes reply.text, I18n.t("decidim.bih.concierge.goodwill.earning.intro", locale: :sr)
          assert_not_includes reply.text, "245"
        end

        # The proof that matters: the model is never asked, and no catalogue or
        # directory read happens at all — both ports raise if they are reached.
        test "the points explanation reaches the goodwill handler through the coordinator without a model call" do
          executed = []
          responder = probed_responder(executed)
          dialogue = Decidim::Bih::Concierge::Dialogue
          coordinator = dialogue::Coordinator.new(
            understanding: ->(**) { raise "the understanding call must not be reached" },
            procedures: dialogue::ProcedureRunner.new(
              read_port: ->(**) { raise "no read port call for a points explanation" },
              registration_port: ->(**) { raise "no account operation" },
              destinations: { "report" => "/prijave/new", "account" => "/nalog", "neighborhood" => "/komsiluk", "support" => "/vodic" }
            ),
            state_store: dialogue::StateStore.new,
            runtime: dialogue::Coordinator::Runtime.new,
            legacy_secondary: dialogue::Coordinator::LegacyReadAdapter.new(responder:)
          )
          context = dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: SecureRandom.hex(32),
            account_state: "anonymous", capabilities: ["public_reads"], now: Time.current
          )

          EXPLANATION_PROMPTS.each do |prompt|
            executed.clear
            result = coordinator.call(message: message_for(prompt, user: nil, context:), context:)

            assert_equal [:goodwill_reply], executed, prompt
            assert_equal "answered", result.resolution, prompt
            assert_equal "goodwill", result.reply.answer_intent, prompt
            assert_includes result.reply.text, I18n.t("decidim.bih.concierge.goodwill.earning.intro", locale: :sr), prompt
          end
        end

        private

        def respond(text, user: nil)
          responder.respond(Message.new(text:, user:))
        end

        def responder
          Decidim::Bih::Concierge::Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new,
            goodwill_user_resolver: ->(message) { message.respond_to?(:user) ? message.user : nil }
          )
        end

        # Records the handler that ANSWERED, so reachability is observed rather
        # than inferred from the reply text.
        def probed_responder(executed)
          responder.tap do |instance|
            instance.define_singleton_method(:goodwill_reply) do |message|
              reply = super(message)
              executed << :goodwill_reply if reply
              reply
            end
            instance.singleton_class.send(:private, :goodwill_reply)
          end
        end

        def message_for(text, user:, context:)
          Decidim::Bih::Concierge::WebMessage.new(text, user:, trusted_context: context)
        end

        def points(count)
          I18n.t("decidim.bih.concierge.goodwill.earning.points", locale: :sr, count:)
        end
      end
    end
  end
end
