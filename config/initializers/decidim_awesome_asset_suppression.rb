# frozen_string_literal: true

# Decidim Awesome injects its global public packs into every public page through
# a Deface override. The custom Biceriseno engine pages do not use those DOM
# hooks and load their own small scripts/styles. The MI homepage also uses only
# core controllers and MI content blocks. Skip only the global Awesome
# packs there. Normal Decidim pages, admin pages, and component-specific Awesome
# assets continue to load unchanged.
module DecidimApp
  module Bijeljina
    module DecidimAwesomeAssetSuppression
      SUPPRESSED_PACKS = %w(
        decidim_decidim_awesome
        decidim_decidim_awesome_custom_fields
      ).freeze

      def append_stylesheet_pack_tag(*names, **)
        filtered = filter_decidim_awesome_packs(names)
        return if filtered.empty?

        super(*filtered, **)
      end

      def append_javascript_pack_tag(*names, **)
        filtered = filter_decidim_awesome_packs(names)
        return if filtered.empty?

        super(*filtered, **)
      end

      private

      def filter_decidim_awesome_packs(names)
        return names unless suppress_decidim_awesome_assets?

        names.reject { |name| SUPPRESSED_PACKS.include?(name.to_s) }
      end

      def suppress_decidim_awesome_assets?
        path = request&.path.to_s

        path == "/" || path == "/biceriseno" || path.start_with?("/biceriseno/")
      end
    end
  end
end

ActiveSupport.on_load(:action_view) do
  prepend DecidimApp::Bijeljina::DecidimAwesomeAssetSuppression
end
