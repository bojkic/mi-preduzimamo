# frozen_string_literal: true

module DecidimApp
  # Decidim only ships an HTML template for the 404 page, so scanner probes
  # for /x.json, /x.xml, /x.yaml or /x.txt raised MissingTemplate and were
  # logged as 500s after a full layout/query round trip. Answer them with a
  # bare 404; the HTML page, also for a wildcard Accept, is untouched.
  module NonHtmlNotFound
    def not_found
      return super if html_or_wildcard?

      head :not_found
    end

    private

    # A bare Accept: */* (curl, wget, link-preview fetchers) has always been
    # answered with the HTML 404 page; keep that. Only explicit non-HTML
    # formats (.json/.xml/.yaml/.txt or the matching Accept) get a bodyless 404.
    def html_or_wildcard?
      request.format&.html? || request.format.to_s == "*/*"
    end
  end
end
