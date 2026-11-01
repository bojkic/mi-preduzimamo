# frozen_string_literal: true

module DecidimApp
  module MilicaRegistrationAuthReturn
    # Phone backend resets the browser session only after grant/claim success.
    # Preserve exactly this bound ticket, not the old chat, CSRF or auth data.
    module Phone
      def complete_phone_authentication(**arguments)
        entry = session[Bijeljina::Milica::RegistrationHandoff::SESSION_KEY]
        completed = super
        if completed == true && entry && user_signed_in? && current_user == arguments[:user]
          Bijeljina::Milica::RegistrationHandoff.new(organization: current_organization)
                                                .authenticated(entry:, session:, user: current_user)
        end
        completed
      end
    end

    # Keep Devise's TOS/password/onboarding destination exactly as returned by
    # the existing owner. Opening Milica later performs the one-use resumption.
    module Devise
      def after_sign_in_path_for(user)
        destination = super
        entry = session[Bijeljina::Milica::RegistrationHandoff::SESSION_KEY]
        if entry && user_signed_in? && current_user == user
          Bijeljina::Milica::RegistrationHandoff.new(organization: current_organization)
                                                .authenticated(entry:, session:, user:)
        end
        destination
      end
    end
  end
end
