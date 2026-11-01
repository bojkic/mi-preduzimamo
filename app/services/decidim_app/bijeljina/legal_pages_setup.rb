# frozen_string_literal: true

require "cgi"
require_relative "legal_pages_configuration"

module DecidimApp
  module Bijeljina
    # Idempotent setup for the public legal/static pages that must exist before
    # launch. It replaces Decidim's default Terms placeholder and groups the
    # legal pages under a footer-visible topic.
    #
    #   DecidimApp::Bijeljina::LegalPagesSetup.call(organization: org)
    class LegalPagesSetup
      def self.call(organization:, configuration: nil)
        new(organization:, configuration:).call
      end

      def initialize(organization:, configuration: nil)
        @organization = organization
        @configuration = LegalPagesConfiguration.load(configuration)
      end

      def call
        topic = ensure_topic
        created_pages = pages.map do |slug, config|
          ensure_page(slug, config, topic)
        end

        { topic:, pages: created_pages }
      end

      private

      attr_reader :organization, :configuration

      def pages = configuration.fetch(:pages)
      def contact_email = configuration.fetch(:contact_email)
      def contact_domain = configuration.fetch(:contact_domain)
      def topic_title = configuration.fetch(:topic_title)

      def ensure_topic
        topic = existing_topic || Decidim::StaticPageTopic.new(organization:)
        topic.assign_attributes(
          title: translatable(topic_title),
          description: translatable(configuration.fetch(:topic_description)),
          weight: 100,
          show_in_footer: true
        )
        topic.save!
        topic
      end

      def existing_topic
        page_topic = Decidim::StaticPage.where(organization:, slug: pages.keys)
                                        .where.not(topic_id: nil)
                                        .first&.topic
        return page_topic if page_topic&.organization == organization

        Decidim::StaticPageTopic.where(organization:).detect do |topic|
          topic.title["sr"] == topic_title
        end
      end

      def ensure_page(slug, config, topic)
        page = Decidim::StaticPage.find_or_initialize_by(organization:, slug:)
        page.assign_attributes(
          title: translatable(config.fetch(:title)),
          content: translatable_content(config.fetch(:sections), slug:),
          topic:,
          weight: config.fetch(:weight),
          allow_public_access: true
        )
        page.save!
        ensure_summary_block(page, config.fetch(:summary))
        page
      end

      def ensure_summary_block(page, summary)
        block = Decidim::ContentBlock.find_or_initialize_by(
          organization:,
          scope_name: "static_page",
          scoped_resource_id: page.id,
          manifest_name: "summary"
        )
        block.assign_attributes(
          settings: { "summary" => translatable(summary) },
          weight: 0,
          published_at: block.published_at || Time.current
        )
        block.save!
      end

      def translatable(serbian_string)
        {
          "sr" => serbian_string,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(serbian_string),
          "bs" => serbian_string,
          "hr" => serbian_string
        }
      end

      def translatable_content(sections, slug:)
        %w(sr sr-Cyrl bs hr).index_with do |locale|
          content_for(locale, sections, slug:)
        end
      end

      def content_for(locale, sections, slug:)
        updated_on = Date.iso8601(pages.fetch(slug).fetch(:updated_on)).strftime("%-d. %-m. %Y.")
        body = [
          paragraph(locale, "Zadnje ažuriranje: #{updated_on}")
        ]

        sections.each do |heading, paragraphs|
          body << heading(locale, heading)
          paragraphs.each { |text| body << paragraph(locale, text) }
        end

        body.join("\n")
      end

      def heading(locale, text)
        "<h2>#{escape(localize(text, locale))}</h2>"
      end

      def paragraph(locale, text)
        "<p>#{linkify(escape(localize(text, locale)))}</p>"
      end

      def contact_pattern
        @contact_pattern ||= Regexp.union(contact_email, contact_domain)
      end

      def localize(text, locale)
        return text unless locale == "sr-Cyrl"

        # Split around actual contact literals; ASCII placeholder words would
        # themselves be transliterated and could lose the original address.
        text.split(/(#{contact_pattern})/).map do |part|
          contact_pattern.match?(part) ? part : Decidim::Bih::Transliterator.call(part)
        end.join
      end

      def escape(text)
        CGI.escapeHTML(text)
      end

      def linkify(html)
        html.gsub(contact_pattern) do |contact|
          href = contact == contact_email ? "mailto:#{contact_email}" : "https://#{contact_domain}"
          %(<a href="#{href}">#{contact}</a>)
        end
      end
    end
  end
end
