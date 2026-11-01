# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/budgets/test/factories"

module DecidimApp
  module Bijeljina
    class CommunityProjectsSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      test "creates one canonical community-project budget in a hidden storage process" do
        budget = CommunityProjectsSetup.call(organization: @organization)

        assert_instance_of Decidim::Budgets::Budget, budget
        assert_equal "projekti-zajednice", budget.participatory_space.slug
        assert_equal "Interna pohrana projekata podrške", budget.participatory_space.title["sr"]
        assert_equal "Interni fond projekata podrške", budget.title["sr"]
        assert_includes budget.participatory_space.description["sr"], "nije javna participacija ni glasanje"
      end

      test "disables voting while leaving project comments enabled" do
        budget = CommunityProjectsSetup.call(organization: @organization)
        component = budget.component
        step_settings = component.step_settings.values.first

        assert component.settings.comments_enabled
        assert_equal 1000, component.settings.comments_max_length
        assert_equal "disabled", step_settings.votes
        assert_not step_settings.show_votes
        assert_not step_settings.comments_blocked
      end

      test "stores the canonical budget id for the reusable approval service" do
        budget = CommunityProjectsSetup.call(organization: @organization)
        settings = Decidim::Bih::Setting.namespace_for(
          @organization,
          CommunityProjectsSetup::SETTINGS_NAMESPACE
        )

        assert_equal budget.id, settings.fetch(CommunityProjectsSetup::BUDGET_ID_KEY)
      end

      test "is idempotent" do
        first = CommunityProjectsSetup.call(organization: @organization)
        second = CommunityProjectsSetup.call(organization: @organization)

        assert_equal first.id, second.id
        assert_equal 1, Decidim::ParticipatoryProcess.where(
          organization: @organization,
          slug: CommunityProjectsSetup::DEFAULT_SLUG
        ).count
        assert_equal 1, first.component.participatory_space.steps.count
        assert_equal 1, first.component.participatory_space.components.where(manifest_name: "budgets").count
        assert_equal 1, Decidim::Budgets::Budget.where(component: first.component).count
      end

      test "creates draft structure unless publication is explicit" do
        budget = CommunityProjectsSetup.call(organization: @organization)

        assert_not budget.participatory_space.published?
        assert_not budget.component.published?
      end

      test "publishes only the storage component when requested" do
        draft = CommunityProjectsSetup.call(organization: @organization)
        published = CommunityProjectsSetup.call(organization: @organization, publish: true)

        assert_equal draft.id, published.id
        assert_not published.participatory_space.published?
        assert published.component.published?
      end

      test "repairs a mistakenly public storage process without disabling its component" do
        budget = CommunityProjectsSetup.call(organization: @organization, publish: true)
        budget.participatory_space.update!(published_at: Time.current)

        repaired = CommunityProjectsSetup.call(organization: @organization)

        assert_not repaired.participatory_space.published?
        assert repaired.component.published?
      end

      test "populates translated public fields in all supported locales" do
        budget = CommunityProjectsSetup.call(organization: @organization)

        %w(sr sr-Cyrl bs hr).each do |locale|
          assert budget.title.fetch(locale).present?, "budget title missing #{locale}"
          assert budget.participatory_space.title.fetch(locale).present?, "process title missing #{locale}"
        end
        assert_equal Decidim::Bih::Transliterator.call(budget.title["sr"]), budget.title["sr-Cyrl"]
      end

      test "keeps the technical budget total aligned with project fundraising goals" do
        budget = CommunityProjectsSetup.call(organization: @organization)
        create(:project, budget:, budget_amount: 2_500)
        create(:project, budget:, budget_amount: 7_500)

        refreshed = CommunityProjectsSetup.call(organization: @organization)

        assert_equal 10_000, refreshed.total_budget
      end
    end
  end
end
