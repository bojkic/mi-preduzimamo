# frozen_string_literal: true

module DecidimApp
  class LaunchEventLinksController < Decidim::ApplicationController
    include Decidim::Bih::CompletesPhoneAuthentication
    layout "decidim_app/launch_event_link"
    skip_before_action :store_current_location
    before_action :protect_link
    before_action :load_delivery

    def show
      return redirect_to(@delivery.destination) if @delivery.consumed_at && current_user == @delivery.user
      return invalid_link if @delivery.consumed_at

      @message = LaunchEvent::MESSAGES.fetch(@delivery.message_key)
    end

    def consume
      return redirect_to(@delivery.destination) if @delivery.consumed_at && current_user == @delivery.user

      completed = complete_phone_authentication(
        user: @delivery.user, purpose: "login", destination: @delivery.destination,
        grant: -> { LaunchEvent.valid_link_recipient?(@delivery) },
        consume: lambda do
          @delivery.user.with_lock do
            LaunchEvent.valid_link_recipient?(@delivery) && @delivery.claim_token!
          end
        end
      )
      invalid_link unless completed
    end

    private

    # These event links validate an existing recipient and carry a fixed map or
    # poll destination. Preserve that established event handoff across sign-in.
    def phone_first_onboarding_chain? = false

    def protect_link
      response.cache_control.replace(no_store: true, private: true)
      response.set_header("Pragma", "no-cache")
      response.set_header("Referrer-Policy", "strict-origin")
      response.set_header("X-Robots-Tag", "noindex, nofollow")
    end

    def load_delivery
      @delivery = LaunchEventDelivery.where(organization: current_organization)
                                     .where(status: %w(sending accepted delivered unknown))
                                     .where("expires_at > ?", Time.current)
                                     .find_by(token_digest: Digest::SHA256.hexdigest(params[:token].to_s))
      invalid_link unless @delivery && LaunchEvent.valid_link_recipient?(@delivery)
    end

    def invalid_link
      render :invalid, status: :unprocessable_entity
    end
  end
end
