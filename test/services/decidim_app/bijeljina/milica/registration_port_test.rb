# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class RegistrationPortTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        Backend = Struct.new(
          :registration_destination,
          :sign_in_destination,
          :verification_path,
          :area_destination,
          :preferences_destination,
          :account_destination,
          keyword_init: true
        ) do
          def verification_destination(_actor) = verification_path
        end

        setup do
          @organization = create_organization(host: "handoff.example.org")
          @now = Time.utc(2026, 9, 5, 12, 0)
          @backend = Backend.new(
            registration_destination: "/users/sign_up",
            sign_in_destination: "/users/sign_in",
            verification_path: "/sms/authorizations/new",
            area_destination: "/biceriseno/komsiluk?setup=1",
            preferences_destination: "/notifications_settings",
            account_destination: "/biceriseno/moj-nalog?setup=1"
          )
        end

        test "offers the real registration destination without claiming completion or resume" do
          result = port.call(
            action: "registration",
            context: context(capabilities: ["registration_handoff"])
          )

          assert_equal "anonymous", result.account_state
          assert_equal "register", result.next_step
          assert_equal "/users/sign_up", result.destination
          assert_equal false, result.completed
          assert_equal false, result.resume_supported
          assert_nil result.expires_at
        end

        test "distinguishes returning sign in from new registration" do
          result = port.call(
            action: "sign_in",
            context: context(account_state: "unregistered", capabilities: ["registration_handoff"])
          )

          assert_equal "unregistered", result.account_state
          assert_equal "sign_in", result.next_step
          assert_equal "/users/sign_in", result.destination
          assert_equal false, result.completed
        end

        test "proves an anonymous-to-authenticated transition by re-reading a scoped actor" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          result = port.call(
            action: "registration",
            context: context(actor:, account_state: "anonymous", capabilities: ["registration_handoff"])
          )

          assert_equal "registered", result.account_state
          assert_equal "registered", result.next_step
          assert_equal true, result.completed
          assert_equal "/biceriseno/moj-nalog?setup=1", result.destination
        end

        test "does not claim registration completion for an unconfirmed actor" do
          actor = FactoryBot.create(:user, organization: @organization)

          result = port.call(
            action: "registration",
            context: context(actor:, account_state: "unverified", capabilities: ["registration_handoff"])
          )

          assert_equal "unverified", result.account_state
          assert_equal "verify", result.next_step
          assert_equal false, result.completed
          assert_equal "/sms/authorizations/new", result.destination
        end

        test "offers verification but does not treat a pending authorization as verified or sent" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: actor, name: "sms")

          result = port.call(
            action: "verification",
            context: context(actor:, account_state: "unverified", capabilities: ["registration_handoff"])
          )

          assert_equal "registered", result.account_state
          assert_equal "verify", result.next_step
          assert_equal false, result.completed
          assert_equal "/sms/authorizations/new", result.destination
        end

        test "claims verification completion only from a granted backend authorization" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          authorization = Decidim::Authorization.create!(user: actor, name: "sms")
          authorization.update!(granted_at: @now)

          result = port.call(
            action: "verification",
            context: context(actor:, account_state: "unverified", capabilities: ["registration_handoff"])
          )

          assert_equal "verified", result.account_state
          assert_equal "verified", result.next_step
          assert_equal true, result.completed
        end

        test "real backend keeps the legacy verification destination when phone-first is off" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          with_phone_first_registration(false) do
            Decidim::Bih::Onboarding::NextStep.stub(:for, ->(*, **) { flunk("phone-first must be opt-in") }) do
              assert_no_registration_writes do
                assert_equal "/biceriseno/verifikacija/telefon", real_backend.verification_destination(actor)
              end
            end
          end
        end

        test "real backend uses the phone-first destination for an absent authorization" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          with_phone_first_registration(true) do
            assert_no_registration_writes do
              assert_equal Decidim::Bih::Onboarding::NextStep::SMS_NEW_PATH,
                           real_backend.verification_destination(actor)
            end
          end
        end

        test "real backend sends a verified citizen without an assigned profile to the picker" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: actor, name: "sms", granted_at: @now)
          Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)

          with_phone_first_registration(true) do
            assert_no_registration_writes do
              assert_equal "/biceriseno/komsiluk?setup=1", real_backend.verification_destination(actor)
            end
          end
        end

        test "real backend keeps the legacy destination when phone-first accessor is unavailable" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          with_phone_first_registration(true) do
            original_respond_to = Decidim::Bih.method(:respond_to?)
            missing_phone_flag = lambda do |name, include_private = false|
              next false if name == :phone_first_registration

              original_respond_to.call(name, include_private)
            end

            Decidim::Bih.stub(:respond_to?, missing_phone_flag) do
              Decidim::Bih::Onboarding::NextStep.stub(:for, ->(*, **) { flunk("missing flag must use fallback") }) do
                assert_no_registration_writes do
                  assert_equal "/biceriseno/verifikacija/telefon", real_backend.verification_destination(actor)
                end
              end
            end
          end
        end

        test "real backend preserves tenant actor scope before resolving phone-first" do
          foreign_actor = FactoryBot.create(:user, :confirmed, organization: create_organization)

          with_phone_first_registration(true) do
            assert_raises(contracts::Invalid) do
              RegistrationPort.new(organization: @organization, backend: real_backend).call(
                action: "verification",
                context: context(
                  actor: foreign_actor,
                  account_state: "unverified",
                  capabilities: ["registration_handoff"]
                )
              )
            end
          end
        end

        test "real backend distinguishes a pending authorization from a verified one" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          authorization = Decidim::Authorization.create!(user: actor, name: "sms")

          with_phone_first_registration(true) do
            assert_no_registration_writes do
              assert_equal "/biceriseno/verifikacija/telefon", real_backend.verification_destination(actor)
            end

            authorization.update!(granted_at: @now)
            assert_no_registration_writes do
              assert_equal "/biceriseno/komsiluk?setup=1", real_backend.verification_destination(actor)
            end
          end
        end

        test "real backend preserves the welcome step when simplified registration is disabled" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: actor, name: "sms", granted_at: @now)
          area = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "assigned-handoff",
            name: { "sr" => "Assigned Handoff" }
          )
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(area, source: "dropdown")

          Decidim::Bih.stub(:simplified_registration, false) do
            with_phone_first_registration(true) do
              assert_no_registration_writes do
                assert_equal "/biceriseno/dobrodosli", real_backend.verification_destination(actor)
              end
              assert_not Decidim::Bih::Onboarding::Welcome.welcomed?(actor.reload)

              # Explicit fixture setup models the registration team's completed
              # welcome action; the Milica read-only resolver must never do it.
              Decidim::Bih::Onboarding::Welcome.mark!(actor)
              assert_no_registration_writes do
                assert_equal "/biceriseno/moj-nalog?setup=1", real_backend.verification_destination(actor)
              end
            end
          end
        end

        test "real backend sends an assigned citizen to member home without a welcome step in simplified registration" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: actor, name: "sms", granted_at: @now)
          area = Decidim::Bih::LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "compact-handoff", name: { "sr" => "Compact Handoff" })
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(area, source: "dropdown")

          Decidim::Bih.stub(:simplified_registration, true) do
            with_phone_first_registration(true) do
              assert_no_registration_writes do
                assert_equal "/biceriseno/moj-nalog", real_backend.verification_destination(actor)
              end
              assert_not Decidim::Bih::Onboarding::Welcome.welcomed?(actor.reload)
            end
          end
        end

        test "re-reads assigned area before claiming the area step complete" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          area = Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "komsiluk-handoff",
            name: { "sr" => "Handoff" }
          )
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(area, source: "dropdown")

          result = port.call(
            action: "choose_area",
            context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
          )

          assert_equal "area_selected", result.next_step
          assert_equal true, result.completed
        end

        test "change_area always offers the picker without claiming a selection" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "change_area",
              context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "registered", result.account_state
          assert_equal "choose_area", result.next_step
          assert_equal "/biceriseno/komsiluk?setup=1", result.destination
          assert_equal false, result.completed
        end

        test "change_area sends anonymous citizens to sign in" do
          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "change_area",
              context: context(account_state: "anonymous", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "anonymous", result.account_state
          assert_equal "sign_in", result.next_step
          assert_equal "/users/sign_in", result.destination
          assert_equal false, result.completed
        end

        test "change_area does not claim a backend selection for an assigned actor" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          area = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "change-area", name: { "sr" => "Change" }
          )
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          profile.assign_komsiluk!(area, source: "dropdown")
          before_attributes = profile.reload.attributes

          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "change_area",
              context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "choose_area", result.next_step
          assert_equal false, result.completed
          assert_equal before_attributes, profile.reload.attributes
        end

        test "change_area preserves an unassigned profile and offers the picker" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = Decidim::Bih::CitizenProfile.create!(organization: @organization, user: actor)
          before_attributes = profile.reload.attributes

          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "change_area",
              context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "choose_area", result.next_step
          assert_equal "/biceriseno/komsiluk?setup=1", result.destination
          assert_equal false, result.completed
          assert_equal before_attributes, profile.reload.attributes
        end

        test "change_area leaves a profile-less actor unchanged while offering the picker" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)

          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "change_area",
              context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "choose_area", result.next_step
          assert_equal false, result.completed
          assert_nil Decidim::Bih::CitizenProfile.find_by(organization: @organization, user: actor)
        end

        test "change_area remains unavailable without the handoff capability" do
          result = port.call(action: "change_area", context: context)

          assert_equal "unavailable", result.next_step
          assert_nil result.destination
          assert_equal false, result.completed
        end

        test "real backend area and account destinations stay on the mounted engine" do
          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          real_port = RegistrationPort.new(organization: @organization, backend: real_backend)

          result = nil
          assert_no_registration_writes do
            result = real_port.call(
              action: "change_area",
              context: context(actor:, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          assert_equal "choose_area", result.next_step
          assert_equal "/biceriseno/komsiluk", result.destination
          assert_equal false, result.completed
          assert_equal "/biceriseno/moj-nalog", real_backend.account_destination
        end

        test "keeps account linking explicitly unsupported on the current backend" do
          result = port.call(
            action: "link_account",
            context: context(capabilities: ["registration_handoff"])
          )

          assert_equal "unsupported", result.next_step
          assert_nil result.destination
          assert_equal false, result.completed
          assert_equal false, result.resume_supported
        end

        test "returns unavailable when registration handoff capability is absent" do
          result = port.call(action: "registration", context: context)

          assert_equal "unavailable", result.next_step
          assert_nil result.destination
          assert_equal false, result.completed
        end

        test "preserves an unavailable account state without consulting destinations" do
          destination_calls = []
          destination_methods = [
            :registration_destination, :sign_in_destination, :verification_destination,
            :area_destination, :preferences_destination, :account_destination
          ]
          destination_methods.each do |method|
            destination_method = method
            @backend.define_singleton_method(method) do |*|
              destination_calls << destination_method
              "/should-not-be-used"
            end
          end

          assert_no_registration_writes do
            %w(registration sign_in link_account verification choose_area change_area preferences).each do |action|
              result = port.call(
                action:,
                context: context(account_state: "unavailable", capabilities: ["registration_handoff"])
              )

              assert_equal "unavailable", result.account_state
              assert_equal "unavailable", result.next_step
              assert_nil result.destination
              assert_equal false, result.completed
              assert_equal false, result.resume_supported
              assert_nil result.expires_at
            end
          end

          actor = FactoryBot.create(:user, :confirmed, organization: @organization)
          result = nil
          assert_no_registration_writes do
            result = port.call(
              action: "verification",
              context: context(actor:, account_state: "unavailable", capabilities: ["registration_handoff"])
            )
          end
          assert_equal "unavailable", result.account_state
          assert_equal "unavailable", result.next_step
          assert_nil result.destination
          assert_equal false, result.completed
          assert_equal false, result.resume_supported
          assert_nil result.expires_at
          assert_empty destination_calls
        end

        test "preserving an unavailable state does not bypass actor organization validation" do
          foreign_actor = FactoryBot.create(:user, :confirmed, organization: create_organization)

          assert_raises(contracts::Invalid) do
            port.call(
              action: "registration",
              context: context(
                actor: foreign_actor,
                account_state: "unavailable",
                capabilities: ["registration_handoff"]
              )
            )
          end
        end

        test "rejects cross-tenant actors and unsafe destinations" do
          foreign_actor = FactoryBot.create(:user, :confirmed, organization: create_organization)
          assert_raises(contracts::Invalid) do
            port.call(
              action: "sign_in",
              context: context(actor: foreign_actor, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end
          assert_raises(contracts::Invalid) do
            port.call(
              action: "change_area",
              context: context(actor: foreign_actor, account_state: "registered", capabilities: ["registration_handoff"])
            )
          end

          @backend.registration_destination = "https://evil.example/collect"
          assert_raises(contracts::Invalid) do
            port.call(
              action: "registration",
              context: context(capabilities: ["registration_handoff"])
            )
          end
        end

        test "accepts same-origin HTTPS destinations for a channel-safe handoff" do
          @backend.registration_destination = "https://handoff.example.org/users/sign_up"

          result = port.call(
            action: "registration",
            context: context(capabilities: ["registration_handoff"])
          )

          assert_equal "https://handoff.example.org/users/sign_up", result.destination
        end

        test "rejects an HTTPS destination on a different origin port" do
          @backend.registration_destination = "https://handoff.example.org:444/users/sign_up"

          assert_raises(contracts::Invalid) do
            port.call(
              action: "registration",
              context: context(capabilities: ["registration_handoff"])
            )
          end
        end

        test "rejects numeric deadlines instead of treating monotonic time as a duration" do
          trusted = contracts::TrustedContext.new(
            organization_id: @organization.id,
            conversation_key: "c" * 64,
            account_state: "anonymous",
            capabilities: ["registration_handoff"],
            now: @now,
            deadline: 30
          )

          result = port.call(action: "registration", context: trusted)

          assert_equal "unavailable", result.account_state
          assert_equal "invalid_deadline", result.next_step
          assert_nil result.destination
        end

        test "fails closed when the shared deadline is already expired" do
          deadline = Struct.new(:deadline, :remaining_seconds, :expired?) do
            def within(_seconds) = self
          end.new(Time.current, 0.0, true)

          result = port.call(
            action: "registration",
            context: context(capabilities: ["registration_handoff"], deadline:)
          )

          assert_equal "unavailable", result.account_state
          assert_equal "deadline_exceeded", result.next_step
          assert_nil result.destination
        end

        private

        def port
          RegistrationPort.new(organization: @organization, backend: @backend)
        end

        def real_backend
          RegistrationPort::Backend.new(organization: @organization)
        end

        def with_phone_first_registration(value)
          previous = Decidim::Bih.phone_first_registration
          Decidim::Bih.phone_first_registration = value
          yield
        ensure
          Decidim::Bih.phone_first_registration = previous
        end

        def assert_no_registration_writes
          before_jobs = enqueued_jobs.map(&:object_id)
          write_operations = []
          ActiveSupport::Notifications.subscribed(
            lambda do |_name, _start, _finish, _id, payload|
              operation = write_sql_operation(payload[:sql] || payload["sql"])
              write_operations << operation if operation
            end,
            "sql.active_record"
          ) { yield }

          assert_empty write_operations, "registration resolver issued a database write"
          assert_equal before_jobs, enqueued_jobs.map(&:object_id), "registration resolver changed the job queue"
        end

        def write_sql_operation(sql)
          normalized = sql.to_s.gsub(%r{/\*.*?\*/}m, " ").gsub(/--[^\n]*/, " ")
          normalized.match(/\b(INSERT|UPDATE|DELETE)\b/i)&.captures&.first
        end

        def context(actor: nil, account_state: "anonymous", capabilities: [], deadline: nil)
          contracts::TrustedContext.new(
            organization_id: @organization.id,
            conversation_key: "b" * 64,
            actor_id: actor&.id,
            account_state:,
            capabilities:,
            now: @now,
            deadline:
          )
        end

        def contracts
          Decidim::Bih::Concierge::Dialogue::Contracts
        end
      end
    end
  end
end
