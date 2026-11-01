# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "active_support"
require "active_support/core_ext"
require "decidim/bih"
engine = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine, "app/services/decidim/bih/concierge/dialogue/coordinator")
require File.join(engine, "app/services/decidim/bih/concierge/web_message")
require_relative "../../../../../app/services/decidim_app/bijeljina/concierge"
require_relative "../../../../../app/services/decidim_app/bijeljina/web_concierge"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica_personality"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/report_conversation"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/channel_capability_reply"
require_relative "../../../../../app/services/decidim_app/bijeljina/milica/private_account_read"

# Pure Minitest contracts run without Rails boot, database or provider access.
# rubocop:disable Rails/RefuteMethods
class ChannelCapabilityReplyTest < Minitest::Test
  Helper = DecidimApp::Bijeljina::Milica::ChannelCapabilityReply
  Web = DecidimApp::Bijeljina::WebConcierge
  Native = DecidimApp::Bijeljina::Concierge
  Personality = DecidimApp::Bijeljina::MilicaPersonality
  Message = Struct.new(:text, :user, :trusted_context, :channel, keyword_init: true)
  Organization = Struct.new(:host, :id)

  CH05 = "Pišem iz Instagrama, vidiš li sada moj broj telefona i koliko imam bodova?"
  Context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext
  User = Struct.new(:id, :decidim_organization_id)

  def with_identity_locales
    prior = [I18n.backend, I18n.load_path, I18n.available_locales]
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = %w(sr sr-Cyrl bs hr en)
    root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
    I18n.load_path = %w(sr.yml sr-Cyrl.yml bs.yml hr.yml en.yml decidim_bih_dialogue.yml).map { |file| File.join(root, "config/locales", file) }
    I18n.with_locale(:sr) { yield }
  ensure
    I18n.backend, I18n.load_path, I18n.available_locales = prior
  end

  def identity_context(actor_id: nil, organization_id: 71)
    Context.new(organization_id:, actor_id:, conversation_key: "a" * 64, capabilities: %w(public_reads own_report_reads), now: Time.utc(2026, 9, 15, 10),
                deadline: Decidim::Bih::Concierge::Dialogue::TurnBudget.new(timeout: 9))
  end

  class PrivateReader < DecidimApp::Bijeljina::Milica::PrivateAccountRead
    attr_reader :reads

    def initialize(**)
      super
      @reads = []
    end

    private

    def balance(user)
      @reads << user.id
      "245 public-test points"
    end
  end

  def test_pure_identity_copy_distinguishes_link_from_channel_name_in_all_locales
    with_identity_locales do
      %w(sr sr-Cyrl bs hr en).each do |locale|
        I18n.with_locale(locale) do
          text = { "sr-Cyrl" => "Видиш ли мој број?", "en" => "Can you see my phone?" }.fetch(locale, CH05)
          answer = Helper.identity_reply(message: Message.new(text:), organization: Organization.new("mi.example.test", 71), linked: false)
          assert_includes answer.text, "https://mi.example.test/users/sign_in"
          refute_includes answer.text, "245"
          assert_nil answer.report
          assert_equal locale, answer.locale
        end
      end
    end
  end

  def test_private_reader_uses_only_same_tenant_actor_and_never_model_routing
    with_identity_locales do
      calls = []
      reader = PrivateReader.new(organization: Organization.new("mi.example.test", 71), actor_lookup: lambda { |id|
        calls << id
        User.new(id, 71)
      })
      anonymous = reader.call(kind: "balance", context: identity_context)
      assert_equal "not_authorized", anonymous.status
      assert_empty calls
      assert_empty reader.reads
      own = reader.call(kind: "balance", context: identity_context(actor_id: 5))
      assert_equal "ok", own.status
      assert_includes own.text, "245"
      assert_equal [5], calls
      assert_equal [5], reader.reads
      assert_raises(Decidim::Bih::Concierge::Dialogue::Contracts::Invalid) do
        reader.call(kind: "balance", context: identity_context(actor_id: 5, organization_id: 72))
      end
      assert_equal [5], reader.reads
    end
  end

  def test_private_reader_rejects_cross_actor_results_and_propagates_unavailable_without_zero
    with_identity_locales do
      [User.new(6, 71), User.new(5, 72), nil].each do |user|
        reader = PrivateReader.new(organization: Organization.new("mi.example.test", 71), actor_lookup: ->(_) { user })
        answer = reader.call(kind: "balance", context: identity_context(actor_id: 5))
        assert_equal "not_authorized", answer.status
        assert_empty reader.reads
        refute_includes answer.text, "245"
      end
      reader = PrivateReader.new(organization: Organization.new("mi.example.test", 71), actor_lookup: ->(_) { raise "synthetic DB failure" })
      assert_raises(RuntimeError) { reader.call(kind: "balance", context: identity_context(actor_id: 5)) }
      assert_empty reader.reads
    end
  end

  def test_public_permission_copy_needs_no_account_and_supports_multiple_scripts
    with_identity_locales do
      ["Ne želim dijeliti broj. Mogu li ipak pitati za autobus?",
       "Не желим дијелити број. Могу ли ипак питати за аутобус?",
       "I don't want to share my phone number. Can I still ask about buses?"].each do |text|
        assert Helper.public_transport_without_phone?(text)
        answer = Helper.public_transport_permission_reply(message: Message.new(text:))
        assert_equal "service", answer.answer_intent
        assert_nil answer.report
      end
      refute Helper.public_transport_without_phone?("Mogu li vidjeti bodove mog komšije?")
    end
  end

  def test_ordinary_web_channel_question_reaches_model_led_coordinator_without_identity_rewrite
    message = Message.new(text: CH05, trusted_context: identity_context, channel: "instagram")
    original = message.to_h
    reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "New coordinator answer", answer_intent: "service")
    coordinator = Object.new
    seen = []
    coordinator.define_singleton_method(:call) do |**arguments|
      seen << arguments
      Struct.new(:reply).new(reply)
    end
    Web.stub(:enabled_for?, true) do
      Web.stub(:coordinator_for, ->(**) { coordinator }) do
        answer, = Web.send(:route, message, context: message.trusted_context)
        assert_same reply, answer
      end
    end
    assert_equal original, message.to_h
    assert_equal 1, seen.size
    assert_same message.trusted_context, seen.first[:context]
  end

  def test_immediate_danger_precedes_public_model_and_cancellation_is_not_a_capability_answer
    text = "Gori mi kuća. Da li Milica radi na Messengeru?"
    assert_nil Helper.call(message: Message.new(text:), channel: "web_chat", organization: Organization.new("mi.example.test"))
    refute Helper.question?("Odustani. Da li Milica radi na Viberu?")
    emergency = Decidim::Bih::Concierge::Responder::Reply.new(text: "Pozovi 123.", answer_intent: "safety")
    Web.stub(:enabled_for?, false) do
      Web.stub(:immediate_control_reply, emergency) do
        Web.stub(:coordinator_for, ->(**) { flunk "Safety must precede model" }) do
          answer, outcome = Web.send(:route, Message.new(text:), context: nil)
          assert_same emergency, answer
          assert_equal "safety_guidance", outcome.resolution
        end
      end
    end
  end

  class EnvelopeRedis
    Store = DecidimApp::Bijeljina::Milica::ReportConversationStore
    def initialize = @data = {}

    def get(key) = @data[key]

    def eval(script, keys:, argv:)
      if script == Store::ACQUIRE
        return -1 if @data.has_key?(keys[1])
        return 0 if @data.has_key?(keys[0])

        @data[keys[0]] = argv[0]
        return 1
      end
      return 0 unless @data[keys.first] == argv.first

      case script
      when Store::RELEASE then @data.delete(keys.first)
      when Store::WRITE then @data[keys[1]] = argv[1]
                             1
      when Store::CLEAR then @data.delete(keys[1])
                             1
      else raise "Unexpected store operation"
      end
    end
  end

  def test_real_pending_report_envelope_is_invalidated_before_identity_topic_switch
    with_identity_locales do
      context = identity_context
      store = DecidimApp::Bijeljina::Milica::ReportConversationStore.new(redis: EnvelopeRedis.new,
                                                                         encryptor: ActiveSupport::MessageEncryptor.new("x" * 32, cipher: "aes-256-gcm", serializer: JSON))
      store.synchronize(context:) do |lease|
        store.write(context:, draft: { "code" => "abcdef123456", "expires_at" => context.now.to_f + 600 }, lease:)
      end
      assert_equal "abcdef123456", store.read(context:).fetch("code")
      submission = Object.new
      submission.define_singleton_method(:call) { |**| raise "No report submission" }
      flow = DecidimApp::Bijeljina::Milica::ReportConversation.new(store:, submission:)
      message = Message.new(text: CH05, trusted_context: context)
      reply, = flow.call(message:, context:) do
        assert_nil store.read(context:), "the old confirmation must expire before the new account answer"
        answer = Helper.identity_reply(message:, organization: Organization.new("mi.example.test", 71), linked: false)
        [answer, nil]
      end
      assert_includes reply.text, "nema potvrđenu vezu"
      assert_nil store.read(context:)
    end
  end

  def test_current_channel_comes_from_ingress_not_the_apps_named_in_prose
    organization = Organization.new("mi.example.test")
    message = Message.new(text: "Pišem iz Instagrama. Da li Milica radi na Viberu i Messengeru?")
    { "web_chat" => "web chat", "messenger" => "Messenger", "instagram" => "Instagram", "whatsapp" => "WhatsApp", "viber_bm" => "Viber" }.each do |channel, label|
      reply = Helper.call(message:, channel:, organization:)
      assert reply.text.start_with?("Ovaj razgovor: #{label}.")
      assert_includes reply.text, "https://mi.example.test#{Decidim::Bih.public_path("mi-bot")}"
      assert_includes reply.text, "Nemam potvrdu"
      assert_nil reply.report
      assert_empty reply.quick_replies
    end
  end

  def test_verification_followup_and_unseen_script_variants_are_answered_without_delivery_claims
    questions = {
      "Znači li to da ste već provjerili da poruke stižu i da Milica odgovara na svakom od tih kanala?" => "sr",
      "Да ли Милица ради на Виберу и Инстаграму?" => "sr-Cyrl",
      "Does Milica work on WhatsApp and Messenger?" => "en",
      "Have messages and replies been verified on every channel?" => "en"
    }
    questions.each do |text, locale|
      reply = Helper.call(message: Message.new(text:), channel: "web_chat", organization: Organization.new("mi.example.test"))
      assert reply, text
      assert_equal locale, reply.locale, text
      refute_match(/(?:svi kanali rade|all channels are live|сви канали раде)/i, reply.text)
    end
  end

  def test_normal_civic_tasks_exact_confirmation_and_feedback_are_not_channel_availability_questions
    ["Na WhatsAppu sam. Treba mi autobus od Janja do bolnice u Bijeljini.",
     "Pišem preko Facebook Messengera. Kako da prijavim rupu na putu?",
     "Pišem iz Instagrama, vidiš li sada moj broj telefona i koliko imam bodova?",
     "Pošalji prijavu abcdef123456", "Potvrdi prijavu na Instagramu", "Šta znači Nije korisno?"].each do |text|
      refute Helper.question?(text), text
    end
  end

  def test_native_ordinary_turn_delegates_to_model_led_dialogue_without_capability_prerouting
    message = Message.new(text: "Da li Milica radi na Messengeru?", channel: "viber_bm")
    reply = Decidim::Bih::Concierge::Responder::Reply.new(text: "Source-backed public channel answer", answer_intent: "service")
    Web.stub(:dialogue_turn, lambda { |message:, context:, **|
      assert_equal "viber_bm", message.channel
      assert_equal :trusted, context
      [reply, nil]
    }) do
      assert_equal [reply, nil], Native.send(:report_aware_turn, message, context: :trusted)
    end
  end

  def test_native_protected_prelude_keeps_priority_over_model_led_turn
    message = Message.new(text: "123456", channel: "viber")
    prelude = Decidim::Bih::Concierge::Responder::Reply.new(text: "Unesi kod.", answer_intent: "account_linking")
    Native.stub(:protected_prelude, prelude) do
      Web.stub(:dialogue_turn, ->(**) { flunk "native prelude owns this turn" }) do
        assert_same prelude, Native.respond(message)
      end
    end
  end
end
# rubocop:enable Rails/RefuteMethods
