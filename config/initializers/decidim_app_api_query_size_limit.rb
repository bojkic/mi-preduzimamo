# frozen_string_literal: true

Rails.application.config.to_prepare do
  mod = DecidimApp::ApiQuerySizeLimit
  Decidim::Api::QueriesController.prepend(mod) unless Decidim::Api::QueriesController.ancestors.include?(mod)
end
