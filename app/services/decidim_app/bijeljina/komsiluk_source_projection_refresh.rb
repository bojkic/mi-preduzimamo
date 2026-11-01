# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Source changes mark linked placements for review without replacing staff
    # wording, sending messages or clearing an existing local moderation hold.
    class KomsilukSourceProjectionRefresh
      SOURCE_FIELDS = {
        "Decidim::Bih::Report" => KomsilukNoticeSources::REPORT_FIELDS,
        "Decidim::Bih::VolunteerOpportunity" => KomsilukNoticeSources::ACTIVITY_FIELDS,
        "Decidim::Budgets::Project" => KomsilukNoticeSources::PROJECT_FIELDS,
        "Decidim::Bih::PartnerProjectSubmission" => KomsilukNoticeSources::SUBMISSION_FIELDS,
        "Decidim::Bih::PartnerProfile" => KomsilukNoticeSources::PROFILE_FIELDS,
        "Decidim::Bih::ProjectDonationLink" => KomsilukNoticeSources::LINK_FIELDS,
        "Decidim::Bih::Setting" => %w(namespace key value decidim_organization_id),
        "Decidim::Budgets::Budget" => %w(deleted_at decidim_component_id),
        "Decidim::Component" => %w(published_at deleted_at participatory_space_id participatory_space_type),
        "Decidim::ParticipatoryProcess" => %w(published_at decidim_organization_id),
        "Decidim::User" => %w(blocked blocked_at deleted_at),
        "Decidim::Bih::LocalArea" => %w(name slug kind boundary decidim_organization_id)
      }.freeze

      class << self
        def install!
          SOURCE_FIELDS.each_key do |name|
            model = name.constantize
            model.include(Decidim::Bih::KomsilukNoticeSource) unless model < Decidim::Bih::KomsilukNoticeSource
            model.komsiluk_notice_source_refresher = self
          end
        end

        def tracked_fields_for(record)
          record.class.ancestors.filter_map { |ancestor| SOURCE_FIELDS[ancestor.name] }.first || []
        end

        def call(record, changes: record.previous_changes)
          fields = tracked_fields_for(record)
          return unless record.destroyed? || changes.keys.intersect?(fields)
          return unless linked_posts_available?
          return if record.is_a?(Decidim::Bih::Setting) && !community_setting?(record, changes)

          references_for(record, changes).uniq.each do |organization_id, kind, id|
            refresh!(organization_id:, kind:, id:)
          end
        end

        # Wire beside board expiry; time passing does not trigger after_commit.
        def refresh_due!(organization:)
          return unless linked_posts_available?

          references = linked_posts.where(organization:).where("details -> 'source_record' ->> 'kind' = ?", "activity")
                                   .where(status: %w(open hidden)).pluck(:decidim_organization_id, :details).map do |organization_id, details|
            [organization_id, "activity", details.dig("source_record", "id")]
          end
          references.uniq.each { |organization_id, kind, id| refresh!(organization_id:, kind:, id:) }
        end

        def refresh!(organization_id:, kind:, id:)
          organization = Decidim::Organization.find_by(id: organization_id)
          return unless organization

          scope = linked_posts.where(organization:)
                              .where("details -> 'source_record' ->> 'kind' = ? AND details -> 'source_record' ->> 'id' = ?", kind, id.to_s)
          return unless scope.exists?

          KomsilukNoticeSources.new(organization:).with_snapshot_lock(kind:, id:) do |current|
            scope.order(:id).each { |post| refresh_post!(post, current, organization_id:, kind:, id:) }
          end
        end

        private

        def linked_posts_available?
          Decidim::Bih::KomsilukPost.table_exists? && Decidim::Bih::KomsilukPost.column_names.include?("details")
        end

        def linked_posts
          Decidim::Bih::KomsilukPost.where(origin: "staff").where("details ? 'source_record'")
        end

        def refresh_post!(post, current, organization_id:, kind:, id:)
          post.with_lock do
            details = post.details.deep_dup
            reference = details["source_record"]
            return unless post.origin == "staff" && post.decidim_organization_id == organization_id && reference.is_a?(Hash)
            return unless reference["kind"] == kind && reference["id"].to_s == id.to_s

            latest_revision = current&.dig(:details, "source_record", "revision")
            return if latest_revision == reference["revision"]
            return if latest_revision.nil? && reference["unavailable_at"].present?
            return if latest_revision.present? && reference["current_revision"] == latest_revision

            now = Time.current
            reference["changed_at"] = now.iso8601
            reference["current_revision"] = latest_revision
            latest_material = current&.dig(:details, "source_record", "material_fingerprint")
            reference["material_changed"] = if latest_revision.nil?
                                                true
                                              elsif reference["material_fingerprint"].present?
                                                latest_material != reference["material_fingerprint"]
                                              else
                                                # Older placements have no public-fact baseline.
                                                true
                                              end
            changes = { details:, review_state: "pending" }
            if current.nil?
              reference["unavailable_at"] = now.iso8601
              changes[:expires_at] = [post.expires_at, now].compact.min
              changes[:status] = "expired" unless post.status == "hidden"
            end
            post.update!(changes)
            Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(
              post:, reason: current ? "source_changed" : "source_unavailable"
            )
          end
        end

        def references_for(record, changes)
          case record
          when Decidim::Bih::Report
            source_organization_ids(record, changes).map { |organization_id| [organization_id, "report", record.id] }
          when Decidim::Bih::VolunteerOpportunity
            source_organization_ids(record, changes).map { |organization_id| [organization_id, "activity", record.id] }
          when Decidim::Budgets::Project
            # Linked rows preserve identity even when the source was deleted.
            project_references([record.id])
          when Decidim::Bih::PartnerProjectSubmission, Decidim::Bih::ProjectDonationLink
            ids = [record.decidim_budgets_project_id, *Array(changes["decidim_budgets_project_id"])].compact
            project_references(ids)
          when Decidim::Bih::PartnerProfile
            profile_references([record.id])
          when Decidim::User
            profile_references(Decidim::Bih::PartnerProfile.where(legacy_user_group_id: record.id).pluck(:id))
          when Decidim::Bih::Setting
            organization_references([record.decidim_organization_id, *Array(changes["decidim_organization_id"])], kinds: ["project"])
          when Decidim::Bih::LocalArea
            organization_references([record.decidim_organization_id, *Array(changes["decidim_organization_id"])], kinds: %w(report activity))
          else
            # Component/budget/parent deletion can remove the association before
            # after_commit. Existing source IDs in our small linked catalog are
            # the durable lookup; unrelated board origins are never touched.
            linked_references(kinds: ["project"])
          end
        end

        def profile_references(ids)
          activity = Decidim::Bih::VolunteerOpportunity.where(partner_profile_id: ids)
                                                       .pluck(:decidim_organization_id, :id).map { |organization_id, id| [organization_id, "activity", id] }
          projects = Decidim::Bih::PartnerProjectSubmission.where(partner_profile_id: ids).pluck(:decidim_budgets_project_id).compact
          activity + project_references(projects)
        end

        def project_references(ids)
          linked_references(kinds: ["project"]).select { |_, _, id| ids.map(&:to_s).include?(id.to_s) }
        end

        def organization_references(ids, kinds:)
          linked_references(kinds:).select { |organization_id, _, _| ids.compact.include?(organization_id) }
        end

        def linked_references(kinds:)
          linked_posts.where("details -> 'source_record' ->> 'kind' IN (?)", kinds)
                      .pluck(:decidim_organization_id, :details).map do |organization_id, details|
            reference = details.fetch("source_record")
            [organization_id, reference["kind"], reference["id"]]
          end
        end

        def source_organization_ids(record, changes)
          [record.decidim_organization_id, *Array(changes["decidim_organization_id"])].compact.uniq
        end

        def community_setting?(record, changes)
          namespaces = [record.namespace, *Array(changes["namespace"])]
          keys = [record.key, *Array(changes["key"])]
          namespaces.include?("community_projects") && keys.include?("budget_id")
        end
      end
    end
  end
end
