# frozen_string_literal: true

module DecidimApp
  # Legacy direct city-data URLs. Host-only city-service information should not
  # be anonymously browsable; citizens get those answers through MI bot, while
  # operators inspect the underlying snapshots from the admin integrations page.
  class CityPagesController < Decidim::ApplicationController
    def waste
      redirect_to decidim_bih.mi_bot_path, status: :moved_permanently
    end

    def budget
      redirect_to decidim_bih.mi_bot_path, status: :moved_permanently
    end
  end
end
