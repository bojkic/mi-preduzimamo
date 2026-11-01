# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/proposals/test/factories"
require "decidim/budgets/test/factories"
require "decidim/accountability/test/factories"

module DecidimApp
  module Bijeljina
    # Exercises the idempotent grant-cycle bootstrap against a real DB-backed
    # Decidim organization (locales sr/sr-Cyrl/bs/hr).
    class GrantCycleSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      test "creates the 'Ti se pitaš!' process with the expected slug" do
        process = GrantCycleSetup.call(organization: @organization)

        assert_instance_of Decidim::ParticipatoryProcess, process
        assert process.persisted?
        assert_equal "ti-se-pitas", process.slug
        assert_equal @organization, process.organization
        assert_equal "Ti se pitaš!", process.title["sr"]
      end

      test "attaches the proposals, budgets and accountability components" do
        process = GrantCycleSetup.call(organization: @organization)

        manifests = process.components.pluck(:manifest_name).sort

        assert_equal %w(accountability budgets proposals), manifests
      end

      test "enables citizen proposals and comments on the proposals component" do
        process = GrantCycleSetup.call(organization: @organization)
        proposals = process.components.find_by(manifest_name: "proposals")

        assert proposals.settings.comments_enabled
        assert_not proposals.settings.official_proposals_enabled

        step_setting = proposals.step_settings.values.first

        assert step_setting.creation_enabled
      end

      test "populates the process title for all four locales" do
        process = GrantCycleSetup.call(organization: @organization)

        assert_equal %w(sr sr-Cyrl bs hr).sort, process.title.keys.sort
        %w(sr sr-Cyrl bs hr).each do |locale|
          assert process.title[locale].present?, "title missing #{locale}"
        end
        # sr-Cyrl is the transliterated Latin source.
        assert_equal Decidim::Bih::Transliterator.call(process.title["sr"]),
                     process.title["sr-Cyrl"]
      end

      test "is idempotent: a second call reuses the same process" do
        first = GrantCycleSetup.call(organization: @organization)
        second = GrantCycleSetup.call(organization: @organization)

        assert_equal first.id, second.id
        assert_equal 1, Decidim::ParticipatoryProcess.where(
          organization: @organization, slug: "ti-se-pitas"
        ).count
      end

      test "is idempotent: a second call adds no duplicate components or steps" do
        GrantCycleSetup.call(organization: @organization)
        process = GrantCycleSetup.call(organization: @organization)

        assert_equal 3, process.components.count
        assert_equal 1, process.steps.count
      end

      test "honours a custom slug" do
        process = GrantCycleSetup.call(organization: @organization, slug: "grant-2026")

        assert_equal "grant-2026", process.slug
      end

      test "includes the year in the title when given" do
        process = GrantCycleSetup.call(organization: @organization, year: 2026)

        assert_equal "Ti se pitaš! 2026", process.title["sr"]
      end

      test "a year folds into the slug so each cycle is a distinct process" do
        base = GrantCycleSetup.call(organization: @organization)
        y2027 = GrantCycleSetup.call(organization: @organization, year: 2027)

        assert_equal "ti-se-pitas-2027", y2027.slug
        assert_not_equal base.id, y2027.id
      end

      test "creates the structure as a draft (unpublished) for admin review" do
        process = GrantCycleSetup.call(organization: @organization)

        assert_not process.published?
        assert(process.components.none?(&:published?))
      end
    end
  end
end
