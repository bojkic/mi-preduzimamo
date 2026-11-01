# frozen_string_literal: true

require "test_helper"
require "capybara"
require "yaml"

module Decidim
  module Bih
    # Locks the host-side decision (5.9.2026): this deployment runs the engine's
    # phone-first registration, so the account is usable the moment it is
    # created, the phone carries identity, and the e-mail address is merely
    # stored until it is separately proven.
    #
    # These checks are deliberately about the HOST's configuration and copy, not
    # about the engine's internals: the engine ships phone-first switched OFF and
    # its own suite covers the mechanics. What can only break here is the host
    # forgetting to flip the switch, getting the cutoff wrong, or losing the
    # approved registration SMS copy while preserving the engine-owned Viber text.
    class PhoneFirstRegistrationTest < ActionDispatch::IntegrationTest
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "the host runs phone-first registration with a cutoff in the past" do
        assert Decidim::Bih.phone_first_registration

        # Pinned, not merely "a Time". Two ways to get this wrong, both quiet:
        # a nil cutoff makes EmailConfirmation#grandfathered? fail closed (every
        # pre-existing account loses password recovery), and a cutoff in the
        # FUTURE fails open the other way — every account created before it,
        # including brand-new phone-first ones, counts as e-mail-proven.
        # Task 19 replaces this with the real deploy instant, in UTC.
        assert_equal Time.utc(2026, 9, 5, 0, 0, 0), Decidim::Bih.phone_first_registration_cutoff
      end

      # Isporuka D: sign-up is one step and it happens at /registracija.
      # Decidim's /users is a 302 to it (see one_step_registration_test.rb), so
      # these go through the path a real citizen now uses.
      test "sign-up activates the account and continues to the pending page" do
        email = "petar-first-#{SecureRandom.hex(3)}@example.org"

        register!(email:)

        assert_redirected_to Decidim::Bih.registration_path_for("/potvrda")
        user = Decidim::User.find_by(organization: @organization, email: "")
        assert_predicate user, :confirmed?
        assert_not Decidim::Bih::EmailConfirmation.confirmed?(user), "the address is activated, not proven"
      end

      test "no confirmation e-mail is enqueued on sign-up" do
        email = "petar-#{SecureRandom.hex(3)}@example.org"

        assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
          register!(email:)
        end

        # Without this, the test would also pass if the registration had simply
        # failed — no account, and therefore no mail either.
        assert Decidim::User.exists?(organization: @organization, email: ""), "the sign-up must have succeeded"
      end

      test "registration SMS and Viber copy remain engine-owned without host overrides" do
        # The September 7 evening policy supersedes the branded SMS override
        # with the engine's one-segment text. Compare raw engine YAML with runtime
        # I18n to catch load-order mistakes; neither channel may be shadowed here.
        [:sr, :"sr-Cyrl", :bs, :hr, :en].each do |locale|
          assert_nil host_copy(locale, "verification_link"), "SMS must not have a host override (#{locale})"
          assert_nil host_copy(locale, "viber_verify_link"), "Viber must not have a host override (#{locale})"
          sms_expected = format(engine_copy(locale, "verification_link"), url: "U", code: "C")
          viber_expected = format(engine_copy(locale, "viber_verify_link"), url: "U", code: "C")

          assert_equal sms_expected,
                       I18n.t("decidim.bih.sms.verification_link", locale:, url: "U", code: "C"),
                       "decidim.bih.sms.verification_link (#{locale}) must remain engine-owned"
          assert_equal viber_expected,
                       I18n.t("decidim.bih.sms.viber_verify_link", locale:, url: "U", code: "C"),
                       "decidim.bih.sms.viber_verify_link (#{locale}) must remain engine-owned"
        end
      end

      test "simplified registration keeps topics off until the explicit komsiluk choice" do
        [true, false].each do |enabled|
          @organization = create_organization
          host! @organization.host
          email = "topics-#{SecureRandom.hex(4)}@example.org"
          register!(email:, newsletter: enabled ? "1" : "0")
          assert_redirected_to Decidim::Bih.registration_path_for("/potvrda")
          user = Decidim::User.find_by!(organization: @organization, email: "")
          Decidim::Bih::TopicPreferences::TOPICS.each do |topic|
            assert_not Decidim::Bih::TopicPreferences.enabled?(user, topic:), topic
          end
          assert_equal "all", user.notification_types
          assert_nil user.newsletter_notifications_at
        end
      end

      test "core registration commits all topic choices with the account for both registration modes" do
        original_mode = Decidim::Bih.phone_first_registration
        [true, false].each do |phone_first|
          Decidim::Bih.phone_first_registration = phone_first
          [true, false].each do |enabled|
            email = "core-topics-#{SecureRandom.hex(4)}@example.org"
            form = Decidim::RegistrationForm.from_params(
              name: "Nova Gradjanka", email:, password: "Stronger-password-2026",
              current_locale: "sr", tos_agreement: "1", newsletter: enabled ? "1" : "0"
            ).with_context(current_organization: @organization)
            created = nil
            Decidim::CreateRegistration.call(form) { on(:ok) { |user| created = user } }
            assert created, form.errors.full_messages.join(", ")
            assert_equal phone_first, created.confirmed?
            Decidim::Bih::TopicPreferences::TOPICS.each do |topic|
              assert_equal enabled, Decidim::Bih::TopicPreferences.enabled?(created, topic:)
            end
          end
        end
      ensure
        Decidim::Bih.phone_first_registration = original_mode
      end

      test "failed core topic initialization rolls back account creation" do
        email = "core-rollback-#{SecureRandom.hex(4)}@example.org"
        form = Decidim::RegistrationForm.from_params(
          name: "Nova Gradjanka", email:, password: "Stronger-password-2026",
          current_locale: "sr", tos_agreement: "1", newsletter: "0"
        ).with_context(current_organization: @organization)
        failed = false
        writer = ->(user, **) { raise ActiveRecord::RecordInvalid, user }
        Decidim::Bih::TopicPreferences.stub(:set_all!, writer) do
          Decidim::CreateRegistration.call(form) { on(:invalid) { failed = true } }
        end
        assert failed
        assert_not Decidim::User.exists?(organization: @organization, email:)
      end

      private

      # One registration through the one-step form. The komšiluk is required by
      # Decidim::Bih::PhoneRegistrationForm — it is the field that puts the new
      # citizen on the trka komšiluka board on day one.
      def register!(email:, newsletter: "1")
        komsiluk = Decidim::Bih::LocalArea.create!(
          decidim_organization_id: @organization.id,
          kind: "komsiluk",
          slug: "k-#{SecureRandom.hex(4)}",
          name: { "sr" => "Test komšiluk" }
        )

        post Decidim::Bih.registration_path_for, params: {
          user: {
            name: "Petar Gradjanin",
            email:,
            # A fixed number is safe: PhoneRegistrationForm's uniqueness check
            # is organization-scoped and each test here has its own.
            mobile_phone_number: "+38765123456",
            komsiluk_id: komsiluk.id,
            tos_agreement: "1",
            newsletter:
          }
        }
      end

      def engine_copy(locale, key)
        @engine_copy ||= {}
        @engine_copy[locale] ||= YAML.load_file(
          Decidim::Bih::Engine.root.join("config/locales/#{locale}.yml"),
          aliases: true
        ).fetch(locale.to_s).fetch("decidim").fetch("bih").fetch("sms")

        @engine_copy[locale].fetch(key)
      end

      def host_copy(locale, key)
        @host_copy ||= {}
        @host_copy[locale] ||= YAML.load_file(
          Rails.root.join("config/locales/decidim_bih_bijeljina_copy.yml"),
          aliases: true
        ).fetch(locale.to_s).fetch("decidim").fetch("bih").fetch("sms")

        @host_copy[locale].fetch(key, nil)
      end
    end
  end
end
