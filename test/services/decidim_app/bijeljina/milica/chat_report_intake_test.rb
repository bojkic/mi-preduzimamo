# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      # The external-channel half of the report boundary: the scope a chat
      # sender gets, and the flow that scope runs through. The effect itself
      # (one durable report, one receipt) belongs to the engine's
      # ConfirmedReportSubmission and is proved by its own test; here the fake
      # submission counts calls, and the draft is additionally validated
      # against the real service's own draft contract.
      class ChatReportIntakeTest < ActiveSupport::TestCase
        Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
        Submitter = Decidim::Bih::Concierge::ConfirmedReportSubmission
        Receipt = Submitter::Receipt
        Store = ReportConversationStore
        Outcome = Data.define(:state, :resolution, :fact_ids)

        # Bounded in-memory stand-in for the Lua scripts the draft store runs.
        class RedisMemory
          attr_reader :data

          def initialize = @data = {}

          def get(key) = @data[key]

          def del(key) = @data.delete(key)

          def set(key, value, nx: false, **) # rubocop:disable Naming/MethodParameterName
            return false if nx && @data.has_key?(key)

            @data[key] = value
            true
          end

          def eval(script, keys:, argv:) # rubocop:disable Metrics/CyclomaticComplexity
            if script == Store::ACQUIRE
              return -1 if @data.has_key?(keys[1])

              return set(keys[0], argv[0], nx: true) ? 1 : 0
            end
            return 0 unless @data[keys.first] == argv.first
            return 0 if [Store::WRITE, Store::CLEAR].include?(script) && @data.has_key?(keys[2])

            case script
            when Store::RELEASE then @data.delete(keys.first)
            when Store::WRITE then @data[keys[1]] = argv[1]
                                   1
            when Store::CLEAR then @data.delete(keys[1])
                                   1
            else raise "Unexpected script"
            end
          end
        end

        class Submission
          attr_reader :calls

          def initialize = @calls = []

          def call(**arguments)
            @calls << arguments
            Receipt.new(reference: "BR-2099-0007", replayed: false)
          end

          def replay(**) = nil
        end

        setup do
          @organization = create_organization
          @previous_env = %w(MI_CHAT_REPORT_INTAKE_CHANNELS MILICA_REPORT_CHAT_SUBMISSION_ENABLED).index_with { |key| ENV.fetch(key, nil) }
          ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = "viber_bm,whatsapp,messenger,instagram"
          ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
          @redis = RedisMemory.new
          @submission = Submission.new
        end

        teardown do
          @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        end

        test "the channel flag is empty by default and admits only supported channels" do
          ENV.delete("MI_CHAT_REPORT_INTAKE_CHANNELS")
          assert_equal [], ChatReportIntake.channels
          ChatReportIntake::SUPPORTED_CHANNELS.each { |channel| assert_not ChatReportIntake.enabled?(channel) }

          ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = " Viber_BM , whatsapp,whatsapp , web_chat,,sms "
          assert_equal %w(viber_bm whatsapp), ChatReportIntake.channels
          assert ChatReportIntake.enabled?("viber_bm")
          assert_not ChatReportIntake.enabled?("messenger")
          assert_not ChatReportIntake.enabled?("web_chat")

          # The per-channel list only ADDS to the master switch.
          ENV.delete("MILICA_REPORT_CHAT_SUBMISSION_ENABLED")
          assert_equal %w(viber_bm whatsapp), ChatReportIntake.channels
          assert_not ChatReportIntake.enabled?("viber_bm")
        end

        test "a channel that is not listed has no trusted scope at all" do
          ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = "whatsapp"
          assert_not_nil context_for(channel: "whatsapp")
          ENV.delete("MILICA_REPORT_CHAT_SUBMISSION_ENABLED")
          assert_nil context_for(channel: "whatsapp"), "the master switch still governs every channel"
          ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
          assert_nil context_for(channel: "viber_bm")
          assert_nil context_for(channel: "instagram")
          assert_not_nil context_for(channel: "whatsapp")

          ENV.delete("MI_CHAT_REPORT_INTAKE_CHANNELS")
          ChatReportIntake::SUPPORTED_CHANNELS.each { |channel| assert_nil context_for(channel:) }
        end

        test "the external conversation key is a stable HMAC that never carries the sender" do
          key = ChatReportIntake.conversation_key(organization: @organization, channel: "viber_bm", sender: "38765123456")
          assert_match(/\A[a-f0-9]{64}\z/, key)
          assert_equal key, ChatReportIntake.conversation_key(organization: @organization, channel: "viber_bm", sender: "38765123456")
          assert_not_includes key, "38765123456"

          other_sender = ChatReportIntake.conversation_key(organization: @organization, channel: "viber_bm", sender: "38765123457")
          other_channel = ChatReportIntake.conversation_key(organization: @organization, channel: "whatsapp", sender: "38765123456")
          other_organization = ChatReportIntake.conversation_key(organization: create_organization, channel: "viber_bm", sender: "38765123456")
          assert_equal 4, [key, other_sender, other_channel, other_organization].uniq.size
        end

        test "an external scope is anonymous and cannot write until the exact confirmation" do
          context = context_for
          assert_nil context.actor_id
          assert_equal "anonymous", context.account_state
          assert_not context.allows?("write_report")
          assert context.allows?("report_guidance")
          assert_equal @organization.id, context.organization_id
        end

        test "a bare message never creates a report on any external channel" do
          ChatReportIntake::SUPPORTED_CHANNELS.each do |channel|
            context = context_for(channel:)
            ["Ima ogromna rupa u Ulici Svetog Save 12", "posalji prijavu", "da", "Pošalji prijavu 000000000000"].each do |text|
              turn(text, context:) { [plain, report_outcome] }
            end
            assert_empty @submission.calls, "channel #{channel} filed a report without an exact confirmation"
          end
        end

        test "the preview prints the exact phrase to reply with instead of a button" do
          context = context_for
          preview = turn("Ima ogromna rupa u Ulici Svetog Save 12", context:) { [plain, report_outcome] }
          command = preview.quick_replies.first.fetch(:send)

          assert_equal "Potvrdi prijavu DA", command
          assert_includes preview.text, command
          assert_includes preview.text, I18n.t("bijeljina.milica_report.location_notice", locale: "sr")
          assert_includes preview.text, I18n.t("bijeljina.milica_report.anonymous_notice", locale: "sr")
          assert_not_includes preview.text, I18n.t("bijeljina.milica_report.confirm_button", locale: "sr")
          labels = preview.quick_replies.map { |chip| chip.fetch(:label) }
          assert_equal [command, "odustani"], labels
          assert_equal labels, preview.quick_replies.map { |chip| chip.fetch(:send) },
                       "on a channel the label is what the citizen retypes"
        end

        test "the typed preview is complete in every supported locale" do
          %w(sr sr-Cyrl bs hr en).each do |locale|
            context = context_for(sender: "3876500#{locale.bytes.sum}")
            preview = turn("prijava", context:) { [plain, report_outcome(locale:)] }
            assert_not_includes preview.text, "translation missing"
            assert_includes preview.text, preview.quick_replies.first.fetch(:send)
            assert_includes preview.text, I18n.t("bijeljina.milica_report.location_notice", locale:)
            assert_equal I18n.t("bijeljina.milica_report.cancel_command", locale:), preview.quick_replies.last.fetch(:send)
          end
        end

        test "an exact confirmation submits once, returns the reference and stays idempotent" do
          context = context_for
          command = turn("Ima ogromna rupa u Ulici Svetog Save 12", context:) { [plain, report_outcome] }.quick_replies.first.fetch(:send)
          draft = store.read(context:)

          receipt = turn(command, context:) { flunk "an exact confirmation must not reach the model" }
          assert_includes receipt.text, "BR-2099-0007"
          assert_equal 1, @submission.calls.size
          assert @submission.calls.sole.fetch(:context).allows?("write_report")
          assert_nil @submission.calls.sole.fetch(:author), "a chat report is anonymous"

          repeated = turn(command, context:) { flunk }
          assert_equal receipt.text, repeated.text
          assert_equal 1, @submission.calls.size, "a repeated confirmation must create nothing new"
          assert_equal true, @last_outcome.replayed

          # The stored draft is acceptable to the real durable service.
          confirmed = context.with(capabilities: context.capabilities + ["write_report"])
          validated = Submitter.new.send(:validated_draft, confirmed, draft, nil)
          assert_equal Submitter::DRAFT_KEYS.sort, validated.keys.sort
          assert_equal context.conversation_key, validated.fetch("conversation_key")
          assert_nil validated.fetch("actor_id")
        end

        test "the short confirmation works only for the sender with a live preview" do
          mine = context_for(sender: "38765111111")
          theirs = context_for(sender: "38765222222")
          command = turn("Ima ogromna rupa u Ulici Svetog Save 12", context: mine) { [plain, report_outcome] }.quick_replies.first.fetch(:send)

          assert_equal "Potvrdi prijavu DA", command
          assert_includes turn(command, context: theirs) { flunk }.text, I18n.t("bijeljina.milica_report.expired", locale: "sr")
          assert_empty @submission.calls
          assert_includes turn("Potvrdi prijavu", context: mine) { flunk }.text, "BR-2099-0007"
          assert_equal 1, @submission.calls.size
        end

        test "a wrong confirmation code refuses and submits nothing" do
          context = context_for
          turn("Ima ogromna rupa u Ulici Svetog Save 12", context:) { [plain, report_outcome] }
          refusal = turn("Pošalji prijavu #{"a" * 12}", context:) { flunk "a wrong code must not reach the model" }
          assert_includes refusal.text, I18n.t("bijeljina.milica_report.expired", locale: "sr")
          assert_empty @submission.calls
          assert_not_nil store.read(context:), "a wrong code must not destroy the citizen's own draft"
        end

        test "an expired preview refuses and says so" do
          context = context_for
          command = turn("Ima ogromna rupa u Ulici Svetog Save 12", context:) { [plain, report_outcome] }.quick_replies.first.fetch(:send)
          later = context.with(now: context.now + Store::TTL + 1)
          assert_nil store.read(context: later)
          refusal = turn(command, context: later) { flunk }
          assert_includes refusal.text, I18n.t("bijeljina.milica_report.expired", locale: "sr")
          assert_empty @submission.calls
        end

        test "odustani clears the draft and the old confirmation stops working" do
          context = context_for
          command = turn("Ima ogromna rupa u Ulici Svetog Save 12", context:) { [plain, report_outcome] }.quick_replies.first.fetch(:send)
          turn("odustani", context:) { [plain, nil] }
          assert_nil store.read(context:)
          assert_includes turn(command, context:) { flunk }.text, I18n.t("bijeljina.milica_report.expired", locale: "sr")
          assert_empty @submission.calls
        end

        test "two senders on one channel never reach each other's draft" do
          mine = context_for(sender: "38765111111")
          theirs = context_for(sender: "38765222222")
          command = turn("Ima ogromna rupa u Ulici Svetog Save 12", context: mine) { [plain, report_outcome] }.quick_replies.first.fetch(:send)

          assert_nil store.read(context: theirs)
          assert_includes turn(command, context: theirs) { flunk }.text, I18n.t("bijeljina.milica_report.expired", locale: "sr")
          assert_empty @submission.calls
          assert_not_nil store.read(context: mine)
        end

        test "one sender keeps independent drafts on two channels" do
          viber = context_for(channel: "viber_bm", sender: "38765123456")
          whatsapp = context_for(channel: "whatsapp", sender: "38765123456")
          viber_command = turn("Rupa u Ulici Svetog Save 12", context: viber) { [plain, report_outcome] }.quick_replies.first.fetch(:send)
          whatsapp_command = turn("Pokvarena lampa u Ulici Nikole Tesle 3", context: whatsapp) do
            [plain, report_outcome(description: "Pokvarena lampa")]
          end.quick_replies.first.fetch(:send)

          assert_equal "Potvrdi prijavu DA", viber_command
          assert_equal viber_command, whatsapp_command
          turn(whatsapp_command, context: whatsapp) { flunk }
          assert_equal "Pokvarena lampa", @submission.calls.sole.fetch(:draft).fetch("description")
          assert_not_nil store.read(context: viber), "the other channel's draft is untouched"
          turn(viber_command, context: viber) { flunk }
          assert_equal 2, @submission.calls.size
          assert_not_equal @submission.calls.first.fetch(:draft).fetch("conversation_key"),
                           @submission.calls.last.fetch(:draft).fetch("conversation_key")
        end

        test "the effect boundary follows both the master switch and the channel list" do
          adapter = DecidimApp::Bijeljina::WebConcierge
          previous = ENV.fetch("MILICA_REPORT_CHAT_SUBMISSION_ENABLED", nil)
          message = Decidim::Bih::Concierge::WebMessage.new("prijava")
          context = context_for
          adapter.stub(:enabled_for?, true) do
            ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = "true"
            ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = "viber_bm"
            assert adapter.send(:report_submission_enabled?, message, context:, channel: "web_chat")
            assert adapter.send(:report_submission_enabled?, message, context:, channel: "viber_bm")
            %w(whatsapp messenger instagram viber).each do |channel|
              assert_not adapter.send(:report_submission_enabled?, message, context:, channel:)
            end

            ENV.delete("MI_CHAT_REPORT_INTAKE_CHANNELS")
            assert adapter.send(:report_submission_enabled?, message, context:, channel: "web_chat")
            %w(viber_bm whatsapp messenger instagram).each do |channel|
              assert_not adapter.send(:report_submission_enabled?, message, context:, channel:)
            end

            ENV.delete("MILICA_REPORT_CHAT_SUBMISSION_ENABLED")
            ENV["MI_CHAT_REPORT_INTAKE_CHANNELS"] = "viber_bm"
            assert_not adapter.send(:report_submission_enabled?, message, context:, channel: "viber_bm")
          end
        ensure
          previous.nil? ? ENV.delete("MILICA_REPORT_CHAT_SUBMISSION_ENABLED") : ENV["MILICA_REPORT_CHAT_SUBMISSION_ENABLED"] = previous
        end

        private

        def context_for(channel: "viber_bm", sender: "38765123456", now: Time.current)
          ChatReportIntake.context(organization: @organization, channel:, sender:, now:)
        end

        def store
          @store ||= Store.new(
            redis: @redis,
            encryptor: ActiveSupport::MessageEncryptor.new("x" * 32, cipher: "aes-256-gcm", serializer: JSON)
          )
        end

        def flow
          ReportConversation.new(store:, submission: @submission, state_store: state_store, typed_confirmation: true)
        end

        def state_store
          @state_store ||= begin
            double = Object.new
            double.define_singleton_method(:read) do |context:|
              { "active_task" => "report_problem", "version" => 1, "locale" => "sr",
                "created_at" => context.now.to_f, "suspended_task" => nil }
            end
            double.define_singleton_method(:empty_state) { |_context| { "active_task" => nil } }
            double.define_singleton_method(:write) { |**| :saved }
            double
          end
        end

        def plain = Decidim::Bih::Concierge::Responder::Reply.new(text: "obican odgovor", report: nil, answer_intent: "service")

        def report_outcome(description: "Ogromna rupa na kolovozu", address: "Ulica Svetog Save 12", locale: "sr")
          Outcome.new(
            state: { "version" => 0, "active_task" => "report_problem", "pending_slot" => nil,
                     "report_handoff_offered" => true, "locale" => locale,
                     "entities" => { "description" => description, "address" => address }.compact },
            resolution: "handoff", fact_ids: []
          )
        end

        def turn(text, context:, &)
          reply, @last_outcome = flow.call(message: Decidim::Bih::Concierge::WebMessage.new(text), context:, &)
          reply
        end
      end
    end
  end
end
