# frozen_string_literal: true

module ApplicationHelper
  # Installation remains available on the authenticated registration handoff,
  # while chat and other overlays stay suppressed during neighborhood setup.
  def mi_install_suppressed?
    return false if current_user && request.path == Decidim::Bih.public_path("komsiluk") && params[:app] == "1"

    mi_overlays_suppressed?
  end

  def mi_overlays_suppressed?
    board_path = Decidim::Bih.public_path("komsiluk-board")
    return true if request.path == board_path || request.path.start_with?("#{board_path}/")

    paths = [
      "/account",
      "/notifications_settings",
      Decidim::Bih.public_path("prijava"),
      Decidim::Bih.public_path("moj-nalog"),
      Decidim::Bih.public_path("moj-nalog/poruke"),
      Decidim::Bih.public_path("komsiluk"),
      Decidim::Bih.public_path("prijave/new")
    ]
    request.path.start_with?("/users/", "/v/event-", "/lansiranje/anketa") || paths.include?(request.path)
  end
end
