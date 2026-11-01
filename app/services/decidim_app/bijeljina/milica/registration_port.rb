# frozen_string_literal: true

require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # Read-only adapter over the registration/account surfaces owned by the
      # registration team. It offers real supported destinations and re-reads
      # account state, but issues no OTP, creates no identity and claims no
      # resumable handoff that the backend does not implement.
      class RegistrationPort
        ACTIONS = %w(registration sign_in link_account verification choose_area change_area preferences).freeze
        WEB_HANDOFF_PATH = "/milica/prijava"
        # The next steps a browser return ticket may stand in for.
        #
        # "register" is deliberately NOT one of them. The ticket lives in ONE
        # browser's session for ten minutes; the moment it is gone — a later
        # tap, a second device, the address copied out of the chat — the
        # handoff controller has no ticket to honour and resolves the
        # destination from the only authority left, the account. An anonymous
        # visitor has none, so it offers /users/sign_in. For a citizen who was
        # just told "hajde da otvorimo nalog — traje minut", that is the LOGIN
        # form: the one page a person without an account cannot use, at the
        # campaign's entry point.
        #
        # A register answer therefore always names the real destination the
        # backend resolved, which is Decidim::Bih.registration_path — the host
        # switch every other "register" link on the platform follows, and the
        # one config/initializers/decidim_bih_registration.rb points at
        # /registracija. A host that moves it moves this too; nothing here
        # types a path.
        #
        # sign_in and verify keep the ticket: both belong to a citizen who HAS
        # an account, and that is exactly the case the controller's recovery
        # resolves correctly.
        WEB_HANDOFF_STEPS = %w(sign_in verify).freeze
        PreparedHandoff = Data.define(:handoff, :ticket, :original_destination)

        def initialize(organization:, backend: nil)
          @organization = organization
          @backend = backend || Backend.new(organization:)
        end

        def call(action:, context:, locale: "sr")
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)

          within_deadline(context.deadline) do
            perform_handoff(action:, context:, locale:)
          end
        rescue CityServiceNoticeCollector::DeadlineExceeded
          handoff("unavailable", "deadline_exceeded", destination: nil)
        rescue CityServiceNoticeCollector::InvalidDeadline
          handoff("unavailable", "invalid_deadline", destination: nil)
        rescue contracts::Invalid
          raise
        rescue StandardError => e
          return handoff("unavailable", "deadline_exceeded", destination: nil) if defined?(ActiveRecord::QueryCanceled) && e.is_a?(ActiveRecord::QueryCanceled)

          log_failure(e, action)
          handoff("unavailable", "unavailable", destination: nil)
        end

        # Web controller only, after the candidate's semantic CAS succeeded.
        # The normal port remains read-only and usable by other channels.
        def prepare_web_handoff(action:, context:, state:, reply_text:, locale: "sr", store: RegistrationHandoffStore.new)
          # An anonymous own-report read offers sign-in directly. Preserve the
          # report task itself for the authenticated return.
          action = "sign_in" if action == "report_status" && context.actor_id.nil?
          result = call(action:, context:, locale:)
          return if result.completed || !WEB_HANDOFF_STEPS.include?(result.next_step) || !result.destination
          return unless reply_text.is_a?(String) && reply_text.include?(result.destination)

          ticket = store.issue(context:, state:, destination: result.destination)
          return unless ticket

          PreparedHandoff.new(handoff: result.with(destination: WEB_HANDOFF_PATH, expires_at: ticket.expires_at, resume_supported: true),
                              ticket: ticket.entry, original_destination: result.destination)
        end

        # Where a citizen belongs when the web return ticket is gone — expired,
        # already consumed, opened in another browser, or invalidated because
        # the conversation moved on. That is the ORDINARY case for anyone who
        # comes back later, not an attack.
        #
        # It is resolved by PURPOSE, from the only authority left once the
        # ticket is gone: the account itself. A citizen who is signed in
        # continues their own onboarding step (phone, komšiluk, welcome); an
        # anonymous visitor is offered SIGN-IN, because most of them already
        # have an account and none of them should be walked through new-account
        # registration by an expired link. Registration stays one link away on
        # the page they land on.
        #
        # Read-only and side-effect free: it creates no account, no token and no
        # conversation state, and it returns nil rather than guessing.
        def recovery_destination(user)
          return backend.sign_in_destination unless user.is_a?(Decidim::User)
          return nil unless resolvable_citizen?(user)

          validated_destination(backend.verification_destination(user))
        rescue StandardError => e
          log_failure(e, "recovery")
          nil
        end

        # The closed set of local paths a recovery redirect may use, named
        # beside the resolver that produces them so the two cannot drift. The
        # comparison ignores any query string: the onboarding chain marks its
        # own steps with "?setup=1".
        def recovery_allowed?(destination)
          return false unless destination.is_a?(String) && destination.start_with?("/") && !destination.start_with?("//")

          path = URI.parse(destination).path
          recovery_paths.include?(path)
        rescue URI::InvalidURIError
          false
        end

        private

        attr_reader :organization, :backend

        # Whose onboarding step this resolver may answer for.
        def resolvable_citizen?(user)
          return false unless user.organization&.id == organization.id
          return false if user.blocked? || user.deleted?
          # Nothing left to continue: without the phone-first chain the only
          # destination is the phone form, which a verified citizen has passed.
          return false if verified?(user) && !phone_first?

          true
        end

        def verified?(user)
          Decidim::Authorization.find_by(user:, name: "sms")&.granted? == true
        end

        def recovery_paths
          ["/users/sign_in", Decidim::Bih::Onboarding::NextStep::SMS_NEW_PATH,
           public_path("verifikacija/telefon"), public_path("komsiluk"),
           public_path("dobrodosli"), public_path("moj-nalog")].compact.uniq
        end

        def public_path(suffix)
          Decidim::Bih.public_path(suffix)
        rescue StandardError
          nil
        end

        # With phone-first on, NextStep answers the whole chain (komšiluk,
        # welcome, account) and is still useful after verification; without it
        # the only destination is the phone form, which a verified citizen has
        # already passed.
        def phone_first?
          Decidim::Bih.respond_to?(:phone_first_registration) && Decidim::Bih.phone_first_registration == true &&
            defined?(Decidim::Bih::Onboarding::NextStep)
        rescue StandardError
          false
        end

        def perform_handoff(action:, context:, locale:)
          validate_context!(context)
          action = contracts.enum!(action.to_s, contracts::ACTIONS)
          contracts.enum!(locale.to_s, contracts::LOCALES)
          return handoff(context.account_state, "unsupported", destination: nil) unless ACTIONS.include?(action)
          return handoff(context.account_state, "unavailable", destination: nil) unless context.allows?("registration_handoff")
          return handoff("unavailable", "unavailable", destination: nil) if context.account_state == "unavailable"

          actor = actor_for!(context)
          state = account_state(actor, context)
          dispatch_handoff(action, actor, state, context.deadline)
        end

        def dispatch_handoff(action, actor, state, deadline)
          case action
          when "registration" then registration_handoff(actor, state)
          when "sign_in" then sign_in_handoff(actor, state)
          when "verification" then verification_handoff(actor, state)
          when "choose_area" then area_handoff(actor, state, deadline)
          when "change_area" then change_area_handoff(actor, state)
          when "preferences" then preferences_handoff(actor, state)
          else handoff(state, "unsupported", destination: nil)
          end
        end

        def registration_handoff(actor, state)
          return completed_handoff(state, "registered", backend.account_destination) if %w(registered verified).include?(state)
          return handoff(state, "verify", destination: backend.verification_destination(actor)) if actor

          handoff(state, "register", destination: backend.registration_destination)
        end

        def sign_in_handoff(actor, state)
          return completed_handoff(state, "signed_in", backend.account_destination) if actor

          handoff(state, "sign_in", destination: backend.sign_in_destination)
        end

        def verification_handoff(actor, state)
          return handoff(state, "sign_in", destination: backend.sign_in_destination) unless actor
          return completed_handoff(state, "verified", backend.account_destination) if state == "verified"

          handoff(state, "verify", destination: backend.verification_destination(actor))
        end

        def area_handoff(actor, state, deadline)
          return handoff(state, "sign_in", destination: backend.sign_in_destination) unless actor

          profile = read_query(deadline) do
            Decidim::Bih::CitizenProfile.find_by(
              decidim_organization_id: organization.id,
              decidim_user_id: actor.id
            )
          end
          assigned_area = profile&.komsiluk
          if profile&.assigned? && assigned_area&.decidim_organization_id == organization.id && assigned_area.kind == "komsiluk"
            return completed_handoff(state, "area_selected", backend.account_destination)
          end

          handoff(state, "choose_area", destination: backend.area_destination)
        end

        def change_area_handoff(actor, state)
          return handoff(state, "sign_in", destination: backend.sign_in_destination) unless actor

          handoff(state, "choose_area", destination: backend.area_destination)
        end

        def preferences_handoff(actor, state)
          return handoff(state, "sign_in", destination: backend.sign_in_destination) unless actor

          handoff(state, "manage_preferences", destination: backend.preferences_destination)
        end

        def completed_handoff(state, next_step, destination)
          handoff(state, next_step, destination:, completed: true)
        end

        def handoff(account_state, next_step, destination:, completed: false)
          destination = validated_destination(destination)
          contracts::HandoffResult.new(
            account_state:,
            next_step:,
            destination:,
            expires_at: nil,
            resume_supported: false,
            completed:
          )
        end

        def validate_context!(context)
          raise contracts::Invalid, "Trusted context required" unless context.is_a?(contracts::TrustedContext)
          raise contracts::Invalid, "Organization scope mismatch" unless context.organization_id == organization.id
          raise contracts::Invalid, "Actor/account scope mismatch" if context.actor_id.nil? && %w(anonymous unregistered unavailable).exclude?(context.account_state)

          CityServiceNoticeCollector.send(:remaining_seconds, context.deadline)
          actor_for!(context) if context.actor_id
        end

        def actor_for!(context)
          return nil unless context.actor_id

          actor = read_query(context.deadline) do
            Decidim::User.find_by(id: context.actor_id, organization:)
          end
          raise contracts::Invalid, "Actor scope mismatch" unless actor

          actor
        end

        def account_state(actor, context)
          return context.account_state == "unregistered" ? "unregistered" : "anonymous" unless actor

          authorization = read_query(context.deadline) do
            Decidim::Authorization.find_by(user: actor, name: "sms")
          end
          return "verified" if authorization&.granted?
          return "registered" if actor.respond_to?(:confirmed?) && actor.confirmed?

          "unverified"
        end

        def read_query(deadline, &)
          seconds = CityServiceNoticeCollector.send(:remaining_seconds, deadline)
          return yield if seconds.nil?
          raise CityServiceNoticeCollector::DeadlineExceeded, "registration read deadline expired" if seconds <= 0

          milliseconds = [(seconds * 1_000).floor, 1].max
          ActiveRecord::Base.connection.transaction(requires_new: true) do
            ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = #{milliseconds}")
            yield
          end
        end

        def within_deadline(deadline, &)
          CityServiceNoticeCollector.send(:within_deadline, deadline, &)
        end

        def validated_destination(destination)
          return nil if destination.blank?

          value = destination.to_s
          uri = URI.parse(value)
          valid = uri.relative? ? relative_destination?(value) : same_origin_https_destination?(uri)
          raise contracts::Invalid, "Unsupported handoff destination" unless valid

          value
        rescue URI::InvalidURIError
          raise contracts::Invalid, "Unsupported handoff destination"
        end

        def relative_destination?(value)
          value.start_with?("/") && !value.start_with?("//") && value.exclude?("\\")
        end

        def same_origin_https_destination?(uri)
          uri.scheme == "https" && uri.host == organization.host && uri.userinfo.nil? && uri.port == 443
        end

        def contracts
          Decidim::Bih::Concierge::Dialogue::Contracts
        end

        def log_failure(error, action)
          if defined?(Rails.logger)
            Rails.logger.warn(
              "[Milica::RegistrationPort] read failed error_class=#{error.class.name} action=#{action.to_s.first(40)}"
            )
          end
        end

        # Destination resolver only. Delivery-A's committed NextStep seam is
        # used when present after integration; this fallback remains compatible
        # with the current engine base and never creates registration state.
        class Backend
          def initialize(organization:)
            @organization = organization
          end

          def registration_destination
            if Decidim::Bih.respond_to?(:registration_path)
              Decidim::Bih.registration_path
            else
              "/users/sign_up"
            end
          end

          def sign_in_destination = "/users/sign_in"

          def verification_destination(actor)
            if phone_first_registration_enabled? && defined?(Decidim::Bih::Onboarding::NextStep)
              Decidim::Bih::Onboarding::NextStep.for(actor, organization:)
            else
              Decidim::Bih.public_path("verifikacija/telefon")
            end
          end

          def area_destination
            Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path
          end

          def preferences_destination = "/notifications_settings"

          def account_destination
            Decidim::Bih::Engine.routes.url_helpers.account_overview_path
          end

          private

          attr_reader :organization

          def phone_first_registration_enabled?
            Decidim::Bih.respond_to?(:phone_first_registration) && Decidim::Bih.phone_first_registration == true
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
