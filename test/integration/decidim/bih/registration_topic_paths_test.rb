# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class RegistrationTopicPathsTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers

      setup do
        @organization = create_organization
        host! @organization.host
      end

      test "new OAuth accounts initialize all topics from checked and unchecked forms" do
        [true, false].each do |enabled|
          form = oauth_form(enabled:)
          user = nil
          Decidim::CreateOmniauthRegistration.call(form, form.email) { on(:ok) { |created| user = created } }
          assert user
          TopicPreferences::TOPICS.each { |topic| assert_equal enabled, TopicPreferences.enabled?(user, topic:) }
        end
      end

      test "OAuth account linking and subsequent login preserve existing topic choices" do
        user = FactoryBot.create(:user, :confirmed, organization: @organization)
        TopicPreferences.set_all!(user, enabled: false)
        form = oauth_form(enabled: true, email: user.email)
        Decidim::CreateOmniauthRegistration.call(form, user.email)
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
        TopicPreferences.set!(user, topic: :community_news, enabled: true)
        Decidim::CreateOmniauthRegistration.call(form, user.email)
        assert TopicPreferences.enabled?(user, topic: :community_news)
        assert_not TopicPreferences.enabled?(user, topic: :report_updates)
      end

      test "failed OAuth topic initialization rolls back the new user and identity" do
        form = oauth_form(enabled: false)
        failed = false
        TopicPreferences.stub(:set_all!, ->(user, **) { raise ActiveRecord::RecordInvalid, user }) do
          Decidim::CreateOmniauthRegistration.call(form, form.email) { on(:error) { failed = true } }
        end
        assert failed
        assert_not Decidim::User.exists?(organization: @organization, email: form.email)
        assert_not Decidim::Identity.exists?(provider: form.provider, uid: form.uid)
      end

      test "invitation form starts checked and preserves an unchecked validation response" do
        user, token = invitation
        get "/sr/users/invitation/accept", params: { invitation_token: token }
        assert_response :success
        assert_select "#mi-invitation-notifications[checked]", count: 1
        assert_select "details.mi-notification-registration-details summary", count: 1
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "0").merge(password: "short") }
        assert_response :forbidden # Decidim Devise responder uses 403 for invalid invitation forms.
        assert_select "#mi-invitation-notifications[checked]", count: 0
        assert_nil user.reload.invitation_accepted_at
      end

      test "invitation acceptance initializes all four topics including explicit false" do
        [true, false].each do |enabled|
          user, token = invitation
          put "/sr/users/invitation", params: { user: invitation_params(user, token, enabled ? "1" : "0") }
          assert_response :redirect
          assert user.reload.invitation_accepted_at
          TopicPreferences::TOPICS.each { |topic| assert_equal enabled, TopicPreferences.enabled?(user, topic:) }
          assert_equal enabled, user.newsletter_notifications_at.present?
          sign_out user
        end
      end

      test "failed invitation topic initialization rolls back accepting the invitation" do
        user, token = invitation
        TopicPreferences.stub(:set_all!, ->(record, **) { raise ActiveRecord::RecordInvalid, record }) do
          put "/sr/users/invitation", params: { user: invitation_params(user, token, "0") }
        end
        assert_response :forbidden # Decidim Devise responder uses 403 for invalid invitation forms.
        assert_nil user.reload.invitation_accepted_at
        assert user.invitation_token.present?
        TopicPreferences::TOPICS.each { |topic| assert TopicPreferences.enabled?(user, topic:) }
      end

      test "reusing an accepted invitation cannot reset notification preferences" do
        user, token = invitation
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "1") }
        assert user.reload.invitation_accepted_at
        sign_out user
        TopicPreferences.set_all!(user, enabled: false)
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "1") }
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
      end

      test "a new invitation token for an existing account preserves its topic choices" do
        user, token = invitation
        user.update!(invitation_accepted_at: 1.day.ago, sign_in_count: 1)
        TopicPreferences.set_all!(user, enabled: false)
        get "/sr/users/invitation/accept", params: { invitation_token: token }
        assert_response :success
        assert_select "#mi-invitation-notifications", count: 0
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "1") }
        assert_response :redirect
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
      end

      test "an invited account with an existing topic choice preserves it before its first sign in" do
        user, token = invitation
        TopicPreferences.set_all!(user, enabled: false)
        get "/sr/users/invitation/accept", params: { invitation_token: token }
        assert_response :success
        assert_select "#mi-invitation-notifications", count: 0
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "1") }
        assert_response :redirect
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
      end

      test "migration defaults on an unaccepted invitation still allow a first registration choice" do
        user, token = invitation
        TopicPreferences.set_all!(user, enabled: true, source: "organization_default")
        get "/sr/users/invitation/accept", params: { invitation_token: token }
        assert_response :success
        assert_select "#mi-invitation-notifications[checked]", count: 1
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "0") }
        assert_response :redirect
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
      end

      test "an invitation token from another organization cannot change its account" do
        user, token = invitation(organization: create_organization)
        put "/sr/users/invitation", params: { user: invitation_params(user, token, "0") }
        assert_nil user.reload.invitation_accepted_at
        TopicPreferences::TOPICS.each { |topic| assert TopicPreferences.enabled?(user, topic:) }
      end

      private

      def oauth_form(enabled:, email: "oauth-#{SecureRandom.hex(4)}@example.org")
        provider = "facebook"
        uid = SecureRandom.hex(8)
        Decidim::OmniauthRegistrationForm.from_params(
          email:, name: "Nova Gradjanka", provider:, uid:, newsletter: enabled,
          tos_agreement: true, oauth_signature: Decidim::OmniauthRegistrationForm.create_signature(provider, uid), raw_data: {}
        ).with_context(current_organization: @organization)
      end

      def invitation(organization: @organization)
        user = FactoryBot.create(:user, :confirmed, organization:)
        raw, digest = ::Devise.token_generator.generate(Decidim::User, :invitation_token)
        user.update!(invitation_token: digest, invitation_created_at: Time.current,
                     invitation_sent_at: Time.current, invitation_accepted_at: nil)
        [user, raw]
      end

      def invitation_params(user, token, newsletter)
        { invitation_token: token, nickname: user.nickname, password: "Stronger-password-2026",
          password_confirmation: "Stronger-password-2026", tos_agreement: "1", newsletter_notifications: newsletter }
      end
    end
  end
end
