# frozen_string_literal: true

Rails.application.config.to_prepare do
  mod = DecidimApp::NonHtmlNotFound
  Decidim::ErrorsController.prepend(mod) unless Decidim::ErrorsController.ancestors.include?(mod)
end
