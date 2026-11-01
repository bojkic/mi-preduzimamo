# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Executes the owner's explicit acceptance of the captured totals unchanged.
    # It records that decision; it does not claim another source review occurred.
    class RaceProjectCloseout
      def initialize(organization:, actor:, reason:)
        @organization = organization
        @actor = actor
        @reason = reason
        @review = Decidim::Bih::Race::Review.new(organization)
      end

      def preview
        edition = Decidim::Bih::Race::Edition.for(@organization)
        raise ArgumentError, "capture missing" unless edition&.captured_at

        rows = @review.preview
        { snapshot_digest: edition.snapshot_digest, rows_digest: Decidim::Bih::Race::Edition.digest(rows),
          rows: rows.size, score: rows.sum { |row| row[:score] },
          winners: rows.group_by { |row| row[:zona] }.transform_values { |league| league.first[:komsiluk_id] } }
      end

      def apply!(expected_snapshot_digest:, expected_rows_digest:, winners:)
        Decidim::Bih::Race::Review.authorize!(@organization, @actor)
        raise ArgumentError, "reason required" if @reason.blank?

        edition = Decidim::Bih::Race::Edition.for(@organization)
        raise ArgumentError, "capture missing" unless edition&.captured_at

        edition.with_lock do
          before = preview
          raise ArgumentError, "capture changed" unless before[:snapshot_digest] == expected_snapshot_digest
          raise ArgumentError, "standings changed" unless before[:rows_digest] == expected_rows_digest
          raise ArgumentError, "winner mismatch" unless before[:winners] == winners.stringify_keys.transform_values(&:to_i)

          accept_existing_scoring!(edition, expected_snapshot_digest, expected_rows_digest, winners) unless edition.finalized_at

          result = RaceProjectSelectionSetup.new(organization: @organization, actor: @actor, reason: @reason).call(publish: true)
          update_homepage(result.fetch(:process))
          result.merge(preview: before, final_digest: edition.reload.final_digest)
        end
      end

      private

      def accept_existing_scoring!(edition, expected_snapshot_digest, expected_rows_digest, winners)
        @review.settings!(actor: @actor, reason: @reason, values: {
                            review_closes_at: Time.current.iso8601,
                            project_owner: RaceProjectSelection.localized_name(@organization.name),
                            tie_procedure: "Existing reached-first rule retained; neither approved league leader is tied.",
                            zero_entry_procedure: "No award for an empty or zero-score league.",
                            winners:
                          })
        edition.snapshot.fetch("items").each do |item|
          next unless item.dig("facts", "review_state").in?(%w(pending needs_information))

          @review.decide!(actor: @actor, reason: @reason, item_key: item.fetch("key"),
                          include_item: item.fetch("eligible"), expected_digest: expected_snapshot_digest)
        end
        raise ArgumentError, "acceptance changed scoring" unless preview[:rows_digest] == expected_rows_digest

        edition.record!("owner_closeout", actor: @actor, reason: @reason,
                                          method: "owner_instruction_executed_by_operator", appeals: false,
                                          scores_unchanged: true, rows_digest: expected_rows_digest)
        @review.finalize!(actor: @actor, reason: @reason, expected_digest: expected_snapshot_digest,
                          expected_revision: edition.events.maximum(:id))
      end

      def update_homepage(process)
        block = Decidim::ContentBlock.find_by(organization: @organization, scope_name: "homepage", manifest_name: "highlighted_content_banner")
        return unless block

        title = { "sr" => "Odaberi projekat", "bs" => "Odaberi projekat", "hr" => "Odaberi projekt",
                  "sr-Cyrl" => "Одабери пројекат", "en" => "Choose a project" }
        subtitle = %w(sr bs hr sr-Cyrl en).to_h do |locale|
          names = RaceProjectSelection.winner_names(@organization, locale:).map do |name|
            name = Decidim::Bih::Transliterator.call(name) if locale == "sr-Cyrl"
            ERB::Util.html_escape(name)
          end
          joiner = locale == "en" ? " and " : locale == "sr-Cyrl" ? " и " : " i "
          [locale, names.join(joiner)]
        end
        before = block.settings.to_h.deep_stringify_keys.slice("action_button_url", "action_button_title", "action_button_subtitle")
        after = { "action_button_url" => RaceProjectSelection.process_path,
                  "action_button_title" => title, "action_button_subtitle" => subtitle }
        return if before == after

        block.update!(settings: block.settings.to_h.deep_stringify_keys.merge(after))
        Decidim::Bih::OperatorAuditEvent.record!(
          organization: @organization, actor: @actor, event_type: "race_project_homepage_published", resource: block,
          metadata: { reason: @reason, process_id: process.id, before:, after: }
        )
      end
    end
  end
end
