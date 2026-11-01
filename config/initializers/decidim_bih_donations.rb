# frozen_string_literal: true

# Bez sopstvene kompletne konfiguracije nema donacijskog adaptera.
require_relative "../../app/services/decidim_app/bijeljina/donations"
provider = DecidimApp::Bijeljina::Donations
Decidim::Bih.donations_provider = provider.configured? ? provider : nil
