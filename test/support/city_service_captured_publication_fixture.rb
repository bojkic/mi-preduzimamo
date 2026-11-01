# frozen_string_literal: true

# Queue/transport fixtures begin with an explicitly reviewed source event.
# Capture through the production publication API before running a worker; never
# fabricate a receipt in the worker or replace a membership/visibility guard.
module CityServiceCapturedPublicationFixture
  def capture_city_publication!(event = @event)
    namespace = DecidimApp::Bijeljina
    namespace::CityServiceIncident.synchronize(event.organization) do
      event.with_lock do
        namespace::CityServiceIncidentIdentity.attach!(event)
        revision = namespace::CityServiceIncidentIdentity.revision(event)
        actor = @publication_actor ||= FactoryBot.create(:user, :admin, :confirmed, organization: event.organization)
        event.update!(reviewer: actor, reviewed_at: Time.current, content_version: "fixture-reviewed",
                      reviewed_content_version: "fixture-reviewed",
                      extraction_metadata: event.extraction_metadata.merge("publication_revision" => revision, "source_snapshot_complete" => true))
        identity = namespace::CityServiceIncidentIdentity.delivery_identity(event)
        areas = Decidim::Bih::LocalArea.komsiluci.where(organization: event.organization)
        areas = areas.where(slug: event.area_slugs) unless event.targeting_level == "citywide"
        existing = Decidim::Bih::KomsilukPost.where(organization: event.organization, id: event.komsiluk_post_id_values).index_by(&:komsiluk_id)
        publication_key = existing.values.first&.publication_key || SecureRandom.uuid
        posts = areas.order(:id).map do |area|
          post = existing[area.id] || Decidim::Bih::KomsilukPost.new(organization: event.organization, komsiluk: area, publication_key:)
          post.assign_attributes(origin: "city_service", category: "safety", status: "open", title: event.title,
                                 body: event.summary, published_at: Time.current, expires_at: event.ends_at,
                                 content_revision: post.persisted? ? post.content_revision + 1 : 1,
                                 details: { source: { event_ids: [event.id], urls: [event.source_url], event_revision: revision } })
          post.save!
          namespace::CityServiceBoardPublication.publish!(post:, identity:, expires_at: event.ends_at,
                                                          context: { event_id: event.id, event_revision: revision })
          post
        end
        event.update!(komsiluk_post_ids: posts.map(&:id), target_komsiluk_slugs: posts.map { |post| post.komsiluk.slug },
                      extraction_metadata: event.extraction_metadata.merge("board_audience_identity" => identity))
      end
    end
    @opts&.merge!(event_revision: event.publication_revision, dedupe_key: event.viber_dedupe_key)
    event.reload
  end
end
