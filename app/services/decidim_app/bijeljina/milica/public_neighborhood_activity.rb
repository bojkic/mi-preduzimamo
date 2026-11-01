# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    module Milica
      # A deliberately smaller projection than the public report map. Geometry,
      # tenant, lifecycle and date predicates run in SQL BEFORE the bounded read.
      # Neither member posts nor report text/contact/token fields are selected.
      class PublicNeighborhoodActivity
        LIMIT = 3
        MAX_POINTS = 10_000
        MAX_POLYGONS = 64
        COLUMNS = [:id, :reference, :category, :status, :duplicate_of_report_id, :review_state, :reviewed_at, :last_citizen_reply_at, :created_at].freeze
        Result = Data.define(:status, :facts, :coverage, :warnings)

        def initialize(organization:, report_scope: nil)
          @organization = organization
          @report_scope = report_scope
        end

        def call(areas:, now:, starts_at:, ends_at:, explicit_time:, locale:) # rubocop:disable Metrics/ParameterLists
          area = selected_area(areas)
          coverage = { "limit" => LIMIT, "located_only" => true }
          return unavailable(coverage, "public_reports_area_unavailable") unless area

          from = explicit_time ? starts_at : now - 7.days
          until_time = explicit_time ? [ends_at, now].min : now
          coverage.merge!("area_slug" => area.slug, "area_kind" => area.kind,
                          "area_label" => area_label(area, locale),
                          "starts_at" => from.iso8601, "ends_at" => [until_time, from].max.iso8601)
          warnings = [explicit_time ? "public_reports_window" : "public_reports_recent_window"]
          return empty(coverage, warnings) if from >= until_time

          predicate = geometry_predicate(area.boundary)
          return unavailable(coverage, "public_reports_area_unavailable") unless predicate

          reports = located_reports(predicate, from, until_time)
          project_reports(reports, coverage, warnings, area, locale)
        rescue ArgumentError, TypeError
          unavailable(coverage || {}, "public_reports_area_unavailable")
        end

        # Native PostgreSQL geometry avoids introducing PostGIS or classifying
        # only the first citywide N reports in Ruby. Boundaries come exclusively
        # from trusted tenant records; numeric polygon values are bind arguments.
        def geometry_predicate(boundary)
          polygons = boundary_polygons(boundary)
          return unless polygons
          return if polygons.sum { |rings| rings.sum(&:length) } > MAX_POINTS

          values = []
          clauses = polygons.map { |rings| polygon_clause(rings, values) }
          return if clauses.include?(nil)

          ["(#{clauses.join(" OR ")})", *values]
        end

        private

        attr_reader :organization

        def scope = @report_scope || Decidim::Bih::Report

        def located_reports(predicate, from, until_time)
          scope.where(decidim_organization_id: organization.id, status: Decidim::Bih::Report::STATUSES, removed_from_public_at: nil)
               .where(created_at: from...until_time)
               .where("latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180")
               .where(*predicate)
               .select(*COLUMNS).order(created_at: :desc, id: :desc).limit(LIMIT + 1).to_a
        end

        def project_reports(reports, coverage, warnings, area, locale)
          coverage["truncated"] = reports.length > LIMIT
          warnings << "public_reports_truncated" if coverage["truncated"]
          return empty(coverage, warnings) if reports.empty?

          facts = reports.first(LIMIT).map { |report| report_fact(report, locale:, area:) }
          Result.new("ok", facts, coverage.merge("status" => "ok"), warnings)
        end

        def area_label(area, locale)
          I18n.with_locale(locale) { area.respond_to?(:translated_name) ? area.translated_name.to_s[0, 160] : area.slug }
        end

        def boundary_polygons(boundary)
          return unless boundary.is_a?(Hash)

          polygons = case boundary["type"]
                     when "Polygon" then [boundary["coordinates"]]
                     when "MultiPolygon" then boundary["coordinates"]
                     end
          return unless polygons.is_a?(Array) && polygons.length.between?(1, MAX_POLYGONS)
          return unless polygons.all? { |rings| valid_rings?(rings) }

          polygons
        end

        def valid_rings?(rings)
          rings.is_a?(Array) && rings.length.between?(1, MAX_POLYGONS) && rings.all? { |ring| ring.is_a?(Array) }
        end

        def polygon_clause(rings, values)
          clauses = rings.each_with_index.map do |ring, index|
            polygon = validated_ring(ring)
            return nil unless polygon

            values << polygon
            "#{"NOT " unless index.zero?}(point(longitude, latitude) <@ CAST(? AS polygon))"
          end
          "(#{clauses.join(" AND ")})"
        end

        def selected_area(areas)
          return unless areas.is_a?(Array) && areas.any?
          return unless areas.all? { |area| area.decidim_organization_id == organization.id && %w(mz komsiluk).include?(area.kind) }

          # GPS independently resolves both kinds. The actual komšiluk polygon
          # is the neighborhood scope; its overlapping MZ is never substituted.
          preferred = areas.select { |area| area.kind == "komsiluk" }
          preferred = areas if preferred.empty?
          preferred.first if preferred.one?
        end

        def validated_ring(ring)
          return unless ring.is_a?(Array) && ring.length >= 4 && ring.first == ring.last
          return unless ring.all? { |point| valid_point?(point) }
          return if ring.each_cons(2).sum { |left, right| (left[0] * right[1]) - (right[0] * left[1]) }.abs < 1e-12

          "(#{ring.map { |lon, lat| "(#{lon},#{lat})" }.join(",")})"
        end

        def valid_point?(point)
          point.is_a?(Array) && point.length == 2 && point.all? { |coordinate| coordinate.is_a?(Numeric) && coordinate.finite? } &&
            point[0].between?(-180, 180) && point[1].between?(-90, 90)
        end

        def report_fact(report, locale:, area:)
          reference = report.reference.to_s
          raise ArgumentError, "Invalid public reference" unless reference.match?(/\ABR-\d{4}-\d{4,10}\z/)

          category = I18n.t("decidim.bih.reports.categories.#{report.category.presence || "ostalo"}", locale:, default: "—")
          status = Decidim::Bih::ReportStatusPresenter.label(report, locale:)
          date = report.created_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y.")
          {
            "id" => "public_report:#{reference}", "kind" => "area_public_report",
            "text" => I18n.t("decidim.bih.dialogue.neighborhood_report_fact", locale:, reference:, category:, status:, date:),
            "source_id" => "public_reports",
            "source_label" => I18n.t("decidim.bih.dialogue.neighborhood_reports_source", locale:),
            "reference" => reference, "status" => Decidim::Bih::ReportStatusPresenter.status_key(report),
            "area_slug" => area.slug, "area_kind" => area.kind,
            "observed_at" => report.created_at.iso8601,
            "destination" => Decidim::Bih.public_path("prijave/#{reference}"), "warning_codes" => []
          }
        end

        def empty(coverage, warnings)
          Result.new("empty", [], coverage.merge("status" => "empty"), warnings + ["no_matching_public_reports"])
        end

        def unavailable(coverage, warning)
          Result.new("unavailable", [], coverage.merge("status" => "unavailable"), [warning])
        end
      end
    end
  end
end
