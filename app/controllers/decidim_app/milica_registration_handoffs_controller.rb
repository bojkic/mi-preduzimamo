# frozen_string_literal: true

module DecidimApp
  class MilicaRegistrationHandoffsController < Decidim::ApplicationController
    include Decidim::Bih::CurrentOrganizationUser
    skip_before_action :store_current_location

    def show
      response.set_header("Cache-Control", "no-store, private")
      response.set_header("Referrer-Policy", "no-referrer")
      response.set_header("X-Robots-Tag", "noindex, nofollow")
      destination = Bijeljina::Milica::RegistrationHandoff.new(organization: current_organization).start(
        session:, user: current_organization_user, secret: Rails.application.secret_key_base
      )
      # This URL has no token or arbitrary return parameter. The saved target
      # came from RegistrationPort, and the controller still restricts it to
      # known local authentication routes rather than trusting stored URLs.
      permitted = ["/users/sign_in", Decidim::Bih.registration_path,
                   "/sms/authorizations/new", Decidim::Bih.public_path("verifikacija/telefon")]
      redirect_to(permitted.include?(destination) ? destination : recovery_destination)
    end

    private

    # No usable ticket. That is the ORDINARY case for a citizen who came back
    # an hour later, opened the link in another browser, or whose conversation
    # moved on — not an attack, and not a reason to walk everyone through
    # new-account registration.
    #
    # The purpose is recovered from the only authority left, the account
    # itself: a signed-in citizen continues their own onboarding step, and an
    # anonymous visitor is offered sign-in with the conversation saved as the
    # place to return to. Anything the port does not recognise falls back to
    # the chat, which is where the citizen came from.
    def recovery_destination
      port = Bijeljina::Milica::RegistrationPort.new(organization: current_organization)
      candidate = port.recovery_destination(current_organization_user)
      return chat_destination unless port.recovery_allowed?(candidate)

      store_location_for(:user, chat_destination) if current_organization_user.nil?
      candidate
    rescue StandardError => e
      Rails.logger.warn("[MilicaRegistrationHandoff] recovery #{e.class.name}") if defined?(Rails) && Rails.respond_to?(:logger)
      chat_destination
    end

    def chat_destination = Decidim::Bih.public_path("mi-bot")
  end
end
