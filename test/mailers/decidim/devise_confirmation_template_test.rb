# frozen_string_literal: true

require "test_helper"

class DecidimDeviseConfirmationTemplateTest < ActiveSupport::TestCase
  test "fresh namespaced mailer prefix renders confirmation for exactly the pending address" do
    organization = create_organization
    user = FactoryBot.create(:user, :confirmed, organization:, locale: "sr")
    user.unconfirmed_email = "new-address@example.invalid"
    proof_before = Decidim::Bih::EmailConfirmation.confirmed?(user)
    data_before = user.extended_data.deep_dup
    mailer = Decidim::DecidimDeviseMailer.new
    mailer.stub(:_prefixes, ["decidim/decidim_devise_mailer"]) do
      mailer.process(:confirmation_instructions, user, "synthetic-confirmation-token", to: user.unconfirmed_email)
    end
    mail = mailer.message
    assert_equal ["new-address@example.invalid"], mail.to
    html = (mail.html_part || mail).body.decoded
    assert_includes html, "confirmation_token=synthetic-confirmation-token"
    assert_includes html, organization.host
    assert_equal proof_before, Decidim::Bih::EmailConfirmation.confirmed?(user.reload)
    assert_equal data_before, user.extended_data
  end

  test "default and proof mail delivery jobs omit credential arguments from Rails logging" do
    assert_not ActionMailer::MailDeliveryJob.log_arguments
    assert_not Decidim::Bih::EmailConfirmationDeliveryJob.log_arguments
  end
end
