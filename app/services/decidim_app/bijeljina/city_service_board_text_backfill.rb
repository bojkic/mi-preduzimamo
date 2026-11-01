# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # One-off repair of notices already on the board.
    #
    # The published text pre-dates two corrections: an electricity notice that
    # never said which day the power goes off and carried the utility's circuit
    # identifiers, and a source credit that printed an internal English label
    # ("Elektro Bijeljina planned outages") instead of the institution's name.
    # New notices are written correctly; these were not, and a resident reading
    # the board cannot tell which is which.
    #
    # It rewrites ONLY text it can prove the parser wrote. Each candidate is
    # reconstructed in the historical format and compared to what is stored; a
    # notice an operator has edited by hand fails that comparison and is left
    # exactly as it is, and reported.
    class CityServiceBoardTextBackfill
      Result = Struct.new(:events_rewritten, :posts_rewritten, :skipped, keyword_init: true)

      def initialize(organization:)
        @organization = organization
      end

      def call(apply: false)
        result = Result.new(events_rewritten: [], posts_rewritten: [], skipped: [])
        candidates.each { |event| plan(event, result, apply:) }
        Result.new(events_rewritten: result.events_rewritten.sort, posts_rewritten: result.posts_rewritten.sort,
                   skipped: result.skipped.sort)
      end

      private

      attr_reader :organization

      def plan(event, result, apply:)
        summary = rewritten_summary(event)
        # A post whose body no longer opens with the notice it was generated
        # from has been edited independently. We cannot locate the notice
        # inside it without guessing, so it is reported and left alone.
        detached, attached = board_posts_for(event).partition { |post| detached?(post, event) }
        result.skipped.concat(detached.map(&:id))
        changes = attached.filter_map { |post| post_change(post, event, summary) }
        return if summary == event.summary && changes.empty?

        result.events_rewritten << event.id if summary != event.summary
        result.posts_rewritten.concat(changes.map { |post, _| post.id })
        return unless apply

        write!(event, summary, changes)
      end

      def write!(event, summary, changes)
        ActiveRecord::Base.transaction do
          # Identity and review state are untouched; only the wording moves.
          event.update_columns(summary:, updated_at: Time.current) if summary != event.summary # rubocop:disable Rails/SkipsModelValidations
          changes.each { |post, body| post.update!(body:) }
        end
      end

      def candidates
        CityServiceEvent.for_organization(organization)
                        .where.not(komsiluk_post_ids: [])
                        .order(:id)
      end

      def board_posts_for(event)
        ids = event.komsiluk_post_id_values
        return [] if ids.empty?

        Decidim::Bih::KomsilukPost.where(id: ids, decidim_organization_id: organization.id, decidim_user_id: nil).order(:id).to_a
      end

      # The notice text as it should read today. Only an electricity notice
      # still in the parser's own historical wording is rewritten.
      def rewritten_summary(event)
        return event.summary unless event.source_key == "electricity_outages"
        return event.summary unless event.starts_at && event.ends_at
        return event.summary unless event.summary.to_s.strip == legacy_summary(event)

        ElectricityOutageParser.citizen_summary(
          affected: event.affected_text.to_s,
          starts_at: event.starts_at.in_time_zone(CityServiceTime::ZONE),
          ends_at: event.ends_at.in_time_zone(CityServiceTime::ZONE),
          reason: event.extraction_metadata["reason"]
        )
      end

      # The retired format, frozen here on purpose: it is history, not a living
      # definition, and it exists only to prove a stored notice is untouched.
      def legacy_summary(event)
        starts = event.starts_at.in_time_zone(CityServiceTime::ZONE).strftime("%H:%M")
        ends = event.ends_at.in_time_zone(CityServiceTime::ZONE).strftime("%H:%M")
        text = "Planirano isključenje električne energije za #{event.affected_text} od #{starts} do #{ends}."
        details = { "tj" => "TJ", "feeder" => "Objekat", "reason" => "Razlog" }.filter_map do |field, label|
          "#{label}: #{event.extraction_metadata[field]}" if event.extraction_metadata[field].present?
        end.join("; ")
        details.empty? ? text : "#{text} #{details}"
      end

      # A board body is the notice, the source credit and the source links, and
      # the stored copy has had its line breaks flattened to spaces. Rather than
      # rebuild it — and risk losing a link this code does not know about — the
      # two known-wrong fragments are replaced in place. Anything else is left
      # untouched.
      def detached?(post, event)
        !post.body.to_s.start_with?(event.summary.to_s.strip)
      end

      def post_change(post, event, summary)
        body = post.body.to_s
        stored_summary = event.summary.to_s.strip
        rewritten = summary + body[stored_summary.length..]
        rewritten = rewritten.sub(credit(source_label(event)), credit(source_provider(event))) if source_provider(event).present?
        return nil if rewritten == body || rewritten.length > Decidim::Bih::KomsilukPost::BODY_MAX

        [post, rewritten]
      end

      def credit(name) = "Izvor: #{name}"

      def source_label(event) = CityServiceSources.find(event.source_key)&.dig(:label).to_s

      def source_provider(event) = CityServiceSources.find(event.source_key)&.dig(:provider).to_s
    end
  end
end
