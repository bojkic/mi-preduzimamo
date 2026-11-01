# frozen_string_literal: true

# Standalone Minitest does not provide Rails assert_not aliases.
# rubocop:disable Rails/RefuteMethods

require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/slice"
require "active_support/core_ext/string/exclude"
require "i18n"

engine_root = Gem.loaded_specs.fetch("decidim-bih").full_gem_path
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/state_store")
require File.join(engine_root, "app/services/decidim/bih/concierge/dialogue/coordinator")
require File.join(engine_root, "app/controllers/concerns/decidim/bih/completes_phone_authentication")
require File.join(engine_root, "app/controllers/concerns/decidim/bih/concierge/web_registration_resume")
require_relative "../../app/services/decidim_app/bijeljina/milica/registration_handoff"
require_relative "../../app/controllers/concerns/decidim_app/milica_registration_auth_return"

# Load the real model when the Rails runner loads this contract before other tests.
# Direct standalone Ruby execution still uses the minimal user double.
require "test_helper" if defined?(Rails::TestUnit::Runner)
Decidim.const_set(:User, Class.new) unless defined?(Decidim::User)

class MilicaRegistrationHandoffTest < Minitest::Test
  Dialogue = Decidim::Bih::Concierge::Dialogue
  Contracts = Decidim::Bih::Concierge::Dialogue::Contracts
  Semantic = Decidim::Bih::Concierge::Dialogue::StateStore
  Store = DecidimApp::Bijeljina::Milica::RegistrationHandoffStore
  Bridge = DecidimApp::Bijeljina::Milica::RegistrationHandoff
  Port = DecidimApp::Bijeljina::Milica::RegistrationPort
  Organization = Data.define(:id, :host)
  Reply = Struct.new(:text, keyword_init: true)

  class RedisMemory
    attr_reader :data
    attr_accessor :before_eval

    def initialize = @data = {}

    def get(key) = @data[key]

    def del(key) = @data.delete(key) ? 1 : 0

    def eval(script, keys:, argv:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      callback = @before_eval
      @before_eval = nil
      callback&.call(script, keys)
      case script
      when Semantic::WRITE_SCRIPT
        current = @data[keys[0]] ? JSON.parse(@data[keys[0]]).fetch("version") : 0
        return 0 unless current == argv[0]

        @data[keys[0]] = argv[1]
      when Store::ISSUE
        return 0 if @data[keys[1]]

        @data[keys[0]] = argv[0]
      when Store::REPLACE, Store::CLAIM
        return 0 if @data[keys[1]] || @data[keys[0]] != argv[0]

        source = JSON.parse(@data[keys[2]] || "{}")
        expected = script == Store::REPLACE ? argv[2] : argv[1]
        return 0 unless source["version"] == expected

        if script == Store::REPLACE
          @data[keys[0]] = argv[1]
        else
          @data[keys[1]] = "1"
          @data.delete(keys[0])
        end
      when Store::REVOKE
        @data[keys[1]] = "1"
        @data.delete(keys[0])
      else raise "Unexpected test script"
      end
      1
    end
  end

  # Use the integrated engine key contract, not a test-only delegation.
  SemanticWithRevision = Semantic

  class PhoneController
    include Decidim::Bih::CompletesPhoneAuthentication
    prepend DecidimApp::MilicaRegistrationAuthReturn::Phone
    attr_reader :session, :current_user, :destination, :current_organization

    def initialize(session:, organization:)
      @session = session
      @current_organization = organization
    end

    def user_signed_in? = !current_user.nil?

    def reset_session = @session = {}

    def sign_in(_scope, user) = @current_user = user

    def flash = @flash ||= {}

    def t(_key) = "Existing authentication notice"

    def redirect_to(path) = @destination = path
  end

  # Real return/authentication methods, with only request/session dependencies
  # injected. This does not claim a real browser, user authentication or Redis.
  class ReturningController < PhoneController
    include Decidim::Bih::Concierge::WebRegistrationResume
    attr_accessor :dialogue_context, :semantic_store, :handoff_bridge

    private

    def current_organization_user = current_user

    def trusted_dialogue_context = dialogue_context

    def registration_dialogue_store = semantic_store

    def registration_handoff_bridge = handoff_bridge

    def registration_resume_failure(error) = raise error
  end

  class InlineRuntime
    def call
      Dialogue::AdmissionControl::Result.new(status: :admitted, value: yield(Dialogue::TurnBudget.new(timeout: 10)))
    end
  end

  def setup
    @now = Time.now.utc
    @organization = Organization.new(id: 71, host: "synthetic.example")
    @secret = "synthetic-browser-secret"
    @browser_id = "a" * 32
    @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: OpenSSL::HMAC.hexdigest("SHA256", @secret, @browser_id), now: @now)
    @redis = RedisMemory.new
    @semantic = SemanticWithRevision.new(redis: @redis)
    @revoked_origins = []
    revoked_origins = @revoked_origins
    @report_store = Object.new
    @report_store.define_singleton_method(:revoke) do |context:|
      revoked_origins << context
      1
    end
    @store = Store.new(redis: @redis, state_store: @semantic, report_store: @report_store, clock: -> { @now },
                       encryptor: ActiveSupport::MessageEncryptor.new("x" * 32, cipher: "aes-256-gcm", serializer: JSON))
    @port = Port.new(organization: @organization)
    @bridge = Bridge.new(organization: @organization, store: @store, port: @port)
    @state = committed_state
    @user = user(11)
  end

  def test_real_authentication_is_required_and_successful_claim_is_single_use
    ticket = issue
    refute_includes @redis.data.values.last, "Synthetic report description"
    refute_includes ticket.entry.to_s, "Synthetic report description"
    assert_nil @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
    assert_nil @store.start(entry: ticket.entry, context: @context.with(conversation_key: "f" * 64))
    assert_equal "/users/sign_in", @store.start(entry: ticket.entry, context: @context)
    assert @store.authenticated(entry: ticket.entry, user: @user, organization_id: 71)
    task = @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
    assert_equal "report_problem", task.fetch("active_task")
    assert_equal "Synthetic report description", task.fetch("entities").fetch("description")
    refute task.fetch("entities").has_key?("area_slug")
    assert_nil task.fetch("draft")
    refute task.fetch("report_handoff_offered")
    assert_equal Semantic::TASK_KEYS.sort, task.keys.sort
    assert task.frozen?
    assert_equal [@context.organization_id, @context.actor_id, @context.conversation_key],
                 [@revoked_origins.first.organization_id, @revoked_origins.first.actor_id, @revoked_origins.first.conversation_key]
    assert_nil @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
    assert_nil issue # Successful consumption atomically tombstones old scope.
  end

  def test_wrong_tenant_account_and_unstarted_return_are_rejected
    ticket = issue
    refute @store.authenticated(entry: ticket.entry, user: @user, organization_id: 71)
    assert_nil @store.start(entry: ticket.entry.merge("token" => "0" * 48), context: @context)
    @store.start(entry: ticket.entry, context: @context)
    refute @store.authenticated(entry: ticket.entry, user: user(11, organization_id: 72), organization_id: 72)
    assert @store.authenticated(entry: ticket.entry, user: @user, organization_id: 71)
    refute @store.authenticated(entry: ticket.entry, user: user(12), organization_id: 71)
    assert_nil @store.consume(entry: ticket.entry, context: @context.with(actor_id: 12), user: user(12))
    assert_nil @store.consume(entry: ticket.entry, context: authenticated_context.with(organization_id: 72), user: @user)
    assert @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
  end

  def test_existing_actor_verification_cannot_be_completed_by_another_account
    @redis.data.clear
    @context = @context.with(actor_id: @user.id, account_state: "unverified")
    @state = committed_state
    ticket = issue
    @store.start(entry: ticket.entry, context: @context)
    refute @store.authenticated(entry: ticket.entry, user: user(12), organization_id: 71)
    refute @store.authenticated(entry: ticket.entry, user: Object.new, organization_id: 71)
    assert @store.authenticated(entry: ticket.entry, user: @user, organization_id: 71)
    assert @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
  end

  def test_expiry_revocation_and_same_version_content_change_refuse_resume
    ticket = issue
    @now += Store::TTL + 1
    assert_nil @store.start(entry: ticket.entry, context: @context)
    @now -= Store::TTL + 1
    @store.revoke(context: @context)
    assert_nil @store.start(entry: ticket.entry, context: @context)
    assert_nil issue

    @redis.data.clear
    @state = committed_state
    ticket = issue
    key = @semantic.revision_key(context: @context)
    changed = JSON.parse(@redis.data.fetch(key))
    changed.fetch("suspended_task").fetch("entities")["description"] = "Changed synthetic report"
    @redis.data[key] = JSON.generate(changed)
    assert_nil @store.start(entry: ticket.entry, context: @context)
  end

  def test_revision_race_at_claim_refuses_stale_task
    ticket = issue
    @store.start(entry: ticket.entry, context: @context)
    @store.authenticated(entry: ticket.entry, user: @user, organization_id: 71)
    @redis.before_eval = lambda do |script, keys|
      assert_equal Store::CLAIM, script
      changed = JSON.parse(@redis.data.fetch(keys[2]))
      changed["version"] += 1
      @redis.data[keys[2]] = JSON.generate(changed)
    end
    assert_nil @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
  end

  def test_precommit_state_and_registration_without_a_resumable_task_are_not_offered
    assert_nil @store.issue(context: @context, state: @state.merge("version" => 0), destination: "/users/sign_in")
    @redis.data.clear
    @state = committed_state(suspended: false)
    assert_nil issue
  end

  def test_prepare_keeps_token_only_in_session_and_preserves_reply_outcome
    previous_backend = I18n.backend
    previous_available = I18n.available_locales
    I18n.available_locales = %w(sr en)
    I18n.backend = I18n::Backend::Simple.new
    I18n.backend.send(:init_translations)
    I18n.backend.store_translations(:sr, decidim: { bih: { dialogue: { resume_manual: "Old manual instruction" } } })
    original = Reply.new(text: "Continue: /users/sign_in\n\nOld manual instruction\n\nOther instruction")
    original.define_singleton_method(:dialogue_outcome) { :preserved }
    session = { decidim_bih_web_chat_id: @browser_id }
    result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "sign_in", destination: "/users/sign_in")
    answer = @port.stub(:call, result) { @bridge.prepare(reply: original, action: "sign_in", context: @context, state: @state, session:) }
    assert_equal :preserved, answer.dialogue_outcome
    assert_includes answer.text, Port::WEB_HANDOFF_PATH
    refute_includes answer.text, "Old manual instruction"
    assert_includes answer.text, "Other instruction"
    assert_includes original.text, "/users/sign_in"
    entry = session.fetch(Bridge::SESSION_KEY)
    refute_includes answer.text, entry.fetch("token")
    assert_equal "/users/sign_in", @bridge.start(session:, user: nil, secret: @secret)
    assert_nil @bridge.consume(session:, context: authenticated_context, user: @user)
    assert_equal entry, session.fetch(Bridge::SESSION_KEY) # Not authenticated yet.
  ensure
    I18n.backend = previous_backend
    I18n.available_locales = previous_available
  end

  # LAUNCH-CRITICAL. A "register" answer must name the host's configured
  # registration path and nothing else.
  #
  # The browser return ticket is a ten-minute, one-session indirection. When it
  # is gone — a later tap, a second device, the address copied out of the chat
  # — the handoff controller resolves the destination from the account, and an
  # anonymous visitor has none, so it offers /users/sign_in. A brand-new
  # citizen who was told "hajde da otvorimo nalog" then lands on the LOGIN
  # form. Verified on production on 14.09.2026: /milica/prijava answered 302 to
  # /users/sign_in while /registracija answered 200.
  def test_a_register_answer_names_the_configured_registration_path
    ["/registracija", "/pridruzi-se"].each do |configured|
      with_registration_path(configured) do
        backend = Port::Backend.new(organization: @organization)

        # Read from the setting, never typed: a host that moves
        # Decidim::Bih.registration_path moves this answer with it.
        assert_equal configured, backend.registration_destination

        result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register",
                                              destination: backend.registration_destination)
        reply_text = "Hajde da otvorimo nalog — traje minut: #{configured}"
        prepared = @port.stub(:call, result) do
          @port.prepare_web_handoff(action: "registration", context: @context, state: @state,
                                    reply_text:, store: @store)
        end

        assert_nil prepared, "a citizen with no account must never be handed #{Port::WEB_HANDOFF_PATH}"
        assert_empty @redis.data.keys.grep(/\A#{Regexp.escape(Store::PREFIX)}/), "a register answer issues no return ticket"
      end
    end
  end

  # The other half of the same rule: a citizen who HAS an account is exactly
  # the case the controller's recovery resolves correctly, so verify and
  # sign-in keep the ticket.
  def test_an_account_holders_next_step_still_uses_the_browser_return_ticket
    %w(verify sign_in).each do |next_step|
      result = Contracts::HandoffResult.new(account_state: "registered", next_step:, destination: "/mi/verifikacija")
      prepared = @port.stub(:call, result) do
        @port.prepare_web_handoff(action: "verification", context: @context, state: @state,
                                  reply_text: "Nastavi ovdje: /mi/verifikacija", store: @store)
      end

      refute_nil prepared, next_step
      assert_equal Port::WEB_HANDOFF_PATH, prepared.handoff.destination, next_step
      assert_equal "/mi/verifikacija", prepared.original_destination, next_step
    end
  end

  def test_anonymous_own_report_read_offers_sign_in_and_resumes_the_same_read
    candidate = @state.merge("active_task" => "report_status", "topic" => "report", "suspended_task" => @state.slice(*Semantic::TASK_KEYS),
                             "entities" => { "query" => "Moje prijave" }, "entity_provenance" => { "query" => "citizen" })
    assert_equal :saved, @semantic.write(context: @context, state: candidate, expected_version: candidate["version"])
    state = @semantic.read(context: @context)
    backend = lambda do |**args|
      assert_equal "sign_in", args.fetch(:action)
      Contracts::HandoffResult.new(account_state: "anonymous", next_step: "sign_in", destination: "/users/sign_in")
    end
    prepared = @port.stub(:call, backend) do
      @port.prepare_web_handoff(action: "report_status", context: @context, state:, reply_text: "/users/sign_in", store: @store)
    end
    assert_equal Port::WEB_HANDOFF_PATH, prepared.handoff.destination
    assert_equal "/users/sign_in", @store.start(entry: prepared.ticket, context: @context)
    assert @store.authenticated(entry: prepared.ticket, user: @user, organization_id: 71)
    task = @store.consume(entry: prepared.ticket, context: authenticated_context, user: @user)
    assert_equal "report_status", task.fetch("active_task")
    assert_equal "Moje prijave", task.fetch("entities").fetch("query")
  end

  def test_supported_active_or_suspended_report_is_not_reordered_and_draft_authority_is_not_carried
    report = @state.fetch("suspended_task").merge("draft" => { "reference" => "opaque_fixture_123", "revision" => 2, "expires_at" => @now.to_f + 60 })
    active_report = @state.merge(report).merge("suspended_task" => nil)
    own_read_with_report = @state.merge("active_task" => "report_status", "topic" => "report", "suspended_task" => report,
                                        "entities" => { "query" => "Moje prijave" }, "entity_provenance" => { "query" => "citizen" })
    [active_report, @state.merge("suspended_task" => report), own_read_with_report].each do |candidate|
      before = Marshal.load(Marshal.dump(candidate))
      selected = @store.send(:resumable_task, candidate, context: @context)
      assert_equal "report_problem", selected.fetch("active_task")
      assert_equal "Synthetic report description", selected.fetch("entities").fetch("description")
      assert_nil selected.fetch("draft")
      refute selected.fetch("report_handoff_offered")
      refute selected.fetch("entities").has_key?("area_slug")
      assert_equal before, candidate
    end
  end

  def test_nonresumable_suspension_fallback_requires_explicit_own_read_without_reference_or_draft
    candidate = @state.merge("active_task" => "report_status", "topic" => "report", "suspended_task" => @state.slice(*Semantic::TASK_KEYS),
                             "entities" => { "query" => "Moje prijave" }, "entity_provenance" => { "query" => "citizen" })
    draft = { "reference" => "opaque_fixture_123", "revision" => 2, "expires_at" => @now.to_f + 60 }
    invalid = [
      candidate.merge("entities" => { "query" => "Moje prijave i prijave komšije" }),
      candidate.merge("entity_provenance" => { "query" => "trusted_profile" }),
      candidate.merge("entities" => { "query" => "Moje prijave", "reference" => "BR-2026-9999" },
                      "entity_provenance" => { "query" => "citizen", "reference" => "citizen" }),
      candidate.merge("draft" => draft),
      candidate.merge("suspended_task" => candidate.fetch("suspended_task").merge("draft" => draft)),
      candidate.merge("active_task" => "ask_information", "topic" => "parking")
    ]
    invalid.each do |state|
      before = Marshal.load(Marshal.dump(state))
      assert_nil @store.send(:resumable_task, state, context: @context)
      assert_equal before, state
    end
  end

  def test_actual_phone_completion_preserves_only_ticket_after_grant_and_keeps_redirect
    ticket = issue
    @store.start(entry: ticket.entry, context: @context)
    session = { Bridge::SESSION_KEY => ticket.entry, :decidim_bih_web_chat_id => @browser_id, :unrelated => "must not survive reset" }
    controller = PhoneController.new(session:, organization: @organization)
    Bridge.stub(:new, @bridge) do
      refute controller.complete_phone_authentication(user: @user, purpose: "verify", grant: -> { false }, destination: "/required-onboarding")
      refute controller.user_signed_in?
      assert_nil @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
      assert controller.complete_phone_authentication(user: @user, purpose: "verify", grant: -> { true }, consume: -> { true }, destination: "/required-onboarding")
    end
    assert_equal "/required-onboarding?app=1", controller.destination
    assert_equal [Bridge::SESSION_KEY], controller.session.keys
    assert_equal @user, controller.current_user
    assert @bridge.consume(session: controller.session, context: authenticated_context, user: @user)
    assert_empty controller.session
    assert_equal @context.conversation_key, @revoked_origins.fetch(0).conversation_key
    assert_nil @revoked_origins.fetch(0).actor_id
  end

  def test_authenticated_return_restores_fresh_scope_and_nastavi_dispatches_a_bound_own_read
    controller = complete_own_report_authentication(suspended_auth: true)
    task = controller.send(:registration_resume_for, "nastavi")
    assert_equal "report_status", task.fetch("active_task")
    assert_equal :saved, controller.send(:restore_registration_task, task, message: "nastavi")
    restored = @semantic.read(context: controller.dialogue_context)
    assert_equal 1, restored.fetch("version")
    assert_equal "Moje prijave", restored.fetch("entities").fetch("query")
    %w(draft suspended_task prior_evidence).each { |key| assert_nil restored.fetch(key) }
    refute restored.fetch("report_handoff_offered")
    assert_empty controller.session
    assert_nil controller.send(:registration_resume_for, "nastavi")
    assert_equal 1, @revoked_origins.length

    reads = []
    runner = Dialogue::ProcedureRunner.new(
      read_port: lambda { |**args|
        reads << args
        Contracts::ReadResult.new(status: "empty")
      },
      registration_port: ->(**) { flunk "An authenticated own-read must not start another authentication handoff" },
      destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", support: "/pages/pomoc" }
    )
    coordinator = Dialogue::Coordinator.new(
      understanding: ->(**) { flunk "The explicit resume must not require a model call" },
      procedures: runner, state_store: @semantic, runtime: InlineRuntime.new
    )
    with_dialogue_translations do
      result = coordinator.call(message: "nastavi", context: controller.dialogue_context)
      # The fixture read carries no facts, so the turn ends with the "no verified
      # data" refusal. That is "unsupported", not "answered" (Task 9b).
      assert_equal "unsupported", result.resolution, result.reply.text
      # R3: a refusal is never bare any more — it leads with the same "no
      # verified data" sentence and then names the next step. Asserted as
      # "opens with, and carries a next step" rather than as a literal, so the
      # refusal itself stays pinned without re-pinning the next-step copy.
      assert result.reply.text.start_with?(I18n.t("decidim.bih.dialogue.no_match", locale: :sr)), result.reply.text
      next_step = I18n.t("decidim.bih.dialogue.dead_end_support", locale: :sr, url: "").strip

      assert_includes result.reply.text, next_step
      assert_nil result.reply.report
      refute result.handoff_offered
      refute result.handoff_completed
    end
    assert_equal 1, reads.length
    read = reads.fetch(0)
    assert_equal ["report_status", "report", { "query" => "Moje prijave" }], read.values_at(:action, :topic, :entities)
    assert_equal [71, 11, "d" * 64], read.fetch(:context).to_h.values_at(:organization_id, :actor_id, :conversation_key)
    assert read.fetch(:context).allows?("own_report_reads")
    assert_nil read.fetch(:location)
    assert_equal 2, @semantic.read(context: controller.dialogue_context).fetch("version")
  end

  def test_sensitive_text_does_not_claim_ticket_and_restore_cannot_overwrite_a_concurrent_task
    controller = complete_own_report_authentication(suspended_auth: true)
    entry = controller.session.fetch(Bridge::SESSION_KEY)
    assert_nil controller.send(:registration_resume_for, "Moj kod je 123456")
    assert_equal entry, controller.session.fetch(Bridge::SESSION_KEY)
    assert_empty @revoked_origins
    task = controller.send(:registration_resume_for, "nastavi")
    assert task
    context = controller.dialogue_context
    concurrent = @semantic.empty_state(context).merge("active_task" => "ask_information", "topic" => "parking")
    assert_equal :saved, @semantic.write(context:, state: concurrent, expected_version: 0)
    before_restore = @semantic.read(context:)
    assert_equal :conflict, controller.send(:restore_registration_task, task, message: "Zdravo")
    assert_equal before_restore, @semantic.read(context:)
    assert_nil controller.send(:registration_resume_for, "nastavi")
    assert_empty controller.session
    assert_equal 1, @revoked_origins.length
  end

  def test_an_unrecognized_first_turn_after_authentication_keeps_the_saved_task_for_explicit_resume
    controller = complete_own_report_authentication
    message = "nastvvi"
    task = controller.send(:registration_resume_for, message)
    assert task
    assert_equal :saved, controller.send(:restore_registration_task, task, message:)
    restored = @semantic.read(context: controller.dialogue_context)
    assert_nil restored.fetch("active_task")
    assert_equal task, restored.fetch("suspended_task")
    assert_equal task.fetch("locale"), restored.fetch("locale")
    reads = []
    understanding_calls = []
    runner = Dialogue::ProcedureRunner.new(
      read_port: lambda { |**args|
        reads << args
        Contracts::ReadResult.new(status: "empty")
      },
      registration_port: ->(**) { flunk "A greeting does not need another authentication handoff" },
      destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", support: "/pages/pomoc" }
    )
    coordinator = Dialogue::Coordinator.new(
      understanding: lambda { |message:, **|
        understanding_calls << message
        Contracts::Understanding.parse(action: "help", topic: "unknown", entities: {}, operation: "start",
                                        needs_clarification: false, secondary: nil, locale: "sr")
      },
      procedures: runner, state_store: @semantic, runtime: InlineRuntime.new
    )
    with_dialogue_translations do
      coordinator.call(message:, context: controller.dialogue_context)
      result = coordinator.call(message: "nastavi", context: controller.dialogue_context)
      assert_equal "unsupported", result.resolution
    end
    assert_equal [message], understanding_calls
    assert_equal 1, reads.length
    assert_equal ["report_status", "report", { "query" => "Moje prijave" }], reads.first.values_at(:action, :topic, :entities)
  end

  def test_a_new_question_after_authentication_can_finish_before_the_saved_task_resumes
    controller = complete_own_report_authentication
    message = "Koliko košta parking?"
    task = controller.send(:registration_resume_for, message)
    assert_equal :saved, controller.send(:restore_registration_task, task, message:)
    reads = []
    runner = Dialogue::ProcedureRunner.new(
      read_port: lambda { |**args|
        reads << args
        Contracts::ReadResult.new(status: "empty")
      },
      registration_port: ->(**) { flunk "Authenticated reads must not require another authentication" },
      destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", support: "/pages/pomoc" }
    )
    coordinator = Dialogue::Coordinator.new(
      understanding: lambda { |message:, **|
        assert_equal "Koliko košta parking?", message
        Contracts::Understanding.parse(action: "ask_information", topic: "parking", entities: { "query" => message }, operation: "start",
                                        needs_clarification: false, secondary: nil, locale: "sr")
      },
      procedures: runner, state_store: @semantic, runtime: InlineRuntime.new
    )
    with_dialogue_translations do
      assert_equal "unsupported", coordinator.call(message:, context: controller.dialogue_context).resolution
      assert_equal "report_status", @semantic.read(context: controller.dialogue_context).fetch("suspended_task").fetch("active_task")
      assert_equal "unsupported", coordinator.call(message: "nastavi", context: controller.dialogue_context).resolution
    end
    assert_equal %w(parking report), reads.map { |read| read.fetch(:topic) }
    assert_equal({ "query" => "Moje prijave" }, reads.last.fetch(:entities))
    assert_nil @semantic.read(context: controller.dialogue_context).fetch("suspended_task")
  end

  def test_a_non_model_greeting_does_not_consume_the_restored_suspension
    controller = complete_own_report_authentication
    task = controller.send(:registration_resume_for, "Zdravo")
    task = task.merge("locale" => "sr-Cyrl")
    assert_equal :saved, controller.send(:restore_registration_task, task, message: "Zdravo")
    # A host greeting may answer outside Coordinator without a semantic write.
    # The controller has already moved the one-use ticket into safe state.
    assert_empty controller.session
    restored = @semantic.read(context: controller.dialogue_context)
    assert_equal "sr-Cyrl", restored.fetch("locale")
    assert_nil restored.fetch("draft")
    assert_nil restored.fetch("suspended_task").fetch("draft")
    refute restored.fetch("suspended_task").fetch("report_handoff_offered")
    runner = Dialogue::ProcedureRunner.new(
      read_port: ->(**) { Contracts::ReadResult.new(status: "empty") },
      registration_port: ->(**) { flunk "A resumed own-read must not authenticate again" },
      destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", support: "/pages/pomoc" }
    )
    coordinator = Dialogue::Coordinator.new(
      understanding: ->(**) { flunk "Explicit resume must not call the model" },
      procedures: runner, state_store: @semantic, runtime: InlineRuntime.new
    )
    with_dialogue_translations do
      assert_equal "unsupported", runner.call(understanding: Contracts::Understanding.clarify(locale: "sr-Cyrl"),
                                            state: restored, context: controller.dialogue_context, message: "настави").resolution
      assert_equal "unsupported", coordinator.call(message: "настави", context: controller.dialogue_context).resolution
    end
    assert_nil @semantic.read(context: controller.dialogue_context).fetch("suspended_task")
  end

  def test_explicit_clear_after_phone_session_reset_revokes_the_old_return_ticket
    assert_return_cancelled_after_session_reset("/clear")
  end

  def test_explicit_cancel_after_phone_session_reset_revokes_the_old_return_ticket
    assert_return_cancelled_after_session_reset("odustani")
  end

  def test_report_revocation_failure_prevents_restore_without_undoing_authentication
    ticket = issue
    @store.start(entry: ticket.entry, context: @context)
    session = { Bridge::SESSION_KEY => ticket.entry }
    controller = PhoneController.new(session:, organization: @organization)
    Bridge.stub(:new, @bridge) do
      assert controller.complete_phone_authentication(user: @user, purpose: "login", grant: -> { true }, destination: "/required-onboarding")
    end
    @report_store.define_singleton_method(:revoke) { |**| raise IOError, "Synthetic report store failure" }
    assert_nil @bridge.consume(session: controller.session, context: authenticated_context, user: @user)
    assert controller.user_signed_in?
    assert_equal "/required-onboarding", controller.destination
    assert_nil issue
  end

  def test_devise_hook_preserves_owner_redirect_and_requires_observed_sign_in
    ticket = issue
    @store.start(entry: ticket.entry, context: @context)
    controller_class = Class.new(PhoneController) do
      def after_sign_in_path_for(_user) = "/required-password-update"
      prepend DecidimApp::MilicaRegistrationAuthReturn::Devise
    end
    controller = controller_class.new(session: { Bridge::SESSION_KEY => ticket.entry }, organization: @organization)
    Bridge.stub(:new, @bridge) do
      assert_equal "/required-password-update", controller.after_sign_in_path_for(@user)
      assert_nil @store.consume(entry: ticket.entry, context: authenticated_context, user: @user)
      controller.sign_in(:user, @user)
      assert_equal "/required-password-update", controller.after_sign_in_path_for(@user)
    end
    assert @bridge.consume(session: controller.session, context: authenticated_context, user: @user)
  end

  private

  def assert_return_cancelled_after_session_reset(message)
    controller = complete_own_report_authentication
    entry = controller.session.fetch(Bridge::SESSION_KEY)
    assert_nil controller.send(:registration_resume_for, message)
    assert_empty controller.session
    assert_nil @bridge.consume(session: { Bridge::SESSION_KEY => entry }, context: controller.dialogue_context, user: @user)
    assert_nil controller.send(:registration_resume_for, "nastavi")
    assert_nil @semantic.read(context: controller.dialogue_context).fetch("active_task")
    assert_nil @semantic.read(context: controller.dialogue_context).fetch("suspended_task")
  end

  def complete_own_report_authentication(suspended_auth: false)
    candidate = @state.merge("active_task" => "report_status", "topic" => "report", "suspended_task" => suspended_auth ? @state.slice(*Semantic::TASK_KEYS) : nil,
                             "entities" => { "query" => "Moje prijave" }, "entity_provenance" => { "query" => "citizen" })
    assert_equal :saved, @semantic.write(context: @context, state: candidate, expected_version: candidate.fetch("version"))
    ticket = @store.issue(context: @context, state: @semantic.read(context: @context), destination: "/users/sign_in")
    assert_equal candidate.merge("version" => candidate.fetch("version") + 1), @semantic.read(context: @context)
    session = { Bridge::SESSION_KEY => ticket.entry, :decidim_bih_web_chat_id => @browser_id, :unrelated => "not retained" }
    assert_equal "/users/sign_in", @bridge.start(session:, user: nil, secret: @secret)
    controller = ReturningController.new(session:, organization: @organization)
    Bridge.stub(:new, @bridge) do
      assert controller.complete_phone_authentication(user: @user, purpose: "login", grant: -> { true },
                                                      consume: -> { true }, destination: "/required-onboarding")
    end
    assert_equal "/required-onboarding", controller.destination
    assert_equal [Bridge::SESSION_KEY], controller.session.keys
    # The real controller rotates actor scope. Supply that new trusted scope
    # explicitly here; HTTP/session middleware behavior is outside this test.
    controller.dialogue_context = authenticated_context.with(conversation_key: "d" * 64, capabilities: %w(public_reads own_report_reads))
    controller.semantic_store = @semantic
    controller.handoff_bridge = @bridge
    controller
  end

  # The host switch, for the duration of one assertion. Under the Rails runner
  # Decidim::Bih already answers registration_path (the host initializer sets
  # it), and under plain Ruby the engine's lib is not loaded at all — so the
  # helper stubs an existing reader and defines a temporary one otherwise,
  # restoring either way.
  def with_registration_path(path, &)
    return Decidim::Bih.stub(:registration_path, path, &) if Decidim::Bih.respond_to?(:registration_path)

    Decidim::Bih.define_singleton_method(:registration_path) { path }
    begin
      yield
    ensure
      Decidim::Bih.singleton_class.send(:remove_method, :registration_path)
    end
  end

  def with_dialogue_translations
    previous_backend = I18n.backend
    previous_available = I18n.available_locales
    I18n.available_locales = Contracts::LOCALES
    I18n.backend = I18n::Backend::Simple.new
    I18n.backend.send(:init_translations)
    I18n.backend.load_translations(File.join(Gem.loaded_specs.fetch("decidim-bih").full_gem_path, "config/locales/decidim_bih_dialogue.yml"))
    yield
  ensure
    I18n.backend = previous_backend
    I18n.available_locales = previous_available
  end

  def committed_state(suspended: true)
    task = @semantic.empty_state(@context).slice(*Semantic::TASK_KEYS).merge(
      "active_task" => "report_problem", "topic" => "report", "report_handoff_offered" => true,
      "entities" => { "description" => "Synthetic report description", "address" => "Synthetic Street", "area_slug" => "komsiluk-11" },
      "entity_provenance" => { "description" => "citizen", "address" => "corrected", "area_slug" => "trusted_profile" }
    )
    state = @semantic.empty_state(@context).merge("active_task" => "sign_in", "topic" => "account", "suspended_task" => suspended ? task : nil)
    assert_equal :saved, @semantic.write(context: @context, state:, expected_version: 0)
    @semantic.read(context: @context)
  end

  def issue = @store.issue(context: @context, state: @state, destination: "/users/sign_in")

  def authenticated_context = @context.with(actor_id: @user.id, account_state: "registered")

  def user(id, organization_id: 71)
    value = Decidim::User.allocate
    organization = Organization.new(id: organization_id, host: "synthetic.example")
    value.define_singleton_method(:id) { id }
    value.define_singleton_method(:organization) { organization }
    value.define_singleton_method(:persisted?) { true }
    value.define_singleton_method(:active_for_authentication?) { true }
    value.define_singleton_method(:blocked?) { false }
    value.define_singleton_method(:deleted?) { false }
    value
  end
end

# rubocop:enable Rails/RefuteMethods
