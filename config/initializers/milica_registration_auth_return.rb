# frozen_string_literal: true

Rails.application.config.to_prepare do
  phone = DecidimApp::MilicaRegistrationAuthReturn::Phone
  devise = DecidimApp::MilicaRegistrationAuthReturn::Devise
  Decidim::Bih::CompletesPhoneAuthentication.prepend(phone) unless Decidim::Bih::CompletesPhoneAuthentication.ancestors.include?(phone)
  Decidim::Devise::SessionsController.prepend(devise) unless Decidim::Devise::SessionsController.ancestors.include?(devise)
end
