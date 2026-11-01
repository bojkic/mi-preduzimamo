# frozen_string_literal: true

# These exact templates and placeholder contracts were approved for Bijeljina.
# No generic text is silently substituted for a report reference/status pair.
Rails.application.config.to_prepare do
  Decidim::Bih::WebPush.delivery_guard = DecidimApp::Bijeljina::CityServicePlatformDeliveryGuard
  Decidim::Bih::AccountNotifications.delivery_guard = DecidimApp::Bijeljina::CityServiceDeliveryGuard
  Decidim::Bih::AccountNotifications.template_resolver = lambda do |topic:, text:, reference: nil, status: nil|
    case topic.to_s
    when "report_updates"
      if reference.present? && status.present?
        { name: "mi_status_prijave_v1", language: "sr", body: { "1" => reference.to_s, "2" => status.to_s },
          display_text: "Obavještenje platforme MI preduzimamo, Lokalna fondacija Bijeljina: tvoja prijava komunalnog problema " \
                        "broj #{reference} sada ima status #{status}. Detalje i odgovor nadležne službe možeš pogledati na svom nalogu." }
      end
    when "community_news", "neighborhood_info"
      if text.present? && text.length <= 1000
        { name: "mi_novosti_komsiluka_v1", language: "sr", body: { "1" => text.to_s },
          display_text: "Zdravo, ovdje Komšinica Milica, digitalna pomoćnica Lokalne fondacije Bijeljina. Šaljem ti novost sa platforme MI preduzimamo na koju si " \
                        "pretplaćen/a: #{text}. Više informacija je na platformi. " \
                        "Ako više ne želiš ove poruke, odgovori ODJAVA." }
      end
    end
  end
end
