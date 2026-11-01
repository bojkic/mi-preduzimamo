# frozen_string_literal: true

module DecidimApp
  # Keep host/community pages on their existing routes. Core 0.32 prefixes its
  # own routes, while the host and public BIH engine select locale by query.
  class LocalesController < Decidim::LocalesController
    private

    def canonical_url(url, desired_locale)
      uri = URI.parse(url)
      return super("/", desired_locale) unless local_reference?(uri)

      path = uri.path.presence || "/"
      route = Rails.application.routes.recognize_path(path, method: :get)
      return super unless route[:controller].to_s.start_with?("decidim_app/", "decidim/bih/")

      query = Rack::Utils.parse_nested_query(uri.query.to_s).merge("locale" => desired_locale.to_s)
      "#{path}?#{query.to_query}"
    rescue URI::InvalidURIError, ActionController::RoutingError
      super("/", desired_locale)
    end

    def local_reference?(uri)
      return false if uri.userinfo || (uri.scheme && !%w(http https).include?(uri.scheme))
      return true unless uri.host

      uri.host == request.host && uri.port == request.port && uri.scheme == request.scheme
    end
  end
end
