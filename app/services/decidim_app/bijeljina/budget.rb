# frozen_string_literal: true
require "date"
require "uri"
require "bigdecimal"

module DecidimApp
  module Bijeljina
    # Generic parsing stays in the engine; the community owns reviewed source
    # metadata. A parser's table subtotal is not a reviewed whole-budget total.
    module Budget
      DEFAULT_SOURCE_URL = "".freeze
      BUNDLED_TEXT_PATH = ENV.fetch("MI_BUDGET_TEXT_PATH", "").freeze
      YEAR = ENV["MI_BUDGET_YEAR"] && Integer(ENV.fetch("MI_BUDGET_YEAR"))
      SOURCE_CAPTURED_ON = ENV["MI_BUDGET_CHECKED_ON"] && Date.iso8601(ENV.fetch("MI_BUDGET_CHECKED_ON"))
      def self.source_url = ENV.fetch("MI_BUDGET_SOURCE_URL", "")

      def self.configured?
        uri = URI.parse(source_url)
        File.file?(BUNDLED_TEXT_PATH) && YEAR.is_a?(Integer) && (1900..2099).cover?(YEAR) &&
          SOURCE_CAPTURED_ON.is_a?(Date) && uri.is_a?(URI::HTTPS) && uri.host && uri.port == 443 && uri.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end

      # Explicit reviewed metadata; no fallback to Budget#total, which may be
      # just the sum of partial extracted rows or a table's stated subtotal.
      def self.headline_total
        value = ENV.fetch("MI_BUDGET_HEADLINE_TOTAL", "")
        return unless /\A\d{1,15}(?:\.\d{1,2})?\z/.match?(value)

        BigDecimal(value)
      end

      def self.table_page
        value = ENV.fetch("MI_BUDGET_TABLE_PAGE", "")
        return unless /\A[1-9]\d{0,3}\z/.match?(value)

        value.to_i
      end

      def self.default
        raise Decidim::Bih::City::BudgetError, "community budget data is not configured" unless configured?

        parsed = @default ||= Decidim::Bih::City::Budget.from_text(File.read(BUNDLED_TEXT_PATH))
        raise Decidim::Bih::City::BudgetError, "community budget fiscal year does not match reviewed metadata" unless parsed.year == YEAR

        parsed
      end
    end
  end
end
