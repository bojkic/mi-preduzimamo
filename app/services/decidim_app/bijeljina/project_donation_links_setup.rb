# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # One-time/idempotent bridge from the five existing Decidim budget projects
    # to their Odoo UTM campaigns. New partner projects receive the same generic
    # ProjectDonationLink during LFBN approval, so runtime donation code has one
    # source of truth and never duplicates project titles.
    class ProjectDonationLinksSetup
      LEGACY_LINKS = {
        1 => "mi-ti-se-pitas-2026-novi-vrtic-u-ledincima",
        2 => "mi-ti-se-pitas-2026-uredjenje-obale-drine",
        3 => "mi-ti-se-pitas-2026-sanacija-gradskog-parka",
        4 => "mi-ti-se-pitas-2026-javna-rasvjeta-prigradska-naselja",
        5 => "mi-ti-se-pitas-2026-biciklisticka-staza-drina"
      }.freeze

      def self.call(organization:, repair: false)
        new(organization:, repair:).call
      end

      def initialize(organization:, repair:)
        @organization = organization
        @repair = repair
      end

      # Returns the links that exist after the pass. Missing/deleted legacy
      # projects are intentionally skipped rather than recreated from stale ids.
      def call
        return [] unless Decidim::Bih::ProjectDonationLink.table_exists?

        LEGACY_LINKS.filter_map do |project_id, campaign_key|
          project = Decidim::Budgets::Project.find_by(id: project_id)
          next unless project&.organization == organization

          link = Decidim::Bih::ProjectDonationLink.find_or_initialize_by(
            organization:,
            project:
          )
          if link.new_record? || repair?
            link.campaign_key = campaign_key
            link.active = true
            link.save!
          end
          link
        end
      end

      private

      attr_reader :organization

      def repair?
        @repair
      end
    end
  end
end
