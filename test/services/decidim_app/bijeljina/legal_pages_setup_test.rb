# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_legal_pages"

module DecidimApp
  module Bijeljina
    class LegalPagesSetupTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @legal_configuration = SyntheticLegalPages.configuration
      end

      test "creates a footer-visible legal topic" do
        topic = setup_pages.fetch(:topic)
        assert topic.persisted?
        assert topic.show_in_footer?
        assert_equal "Izmišljeni pravni dokumenti", topic.title["sr"]
        assert_equal "Измишљени правни документи", topic.title["sr-Cyrl"]
      end

      test "creates the launch legal pages" do
        setup_pages
        assert_equal %w(cookie-policy data-processing privacy-policy terms-of-service), scoped_pages.pluck(:slug).sort
      end

      test "replaces Decidim's default terms placeholder" do
        terms = Decidim::StaticPage.find_or_initialize_by(organization: @organization, slug: "terms-of-service")
        terms.assign_attributes(title: { "sr" => "Default title" }, content: { "sr" => "Default content" })
        terms.save!
        setup_pages
        terms.reload
        assert_equal "Izmišljeni uslovi", terms.title["sr"]
        assert_includes terms.content["sr"], "IZMIŠLJENI TEST"
        summary = summary_for(terms)
        text = terms.title.values.join(" ") + terms.content.values.join(" ") + summary.settings.summary.values.join(" ")
        assert_includes summary.settings.summary["sr"], "Izmišljeni sažetak"
        assert_no_match(/Default title|Default content|Please add meaningful summary/, text)
      end

      test "populates title and content for the four public locales" do
        setup_pages
        page = scoped_pages.find_by!(slug: "privacy-policy")
        assert_equal %w(bs hr sr sr-Cyrl), page.title.keys.sort
        assert_equal %w(bs hr sr sr-Cyrl), page.content.keys.sort
        assert_includes page.content["sr"], "rok čuvanja A"
        assert_includes page.content["sr-Cyrl"], "рок чувања А"
        %w(sr sr-Cyrl bs hr).each do |locale|
          assert_includes page.content[locale], 'href="mailto:legal@community.example.invalid"'
          assert_includes page.content[locale], 'href="https://community.example.invalid"'
        end
      end

      test "publishes explicitly supplied fictional retention processor and date details" do
        setup_pages
        privacy = scoped_pages.find_by!(slug: "privacy-policy")
        processing = scoped_pages.find_by!(slug: "data-processing")
        assert_includes privacy.content["sr"], "3. 2. 2040."
        assert_includes privacy.content["sr-Cyrl"], "3. 2. 2040."
        assert_includes privacy.content["sr"], "rok čuvanja A, obrađivač B i način zahtjeva C"
        assert_includes processing.content["sr"], "2. 1. 2040."
        assert_includes processing.content["sr"], "lokalna pravila određuje vaša zajednica"
      end

      test "terms retain explicitly supplied separation of points rewards donations and voting" do
        setup_pages
        terms = scoped_pages.find_by!(slug: "terms-of-service")
        assert_includes terms.content["sr"], "bodovi, nagrade, donacije i glasanje imaju zasebna pravila"
        assert_includes terms.content["sr-Cyrl"], "бодови, награде, донације и гласање имају засебна правила"
      end

      test "populates summary content blocks for the four public locales" do
        setup_pages
        summary = summary_for(scoped_pages.find_by!(slug: "terms-of-service"))
        assert summary.published?
        assert_equal %w(bs hr sr sr-Cyrl), summary.settings.summary.keys.sort
        assert_includes summary.settings.summary["sr"], "Izmišljeni sažetak"
        assert_includes summary.settings.summary["sr-Cyrl"], "Измишљени сажетак"
      end

      test "makes all legal pages public and orders them under the same topic" do
        setup_pages
        pages = scoped_pages.order(:weight)
        assert_equal [10, 20, 30, 40], pages.map(&:weight)
        assert_equal [true], pages.map(&:allow_public_access).uniq
        assert_equal 1, pages.map(&:topic_id).uniq.size
      end

      test "is idempotent" do
        first = setup_pages
        second = setup_pages
        assert_equal first.fetch(:topic).id, second.fetch(:topic).id
        assert_equal 1, Decidim::StaticPageTopic.where(organization: @organization).count
        assert_equal 4, scoped_pages.count
      end

      test "unconfigured setup does not create a topic or page" do
        prior = ENV.delete("MI_LEGAL_PAGES_PATH")
        assert_no_difference ["Decidim::StaticPage.count", "Decidim::StaticPageTopic.count"] do
          assert_raises(LegalPagesConfiguration::Invalid) { LegalPagesSetup.call(organization: @organization) }
        end
      ensure
        prior.nil? ? ENV.delete("MI_LEGAL_PAGES_PATH") : ENV["MI_LEGAL_PAGES_PATH"] = prior
      end

      test "malformed late page is rejected before earlier pages are written" do
        @legal_configuration.fetch("pages").fetch("data-processing")["sections"] = []
        assert_no_difference ["Decidim::StaticPage.count", "Decidim::StaticPageTopic.count"] do
          assert_raises(LegalPagesConfiguration::Invalid) { setup_pages }
        end
      end

      test "setup remains scoped to its organization" do
        other = create_organization
        theirs = LegalPagesSetup.call(organization: other, configuration: SyntheticLegalPages.configuration)
        ours = setup_pages
        assert_not_equal theirs.fetch(:topic).id, ours.fetch(:topic).id
        assert_empty theirs.fetch(:pages).map(&:id) & ours.fetch(:pages).map(&:id)
        assert_equal 4, Decidim::StaticPage.where(organization: other).count
      end

      test "community paragraphs are escaped before contact links are added" do
        @legal_configuration.fetch("pages").fetch("privacy-policy").fetch("sections").first.last << '<script>alert("example")</script>'
        setup_pages
        content = scoped_pages.find_by!(slug: "privacy-policy").content.fetch("sr")
        assert_includes content, "&lt;script&gt;"
        assert_not_includes content, "<script>"
        assert_includes content, 'href="mailto:legal@community.example.invalid"'
      end

      private

      def setup_pages
        LegalPagesSetup.call(organization: @organization, configuration: @legal_configuration)
      end

      def scoped_pages
        Decidim::StaticPage.where(organization: @organization, slug: @legal_configuration.fetch("pages").keys)
      end

      def summary_for(page)
        Decidim::ContentBlock.find_by!(organization: @organization, scope_name: "static_page", scoped_resource_id: page.id, manifest_name: "summary")
      end
    end
  end
end
