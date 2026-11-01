# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Idempotent bootstrap for Lokalna fondacija Bijeljina's participatory
    # grant cycle — the Phase 1 "core participation" of the roadmap.
    #
    # It scaffolds the "Ti se pitaš!" participatory process (citizens propose
    # and vote on which community projects the foundation funds) together with
    # the three components that close the participation loop:
    #
    #   1. proposals      — citizens submit project ideas;
    #   2. budgets        — citizens vote to fund projects ("Budžet za sve nas!");
    #   3. accountability — track which funded projects were delivered.
    #
    # Running it more than once is safe: the process is found-or-created by
    # (slug, organization) and each component by manifest_name (one of each), so
    # a re-run never duplicates anything even if an admin renamed a component.
    #
    # The process + components are created UNPUBLISHED (draft): an admin reviews
    # and configures (budget rules, voting) and then publishes — so an empty
    # structure is never exposed to the public the instant this runs.
    #
    # For an annual cycle, pass `year:` (folded into the slug, e.g.
    # "ti-se-pitas-2027") so each year is its own found-or-created process.
    #
    #   DecidimApp::Bijeljina::GrantCycleSetup.call(organization: org, year: 2027)
    #
    # Out of scope (tracked as a follow-up): a separate "Mi odlučujemo!"
    # debates space. No example proposals/projects are seeded — the service
    # only lays down the empty structure an admin then populates.
    class GrantCycleSetup
      DEFAULT_SLUG = "ti-se-pitas"

      # Components added to the process, in display order, each with the global
      # and per-step settings that make it usable out of the box.
      COMPONENTS = [
        {
          manifest_name: "proposals",
          name: "Predlozi građana",
          settings: {
            comments_enabled: true,
            official_proposals_enabled: false,
            attachments_allowed: true
          },
          step_settings: {
            creation_enabled: true,
            comments_blocked: false
          }
        },
        {
          manifest_name: "budgets",
          name: "Budžet za sve nas!",
          settings: {
            comments_enabled: true
          },
          step_settings: {}
        },
        {
          manifest_name: "accountability",
          name: "Šta je urađeno",
          settings: {
            comments_enabled: true,
            display_progress_enabled: true
          },
          step_settings: {}
        }
      ].freeze

      def self.call(organization:, slug: DEFAULT_SLUG, year: nil)
        new(organization:, slug:, year:).call
      end

      def initialize(organization:, slug: DEFAULT_SLUG, year: nil)
        @organization = organization
        @year = year
        # Fold the year into the default slug so each annual cycle is a distinct
        # found-or-created process (an explicit slug is respected as-is).
        @slug = slug == DEFAULT_SLUG && year ? "#{DEFAULT_SLUG}-#{year}" : slug
      end

      # Returns the persisted Decidim::ParticipatoryProcess.
      def call
        process = find_or_create_process
        ensure_active_step(process)
        process.reload
        COMPONENTS.each { |config| ensure_component(process, config) }
        process
      end

      private

      attr_reader :organization, :slug, :year

      def find_or_create_process
        existing = Decidim::ParticipatoryProcess.find_by(organization:, slug:)
        return existing if existing

        Decidim::ParticipatoryProcess.create!(process_attributes)
      end

      def process_attributes
        {
          organization:,
          slug:,
          title: translatable(title_text),
          subtitle: translatable("Učešće građana u dodjeli sredstava zajednici"),
          short_description: translatable(short_description_text),
          description: translatable(description_text),
          start_date: Date.current,
          end_date: 3.months.from_now.to_date,
          # Draft: the admin reviews/configures, then publishes.
          published_at: nil
        }
      end

      def ensure_active_step(process)
        return if process.steps.any?

        Decidim::ParticipatoryProcessStep.create!(
          participatory_process: process,
          title: translatable("Prijedlozi i glasanje"),
          active: true,
          start_date: Date.current,
          end_date: 3.months.from_now.to_date
        )
      end

      def ensure_component(process, config)
        # One component per manifest — match on manifest_name only, so an admin
        # renaming a component never causes a duplicate on the next run.
        return if process.components.where(manifest_name: config[:manifest_name]).any?

        Decidim::Component.create!(
          participatory_space: process,
          manifest_name: config[:manifest_name],
          name: translatable(config[:name]),
          settings: config[:settings],
          step_settings: step_settings_for(process, config[:step_settings]),
          # Draft alongside the process; the admin publishes after configuring.
          published_at: nil
        )
      end

      # Maps the desired per-step settings onto the process's active step(s).
      # Returns {} when there is no step, so component creation never fails.
      def step_settings_for(process, settings)
        return {} if settings.blank?

        process.steps.each_with_object({}) do |step, acc|
          acc[step.id.to_s] = settings
        end
      end

      # Builds the 4-locale Hash every translatable Decidim field expects.
      # Serbian Latin is authored once; sr-Cyrl is generated losslessly via the
      # decidim-bih transliterator, and bs/hr (≈95% identical) copy the Latin.
      def translatable(serbian_string)
        {
          "sr" => serbian_string,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(serbian_string),
          "bs" => serbian_string,
          "hr" => serbian_string
        }
      end

      def title_text
        year ? "Ti se pitaš! #{year}" : "Ti se pitaš!"
      end

      def short_description_text
        "Građani predlažu i biraju koje projekte u zajednici finansira " \
          "Lokalna fondacija Bijeljina."
      end

      def description_text
        "„Ti se pitaš!“ je participativni grant ciklus Lokalne fondacije " \
          "Bijeljina. Građani predlažu projekte za svoju zajednicu, zajedno " \
          "biramo koje ćemo finansirati kroz „Budžet za sve nas!“, a zatim " \
          "pratimo realizaciju odobrenih projekata. Tvoj glas odlučuje kako " \
          "se ulaže u Bijeljinu."
      end
    end
  end
end
