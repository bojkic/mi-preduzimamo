# frozen_string_literal: true

require "date"
require "json"

module DecidimApp
  module Bijeljina
    # Community-owned publication copy. No inherited legal text or contacts.
    module LegalPagesConfiguration
      class Invalid < StandardError; end
      REQUIRED_SLUGS = %w(terms-of-service privacy-policy cookie-policy data-processing).freeze

      module_function

      def load(configuration = nil)
        if configuration.nil?
          path = ENV["MI_LEGAL_PAGES_PATH"].to_s
          raise Invalid, "Configure community legal pages before publication" if path.empty?

          configuration = JSON.parse(File.read(path))
        end
        data = JSON.parse(JSON.generate(configuration), symbolize_names: true)
        raise Invalid, "Legal pages configuration must be an object" unless data.is_a?(Hash)

        %i(topic_title topic_description contact_email contact_domain).each { |key| text!(data.fetch(key)) }
        unless /\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z/.match?(data.fetch(:contact_email)) &&
               /\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/i.match?(data.fetch(:contact_domain))
          raise Invalid, "Configure a plain community contact email and domain"
        end
        pages = data.fetch(:pages)
        unless pages.is_a?(Hash) && REQUIRED_SLUGS.all? { |slug| pages.key?(slug.to_sym) }
          raise Invalid, "Provide all four legal pages"
        end
        pages.each do |slug, page|
          raise Invalid, "Invalid page slug" unless /\A[a-z][a-z0-9-]*\z/.match?(slug.to_s)
          raise Invalid, "Page configuration must be an object" unless page.is_a?(Hash)

          %i(title summary updated_on).each { |key| text!(page.fetch(key)) }
          Date.iso8601(page.fetch(:updated_on))
          raise Invalid, "Page weight must be a nonnegative integer" unless page.fetch(:weight).is_a?(Integer) && page.fetch(:weight) >= 0

          sections = page.fetch(:sections)
          raise Invalid, "Provide page sections" unless sections.is_a?(Array) && sections.any?

          sections.each do |section|
            raise Invalid, "Section must contain a heading and paragraphs" unless section.is_a?(Array) && section.size == 2

            title, paragraphs = section
            text!(title)
            raise Invalid, "Provide section paragraphs" unless paragraphs.is_a?(Array) && paragraphs.any?

            paragraphs.each { |text| text!(text) }
          end
        end
        # Callers own their input; keep a separate normalized configuration.
        data[:pages] = pages.transform_keys(&:to_s)
        data
      rescue JSON::ParserError, JSON::GeneratorError, KeyError, Date::Error, Errno::ENOENT, Errno::EISDIR, TypeError
        raise Invalid, "Invalid or unavailable community legal pages configuration"
      end

      def text!(value)
        raise Invalid, "Legal page text must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
      end
    end
  end
end
