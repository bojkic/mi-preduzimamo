# frozen_string_literal: true

# Remix icon for the FAQ-answers admin menu item. Registered after_initialize,
# exactly like decidim-bih's MI_ICONS block: core's and decidim_awesome's
# register_icons initializers have run by then, so the "already registered"
# guard is meaningful and we never re-register a name they own.
Rails.application.config.after_initialize do
  { "chat-quote-line" => "Milica FAQ answers (admin content editor)" }.each do |name, description|
    next if Decidim.icons.all.has_key?(name)

    Decidim.icons.register(name:, icon: name, category: "system", description:, engine: :core)
  end
end

Decidim.menu :admin_menu do |menu|
  menu.add_item :mi_city_service_events,
                I18n.t("decidim_app.admin.city_service_events.menu"),
                Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_path,
                icon_name: "pulse-line",
                position: 9.95,
                active: [%w(decidim_app/admin/city_service_events), []],
                if: Decidim::Bih::OperatorAuthorization.allowed?(
                  current_user,
                  :city_alerts_manage,
                  organization: current_organization
                )
  menu.add_item :mi_city_service_entries,
                I18n.t("decidim_app.admin.city_service_entries.menu"),
                Rails.application.routes.url_helpers.decidim_app_admin_city_service_entries_path,
                icon_name: "chat-quote-line",
                position: 9.96,
                active: [%w(decidim_app/admin/city_service_entries decidim_app/admin/foundation_status), []],
                if: Decidim::Bih::OperatorAuthorization.allowed?(
                  current_user,
                  :city_alerts_manage,
                  organization: current_organization
                )
end

Decidim::Bih.admin_navigation_provider = Class.new do
  def self.groups(**)
    [
      {
        id: "alerts",
        label: I18n.t("decidim.bih.admin.navigation.alerts", default: "Alerts and local notices"),
        items: [
          {
            id: "city_alerts",
            label: I18n.t("decidim_app.admin.city_service_events.menu"),
            url: Rails.application.routes.url_helpers.decidim_app_admin_city_service_events_path,
            description: I18n.t("decidim_app.admin.city_service_events.navigation_description",
                                default: "Review collected city-service notices before publishing them."),
            permission: :city_alerts_manage
          },
          {
            id: "city_service_entries",
            label: I18n.t("decidim_app.admin.city_service_entries.menu"),
            url: Rails.application.routes.url_helpers.decidim_app_admin_city_service_entries_path,
            description: I18n.t("decidim_app.admin.city_service_entries.navigation_description"),
            permission: :city_alerts_manage
          },
          {
            id: "foundation_status",
            label: I18n.t("decidim_app.admin.foundation_status.menu"),
            url: Rails.application.routes.url_helpers.decidim_app_admin_foundation_status_path,
            description: I18n.t("decidim_app.admin.foundation_status.navigation_description"),
            permission: :city_alerts_manage
          }
        ]
      }
    ]
  end
end
