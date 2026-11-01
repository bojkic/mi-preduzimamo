# frozen_string_literal: true

module DecidimApp
  # The static launch-campaign pages. Copy is client-final and lives in
  # config/locales/decidim_bih_bijeljina_copy.yml — the views only lay it out.
  #
  # "lansiranje" (the 17.9. event page) was retired once the event happened;
  # config/routes.rb keeps its URL alive as a 302 to /trka.
  class LaunchPagesController < Decidim::ApplicationController
    # The race table on /trka reads the CACHED Race::Standing rows through the
    # same concern the hub's ?tab=trka uses — never the Scorer, never a second
    # query path that could disagree with the hub about who is leading.
    include Decidim::Bih::Concerns::CommunityHubData

    PAGES = {
      "pozivnica" => :pozivnica,
      "trka" => :trka,
      "moderacija" => :moderacija,
      "neutralnost" => :neutralnost,
      "pitanja" => :pitanja,
      "ko-smo" => :ko_smo
    }.freeze

    def show
      template = PAGES.fetch(params[:page]) { raise ActionController::RoutingError, "Unknown launch page" }
      @race_config = Decidim::Bih::Race::Config.new(organization: current_organization)
      if template == :trka
        load_race_standings
        @race_project_links = DecidimApp::Bijeljina::RaceProjectSelection.links(current_organization)
      end
      render template
    end

    private

    def load_race_standings
      @race_rows, @race_zone, @race_leaders, @race_viewer_row, @race_frozen, @race_computed_at =
        race_data(params[:zona])
      # Quoted by the invite CTA under the citizen's own row. From the
      # schedule, never a literal, so this page and BODOVNIK cannot disagree.
      @race_referral_points = Decidim::Bih::Goodwill::EarningRules.points_for_action(
        :referral, organization: current_organization
      )
    end
  end
end
