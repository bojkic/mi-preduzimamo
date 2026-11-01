# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Idempotently creates the single long-lived Decidim storage hierarchy for
    # approved community-support projects. This is deliberately NOT a public
    # participatory process: citizens discover these records only through the
    # dedicated /biceriseno/projekti product, while genuine participatory
    # budgets keep their native process, voting and result pages.
    #
    # The component is draft by default. Production/bootstrap callers opt in
    # with `publish: true` to activate the technical component, but the parent
    # process always remains unpublished so it cannot be mistaken for a voting
    # process or appear in Decidim's public process directory.
    class CommunityProjectsSetup
      DEFAULT_SLUG = "projekti-zajednice"
      SETTINGS_NAMESPACE = "community_projects"
      BUDGET_ID_KEY = "budget_id"

      def self.call(organization:, slug: DEFAULT_SLUG, publish: false)
        new(organization:, slug:, publish:).call
      end

      def initialize(organization:, slug: DEFAULT_SLUG, publish: false)
        @organization = organization
        @slug = slug
        @publish = publish
      end

      # Returns the one Decidim budget used by project-approval services.
      def call
        process = find_or_create_process
        step = ensure_active_step(process)
        component = ensure_budgets_component(process, step)
        budget = ensure_budget(component)

        label_storage_hierarchy(process, component, budget)
        hide_storage_process(process)
        publish_storage_component(component) if publish?
        store_budget_id(budget)
        budget.reload
      end

      private

      attr_reader :organization, :slug

      def publish?
        @publish
      end

      def find_or_create_process
        Decidim::ParticipatoryProcess.find_or_create_by!(organization:, slug:) do |process|
          process.assign_attributes(
            title: translatable("Interna pohrana projekata podrške"),
            subtitle: translatable("Tehnička evidencija — nije participativni budžet"),
            short_description: translatable(
              "Interna Decidim pohrana za odobrene projekte podrške."
            ),
            description: translatable(
              "Ovaj proces nije javna participacija ni glasanje. Javna prijava, " \
              "doniranje i pomoć vode se na /biceriseno/projekti."
            ),
            start_date: Date.current,
            end_date: nil,
            published_at: nil
          )
        end
      end

      def ensure_active_step(process)
        process.steps.find_by(active: true) || process.steps.create!(
          title: translatable("Aktivni projekti"),
          active: true,
          start_date: Date.current,
          end_date: nil
        )
      end

      def ensure_budgets_component(process, step)
        process.components.find_by(manifest_name: "budgets") || Decidim::Component.create!(
          participatory_space: process,
          manifest_name: "budgets",
          name: translatable("Projekti i donacije"),
          settings: {
            comments_enabled: true,
            comments_max_length: 1000,
            geocoding_enabled: true,
            resources_permissions_enabled: true
          },
          step_settings: {
            step.id.to_s => {
              comments_blocked: false,
              votes: "disabled",
              show_votes: false
            }
          },
          published_at: nil
        )
      end

      def ensure_budget(component)
        budget = Decidim::Budgets::Budget.find_or_create_by!(component:) do |record|
          record.assign_attributes(
            title: translatable("Fond projekata zajednice"),
            description: translatable(
              "Svaki projekat ima svoj cilj prikupljanja sredstava i provjeren način doniranja."
            ),
            total_budget: 1
          )
        end

        desired_total = [budget.projects.sum(:budget_amount), 1].max
        budget.update!(total_budget: desired_total) unless budget.total_budget == desired_total
        budget
      end

      def label_storage_hierarchy(process, component, budget)
        process.assign_attributes(
          title: translatable("Interna pohrana projekata podrške"),
          subtitle: translatable("Tehnička evidencija — nije participativni budžet"),
          short_description: translatable("Interna Decidim pohrana za odobrene projekte podrške."),
          description: translatable(
            "Ovaj proces nije javna participacija ni glasanje. Javna prijava, " \
            "doniranje i pomoć vode se na /biceriseno/projekti."
          )
        )
        component.assign_attributes(name: translatable("Interna evidencija projekata podrške"))
        budget.assign_attributes(
          title: translatable("Interni fond projekata podrške"),
          description: translatable(
            "Tehnički zbir ciljeva prikupljanja; glasanje je isključeno."
          )
        )

        [process, component, budget].each { |record| record.save! if record.changed? }
      end

      def hide_storage_process(process)
        process.update!(published_at: nil) if process.published?
      end

      def publish_storage_component(component)
        component.update!(published_at: Time.current) unless component.published?
      end

      def store_budget_id(budget)
        Decidim::Bih::Setting.put(
          organization,
          SETTINGS_NAMESPACE,
          BUDGET_ID_KEY,
          budget.id
        )
      end

      def translatable(serbian_string)
        {
          "sr" => serbian_string,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(serbian_string),
          "bs" => serbian_string,
          "hr" => serbian_string
        }
      end
    end
  end
end
