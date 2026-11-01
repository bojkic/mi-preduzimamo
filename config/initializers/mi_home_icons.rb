# frozen_string_literal: true

# Cached cells can contain the old sprite URL even after helpers change. Rewrite
# only known icon references in the final homepage HTML, preserving every other
# attribute and leaving unknown symbols and all other responses untouched.
module MiHomeIcons
  MANIFEST = JSON.parse(Rails.root.join("config/mi_home_icons.json").read).freeze
  ICONS = MANIFEST.fetch("icons").freeze
  PATH = MANIFEST.fetch("path").freeze

  private

  def mi_use_home_icon_subset
    return unless request.path == "/" && response.status == 200 && response.media_type == "text/html"
    return if Decidim.cors_enabled

    response.body = response.body.gsub(/href="[^"#]*remixicon\.symbol-[^"#]+\.svg#ri-([a-z0-9-]+)"/) do |original|
      icon_name = Regexp.last_match(1)
      ICONS.include?(icon_name) ? %(href="#{PATH}#ri-#{icon_name}") : original
    end
  end
end

Rails.application.config.to_prepare do
  unless Decidim::HomepageController.ancestors.include?(MiHomeIcons)
    Decidim::HomepageController.include(MiHomeIcons)
    Decidim::HomepageController.after_action :mi_use_home_icon_subset, only: :show
  end
end
