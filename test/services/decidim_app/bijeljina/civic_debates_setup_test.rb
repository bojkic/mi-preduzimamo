# frozen_string_literal: true

require "test_helper"
require "decidim/participatory_processes/test/factories"
require "decidim/debates/test/factories"

module DecidimApp
  module Bijeljina
    # Exercises the idempotent civic-debates bootstrap against a real DB-backed
    # Decidim organization (locales sr/sr-Cyrl/bs/hr).
    class CivicDebatesSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
      end

      test "creates the 'Mi odlučujemo!' process with the expected slug" do
        process = CivicDebatesSetup.call(organization: @organization)

        assert_instance_of Decidim::ParticipatoryProcess, process
        assert process.persisted?
        assert_equal "mi-odlucujemo", process.slug
        assert_equal @organization, process.organization
        assert_equal "Mi odlučujemo!", process.title["sr"]
      end

      test "attaches a single debates component named 'Mi odlučujemo!'" do
        process = CivicDebatesSetup.call(organization: @organization)

        manifests = process.components.pluck(:manifest_name)

        assert_equal %w(debates), manifests
        debates = process.components.find_by(manifest_name: "debates")
        assert_equal "Mi odlučujemo!", debates.name["sr"]
      end

      test "the debates manifest is available in the bundle" do
        assert_not_nil Decidim.find_component_manifest(:debates)
      end

      test "enables citizen-created debates and comments" do
        process = CivicDebatesSetup.call(organization: @organization)
        debates = process.components.find_by(manifest_name: "debates")

        assert debates.settings.comments_enabled
        assert_equal 1000, debates.settings.comments_max_length

        step_setting = debates.step_settings.values.first

        assert step_setting.creation_enabled
        assert step_setting.likes_enabled
      end

      test "populates the process title for all four locales" do
        process = CivicDebatesSetup.call(organization: @organization)

        assert_equal %w(sr sr-Cyrl bs hr).sort, process.title.keys.sort
        %w(sr sr-Cyrl bs hr).each do |locale|
          assert process.title[locale].present?, "title missing #{locale}"
        end
        # sr-Cyrl is the transliterated Latin source.
        assert_equal Decidim::Bih::Transliterator.call(process.title["sr"]),
                     process.title["sr-Cyrl"]
      end

      test "populates the long description for all four locales" do
        process = CivicDebatesSetup.call(organization: @organization)

        %w(sr sr-Cyrl bs hr).each do |locale|
          assert process.description[locale].present?, "description missing #{locale}"
        end
      end

      test "is idempotent: a second call reuses the same process" do
        first = CivicDebatesSetup.call(organization: @organization)
        second = CivicDebatesSetup.call(organization: @organization)

        assert_equal first.id, second.id
        assert_equal 1, Decidim::ParticipatoryProcess.where(
          organization: @organization, slug: "mi-odlucujemo"
        ).count
      end

      test "is idempotent: a second call adds no duplicate components or steps" do
        CivicDebatesSetup.call(organization: @organization)
        process = CivicDebatesSetup.call(organization: @organization)

        assert_equal 1, process.components.count
        assert_equal 1, process.steps.count
      end

      test "creates the structure as a draft (unpublished) for admin review" do
        process = CivicDebatesSetup.call(organization: @organization)

        assert_not process.published?
        assert(process.components.none?(&:published?))
      end
    end
  end
end
