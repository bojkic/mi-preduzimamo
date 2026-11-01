# frozen_string_literal: true

require "digest"
require "json"

module DecidimApp
  module Bijeljina
    # Trusted, read-only prefills for staff publications. A linked notice keeps
    # the reviewed source digest; it never imports a report's private narrative.
    class KomsilukNoticeSources
      KINDS = %w(report activity project).freeze
      REPORT_FIELDS = %w(decidim_organization_id reference category status review_state reviewed_at reviewed_by_id duplicate_of_report_id
                         report_collection_id location_kind latitude longitude location_end_latitude location_end_longitude
                         location_reviewed_at location_reviewed_by_id).freeze
      ACTIVITY_FIELDS = %w(decidim_organization_id title description category location meeting_point requirements starts_at ends_at signup_deadline_at
                           applications_paused_at cancelled_at active review_status reviewed_at reviewed_by_id partner_profile_id
                           komsiluk_id opportunity_kind day_keys month_keys time_slot_keys).freeze
      PROJECT_FIELDS = %w(title description budget_amount decidim_budgets_budget_id deleted_at).freeze
      SUBMISSION_FIELDS = %w(review_status reviewed_at reviewed_by_id partner_profile_id decidim_budgets_project_id decidim_organization_id).freeze
      PROFILE_FIELDS = %w(verification_status verified_at legacy_user_group_id decidim_organization_id).freeze
      LINK_FIELDS = %w(active decidim_budgets_project_id decidim_organization_id).freeze

      class << self
        def call(organization:, actor:, kind:, id:)
          return unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :broadcast_preview, organization:)

          new(organization:).snapshot(kind:, id:)
        end

        # Publication/correction uses a newly reviewed current digest, including
        # when an older linked digest was deliberately superseded. The caller
        # takes placement locks inside this block and verifies its exact preview.
        def with_reviewed_source_lock(organization:, actor:, kind:, id:, revision:)
          return false unless Decidim::Bih::OperatorAuthorization.allowed?(actor, :broadcast_preview, organization:)

          new(organization:).with_snapshot_lock(kind:, id:) do |current|
            next false unless current && current.dig(:details, "source_record", "revision") == revision

            yield current
          end
        end

        def refresh_due!(organization:)
          KomsilukSourceProjectionRefresh.refresh_due!(organization:)
        end

        # Parent/source locks precede post/receipt/user locks. The post lock
        # also prevents its linkage changing after the source has been chosen.
        # false means the block was not entered; otherwise its value is returned.
        def with_source_lock(post:)
          reference = post.details.to_h["source_record"]
          return yield if reference.blank?
          return false unless reference.is_a?(Hash) && post.origin == "staff"

          new(organization: post.organization).with_snapshot_lock(kind: reference["kind"], id: reference["id"]) do |current|
            next false unless current && current.dig(:details, "source_record", "revision") == reference["revision"]

            post.with_lock do
              next false unless post.details.to_h["source_record"] == reference

              yield
            end
          end
        end
      end

      def initialize(organization:)
        @organization = organization
      end

      def snapshot(kind:, id:)
        return unless organization && KINDS.include?(kind.to_s) && id.to_s.match?(/\A[1-9]\d*\z/)

        record = source_record(kind.to_s, id)
        return unless record

        case kind.to_s
        when "report" then report_snapshot(record)
        when "activity" then activity_snapshot(record)
        when "project" then project_snapshot(record)
        end
      end

      # Used by the projection refresh adapter as well as the final dispatch
      # guard. A missing source yields nil, so its placements can be withdrawn.
      def with_snapshot_lock(kind:, id:)
        return yield(nil) unless organization && KINDS.include?(kind.to_s) && id.to_s.match?(/\A[1-9]\d*\z/)

        record = source_record(kind.to_s, id)
        return yield(nil) unless record

        chain = lock_chain(kind.to_s, record)
        return yield(nil) if chain.empty?

        Decidim::ApplicationRecord.transaction do
          begin
            chain.each(&:lock!)
            record.reload
          rescue ActiveRecord::RecordNotFound
            next yield(nil)
          end
          fresh_chain = lock_chain(kind.to_s, record)
          next false unless identities(chain) == identities(fresh_chain)

          yield snapshot(kind:, id:)
        end
      end

      private

      attr_reader :organization

      def source_record(kind, id)
        case kind
        when "report" then Decidim::Bih::Report.find_by(organization:, id:)
        when "activity" then Decidim::Bih::VolunteerOpportunity.find_by(organization:, id:)
        when "project"
          Decidim::Budgets::Project.find_by(id:).then do |project|
            space = project&.component&.participatory_space
            project if space&.organization == organization
          end
        end
      end

      def report_snapshot(report)
        return unless report.review_state == "validated" && report.reviewed_at && report.duplicate_of_report_id.nil?

        url = public_routes.report_path(report.reference, script_name: "/biceriseno")
        category = I18n.t("decidim.bih.reports.categories.#{report.category}", default: report.category.to_s, locale:)
        status = Decidim::Bih::ReportStatusPresenter.label(report, locale:)
        title = text("report_title", reference: report.reference)
        body = text("report_body", reference: report.reference, category:, status:, url:)
        reviewed_location = report.location_reviewed_at && report.location_reviewed_by&.organization == organization
        material = report.attributes.slice("reference", "category", "status")
        material.merge!(report.attributes.slice("location_kind", "latitude", "longitude", "location_end_latitude",
                                                 "location_end_longitude")) if reviewed_location
        build("report", report.id, title:, body:, url:, area_ids: report_area_ids(report),
                                   material:,
                                   revision: [report.attributes.slice(*REPORT_FIELDS)])
      end

      def activity_snapshot(activity)
        return unless Decidim::Bih::VolunteerOpportunity.publicly_visible.exists?(organization:, id: activity.id)
        return unless activity.signup_open?

        profile = activity.partner_profile
        return if profile && profile.organization != organization

        url = public_routes.volunteer_path(tab: "prilike", anchor: "volunteer-opportunity-#{activity.id}", script_name: "/biceriseno")
        area_ids = reviewed_activity_area_ids(activity)
        schedule, location = I18n.with_locale(locale) { [activity.time_frame_label, activity.location_label] }
        body = [plain(activity.description, 500), plain(schedule, 120),
                plain(location, 180), text("activity_link", url:)].compact_blank.join("\n\n")
        build("activity", activity.id, title: plain(activity.title, 100), body:, url:, area_ids:,
                                       material: activity.attributes.slice("category", "location", "meeting_point", "requirements", "starts_at", "ends_at",
                                                                           "signup_deadline_at", "opportunity_kind", "day_keys", "month_keys", "time_slot_keys"),
                                       revision: [activity.attributes.slice(*ACTIVITY_FIELDS), profile_facts(profile),
                                                  activity.komsiluk&.attributes&.slice("id", "name", "kind", "decidim_organization_id")])
      end

      def project_snapshot(project)
        context = project_context(project)
        return unless current_project?(project, context)

        url = public_routes.community_project_path(project.id, script_name: "/biceriseno")
        body = [plain(project.description, 850), text("project_link", url:)].compact_blank.join("\n\n")
        build("project", project.id, title: plain(project.title, 100), body:, url:, area_ids: [],
                                     material: project.attributes.slice("budget_amount"),
                                     revision: [project.attributes.slice(*PROJECT_FIELDS), context[:submission].attributes.slice(*SUBMISSION_FIELDS),
                                                profile_facts(context[:profile]), context[:link].attributes.slice(*LINK_FIELDS),
                                                context[:setting].value, context[:budget].attributes.slice("id", "deleted_at", "decidim_component_id"),
                                                context[:component].attributes.slice("id", "published_at", "deleted_at", "participatory_space_id", "participatory_space_type"),
                                                context[:space].attributes.slice("id", "published_at", "decidim_organization_id")])
      end

      def project_context(project)
        submissions = Decidim::Bih::PartnerProjectSubmission.where(organization:, project:).order(:id)
        submission = submissions.approved.first || submissions.first
        {
          submission:, profile: submission&.partner_profile, budget: project.budget,
          component: project.component, space: project.component&.participatory_space,
          setting: Decidim::Bih::Setting.find_by(organization:, namespace: "community_projects", key: "budget_id"),
          link: Decidim::Bih::ProjectDonationLink.where(organization:, project:).order(created_at: :desc, id: :desc).first
        }
      end

      def current_project?(project, context)
        submission, profile, budget, component, space, setting, link = context.values_at(
          :submission, :profile, :budget, :component, :space, :setting, :link
        )
        return false unless submission&.approved? && profile && budget && component && space && setting && link&.active?
        return false unless Decidim::Bih::PartnerProfile.publicly_visible.exists?(organization:, id: profile.id)

        project.deleted_at.nil? && budget.deleted_at.nil? && component.deleted_at.nil? &&
          setting.value.to_s.to_i == budget.id && component.published? &&
          space.organization == organization && !space.published?
      end

      def report_area_ids(report)
        # A point explicitly checked by an operator can propose its canonical
        # polygon. Segments and free text require a deliberate board choice.
        return [] unless report.location_kind == "point" && report.location_reviewed_at && report.location_reviewed_by&.organization == organization
        return [] unless report.latitude && report.longitude

        area = Decidim::Bih::Geo::AreaLocator.new.locate_komsiluk(
          lat: report.latitude, lon: report.longitude, organization:
        )&.dig(:komsiluk)
        area&.organization == organization && area.kind == "komsiluk" ? [area.id] : []
      end

      def reviewed_activity_area_ids(activity)
        return [] unless activity.reviewed_at && activity.reviewer&.organization == organization

        area = activity.komsiluk
        area&.organization == organization && area.kind == "komsiluk" ? [area.id] : []
      end

      def lock_chain(kind, record)
        case kind
        when "report" then [record.report_collection, record].compact
        when "activity"
          profile = record.partner_profile
          [record, profile, profile&.legacy_user_group, record.komsiluk].compact
        when "project"
          context = project_context(record)
          # Matches approval's budget -> submission -> partner order.
          [context[:budget], context[:submission], context[:profile], context[:profile]&.legacy_user_group,
           record, context[:link], context[:setting], context[:component], context[:space]].compact
        end.uniq { |row| [row.class.base_class.name, row.id] }
      end

      def identities(records)
        records.map { |row| [row.class.base_class.name, row.id] }
      end

      def profile_facts(profile)
        return nil unless profile

        [profile.attributes.slice(*PROFILE_FIELDS),
         profile.legacy_user_group&.attributes&.slice("id", "blocked", "blocked_at", "deleted_at")]
      end

      def build(kind, id, title:, body:, url:, area_ids:, material:, revision:)
        digest = Digest::SHA256.hexdigest(JSON.generate([kind, id, locale, revision, area_ids]))
        # This separate digest describes public facts only. Review timestamps,
        # actor changes and delivery eligibility remain in the full revision.
        public_facts = Digest::SHA256.hexdigest(JSON.generate([kind, id, locale, title, body, area_ids, material]))
        { title:, body:, area_ids:,
          details: { "source_record" => { "kind" => kind, "id" => id, "url" => url, "revision" => digest,
                                           "material_fingerprint" => public_facts } } }
      end

      def public_routes
        Decidim::Bih::Engine.routes.url_helpers
      end

      def locale
        organization.default_locale.presence || "sr"
      end

      def plain(value, limit)
        translated = value.is_a?(Hash) ? value[locale.to_s].presence || value["sr"].presence || value.values.find(&:present?) : value
        ActionController::Base.helpers.strip_tags(translated.to_s).squish.truncate(limit)
      end

      def text(key, **values)
        I18n.t("decidim.bih.komsiluk_notice_sources.#{key}", locale:, **values)
      end
    end
  end
end
