# frozen_string_literal: true

module DecidimApp
  # Browser boundary for an Instagram/Messenger registration handoff. GET only
  # previews; POST atomically claims the opaque credential and stores an
  # unverified, expiring phone prefill with no sign-in or authorization power.
  class SocialRegistrationHandoffsController < Decidim::ApplicationController
    PREVIEW_SESSION_KEY = :mi_social_registration_handoff_preview

    skip_before_action :store_current_location
    before_action :protect_handoff_response

    def show
      if params.has_key?(:social_handoff)
        remember_preview
        return redirect_to social_registration_handoff_path
      end

      preview = session[PREVIEW_SESSION_KEY]
      return render :invalid, status: :unprocessable_entity unless handoff_store.available? && preview.is_a?(Hash)

      payload = handoff_store.peek(token: preview["token"], organization: current_organization)
      render :invalid, status: :unprocessable_entity unless payload
    end

    def create
      preview = session.delete(PREVIEW_SESSION_KEY)
      payload = claim_preview(preview)
      return render :invalid, status: :unprocessable_entity unless payload

      session[Decidim::Bih::SocialRegistrationPrefill::SESSION_KEY] = {
        "phone" => payload.fetch("phone"),
        "organization_id" => current_organization.id,
        "expires_at" => payload.fetch("expires_at")
      }
      redirect_to "/registracija"
    end

    private

    def handoff_store
      DecidimApp::Bijeljina::SocialRegistrationHandoff
    end

    def claim_preview(preview)
      return unless handoff_store.available?
      return unless preview.is_a?(Hash)
      return unless preview["organization_id"].to_i == current_organization.id

      expires_at = Time.zone.parse(preview.fetch("expires_at").to_s)
      return unless expires_at&.future?

      handoff_store.claim(token: preview.fetch("token"), organization: current_organization)
    rescue ArgumentError, KeyError, TypeError
      nil
    end

    # Move the credential out of the URL before any shared layout renders
    # canonical/alternate URLs or social metadata. This remains a read-only
    # preview: browser link scanners never consume the Redis handoff.
    def remember_preview
      session.delete(PREVIEW_SESSION_KEY)
      return unless handoff_store.available?

      payload = handoff_store.peek(token: params[:social_handoff], organization: current_organization)
      return unless payload

      session[PREVIEW_SESSION_KEY] = {
        "token" => params[:social_handoff].to_s,
        "organization_id" => current_organization.id,
        "expires_at" => payload.fetch("expires_at")
      }
    end

    def protect_handoff_response
      response.set_header("Cache-Control", "no-store, private")
      response.set_header("Pragma", "no-cache")
      response.set_header("Referrer-Policy", "no-referrer")
      response.set_header("X-Robots-Tag", "noindex, nofollow")
    end
  end
end
