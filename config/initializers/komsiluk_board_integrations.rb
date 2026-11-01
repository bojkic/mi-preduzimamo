# frozen_string_literal: true

Rails.application.config.to_prepare do
  Decidim::Bih::Komsiluk::PostModeration.integration = DecidimApp::Bijeljina::CityServiceBoardModeration
  Decidim::Bih::Komsiluk::NoticePhonePolicy.source_blocker = DecidimApp::Bijeljina::CityServiceBoardVisibility.method(:phone_blocker)
  Decidim::Bih::Komsiluk::NoticePhonePolicy.source_dispatch_guard = DecidimApp::Bijeljina::CityServiceBoardVisibility.method(:dispatch)
  Decidim::Bih::Komsiluk::NoticeComposer.source_provider = DecidimApp::Bijeljina::KomsilukNoticeSources
  Decidim::Bih::Komsiluk::DeliveryOperations.source_provider = DecidimApp::Bijeljina::KomsilukDeliveryOperations
  DecidimApp::Bijeljina::KomsilukSourceProjectionRefresh.install!
  Decidim::Bih.komsiluk_board_context_provider = DecidimApp::Bijeljina::KomsilukBoardContext
  Decidim::Bih.komsiluk_notice_public_source_provider = DecidimApp::Bijeljina::KomsilukNoticePublicSource
end
