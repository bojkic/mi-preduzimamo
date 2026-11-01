# frozen_string_literal: true

require "decidim/bih/locale_path"

module MiSearchHelper
  # Explicit public destinations: never infer indexability from an authenticated URL.
  SITEMAP_PATHS = %w(/ /trka /ko-smo /pitanja /moderacija /neutralnost /processes /biceriseno/mi-bot /biceriseno/vodic).freeze
  PRIVATE_PATH = %r{
    \A/(?:users|account|admin|sidekiq|registracija|notifications_settings|notifications|v|p|milica/prijava|u-komsiluku|lansiranje/anketa|search|profiles|
    biceriseno/(?:prijave/new|prijave/[^/]+/status|potvrdi-email|service-evidence|
    prijava|komsiluk|komsiluk-board|verifikacija|moj-nalog|moj-doprinos|chat))(?:/|$)
  }x

  def mi_search_home?
    Decidim::Bih::LocalePath.strip(request.path) == "/"
  end

  def mi_search_noindex?
    request.path == "/biceriseno" || Decidim::Bih::LocalePath.strip(request.path).match?(PRIVATE_PATH) || request.query_parameters.keys.any? do |key|
      key.match?(/token|ticket|code|email|phone|redirect|filter|search|query/i)
    end
  end

  def mi_search_url(locale: nil)
    path = request.path == "/biceriseno" ? "/biceriseno/prijave/new" : request.path
    query = {}
    selected_locale = locale || request.query_parameters["locale"]
    if Decidim::Bih::LocalePath.strip(path) != path
      selected_locale = I18n.locale unless available_locales.map(&:to_s).include?(selected_locale.to_s)
      suffix = Decidim::Bih::LocalePath.strip(path)
      path = "/#{selected_locale}#{suffix == '/' ? '' : suffix}"
    else
      query[:locale] = selected_locale if available_locales.map(&:to_s).include?(selected_locale.to_s)
    end
    page = request.query_parameters["page"]
    query[:page] = page if page.is_a?(String) && page.match?(/\A[1-9]\d*\z/) && page != "1"
    "https://#{current_organization.host}#{path}#{query.empty? ? "" : "?#{query.to_query}"}"
  end

  def mi_search_description
    existing = decidim_meta_description.to_s.strip
    return truncate(strip_tags(existing).squish, length: 180) if existing.present?

    fallback = I18n.t("mi_search.description")
    mi_search_home? ? fallback : truncate("#{decidim_page_title}. #{fallback}", length: 180)
  end

  def mi_search_schema
    origin = "https://#{current_organization.host}"
    {
      "@context" => "https://schema.org",
      "@graph" => [
        { "@type" => "WebSite", "@id" => "#{origin}/#website", "url" => "#{origin}/", "name" => current_organization_name, "alternateName" => "MI preduzimamo",
          "publisher" => { "@id" => "#{origin}/#organization" } },
        { "@type" => "Organization", "@id" => "#{origin}/#organization", "name" => current_organization_name,
          "url" => "#{origin}/", "logo" => "#{origin}/mi/heart-mark.png" }
      ]
    }
  end
end
