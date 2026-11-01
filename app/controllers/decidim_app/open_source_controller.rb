# frozen_string_literal: true

module DecidimApp
  class OpenSourceController < Decidim::ApplicationController
    def show
      @release = DecidimApp::OpenSourceRelease.new
    end
  end
end
