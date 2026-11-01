# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Idempotent bootstrap for Lokalna fondacija Bijeljina's ongoing civic
    # debates space — the "Mi odlučujemo!" roadmap module.
    #
    # Unlike the grant cycle ("Ti se pitaš!", see GrantCycleSetup) this space is
    # NOT year-keyed: it is a single, persistent participatory process where the
    # community holds general debates about the city and shared life. Citizens
    # open discussion topics and everyone weighs in — hence one Debates
    # component, with citizen creation enabled but moderation available.
    #
    # We use a Decidim::ParticipatoryProcess (not an Assembly) to stay
    # consistent with GrantCycleSetup and the rest of this app's spaces. A
    # process also gives us a phase/step the Debates component hangs its
    # step-settings (creation, likes) off, which an Assembly lacks.
    #
    # Running it more than once is safe: the process is found-or-created by
    # (slug, organization) and the component by manifest_name, so a re-run never
    # duplicates anything even if an admin renamed the component.
    #
    # The process + component are created UNPUBLISHED (draft): an admin reviews,
    # configures moderation and then publishes — nothing empty is exposed the
    # instant this runs.
    #
    #   DecidimApp::Bijeljina::CivicDebatesSetup.call(organization: org)
    class CivicDebatesSetup
      SLUG = "mi-odlucujemo"
      COMPONENT_MANIFEST = "debates"

      def self.call(organization:)
        new(organization:).call
      end

      def initialize(organization:)
        @organization = organization
      end

      # Returns the persisted Decidim::ParticipatoryProcess.
      def call
        ensure_debates_manifest!
        process = find_or_create_process
        ensure_active_step(process)
        process.reload
        ensure_debates_component(process)
        process
      end

      private

      attr_reader :organization

      # The Debates component ships with the `decidim` meta-gem. Refuse to
      # half-build if it is somehow missing rather than create an empty space.
      def ensure_debates_manifest!
        return if Decidim.find_component_manifest(:debates)

        raise "Decidim debates component manifest is not available — is " \
              "decidim-debates in the bundle?"
      end

      def find_or_create_process
        existing = Decidim::ParticipatoryProcess.find_by(organization:, slug: SLUG)
        return existing if existing

        Decidim::ParticipatoryProcess.create!(process_attributes)
      end

      def process_attributes
        {
          organization:,
          slug: SLUG,
          title: translatable("Mi odlučujemo!"),
          subtitle: translatable("Građanske debate o životu u Bijeljini"),
          short_description: translatable(short_description_text),
          description: translatable(description_text),
          start_date: Date.current,
          # Ongoing space — no fixed end date.
          end_date: nil,
          # Draft: the admin reviews/configures, then publishes.
          published_at: nil
        }
      end

      def ensure_active_step(process)
        return if process.steps.any?

        Decidim::ParticipatoryProcessStep.create!(
          participatory_process: process,
          title: translatable("Otvorene debate"),
          active: true,
          start_date: Date.current,
          end_date: nil
        )
      end

      def ensure_debates_component(process)
        # One Debates component — match on manifest_name only, so an admin
        # renaming it never causes a duplicate on the next run.
        return if process.components.where(manifest_name: COMPONENT_MANIFEST).any?

        Decidim::Component.create!(
          participatory_space: process,
          manifest_name: COMPONENT_MANIFEST,
          name: translatable("Mi odlučujemo!"),
          settings: global_settings,
          step_settings: step_settings_for(process),
          # Draft alongside the process; the admin publishes after configuring.
          published_at: nil
        )
      end

      # Global settings for a moderated civic-debate space.
      def global_settings
        {
          comments_enabled: true,
          # `comments_max_length` is required with no manifest default.
          comments_max_length: 1000,
          attachments_allowed: true
        }
      end

      # Per-step settings: citizens may open debates (creation_enabled) and like
      # them; comments stay open. Moderation tools handle abuse.
      def step_settings_for(process)
        settings = {
          creation_enabled: true,
          likes_enabled: true,
          comments_blocked: false
        }

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

      def short_description_text
        "Prostor za otvorene građanske debate o temama važnim za Bijeljinu i " \
          "našu zajednicu."
      end

      def description_text
        "„Mi odlučujemo!“ je prostor za stalne građanske debate Lokalne " \
          "fondacije Bijeljina. Ovdje građani otvaraju teme o gradu i " \
          "zajedničkom životu, razmjenjuju argumente i zajedno tragaju za " \
          "rješenjima. Za razliku od grant ciklusa „Ti se pitaš!“, debate " \
          "nisu vezane za godinu — razgovor o zajednici traje neprekidno."
      end
    end
  end
end
