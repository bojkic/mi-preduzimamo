# frozen_string_literal: true

require "json"

module DecidimApp
  module Bijeljina
    # Reviewed act extraction attached to an exact issue revision. New or changed
    # PDFs remain issue metadata until the extracted act is reviewed again.
    module GazetteActs
      PATH = ENV.fetch("MI_GAZETTE_ACTS_PATH", "").freeze

      class << self
        def all
          @all ||= (PATH.empty? ? [] : JSON.parse(File.read(PATH)).fetch("acts")).map { |row| row.deep_symbolize_keys.freeze }.freeze
        end

        def for_issue(number:, content_hash:)
          return [] unless content_hash.is_a?(String) && /\A[a-f0-9]{64}\z/i.match?(content_hash)

          all.select { |act| act.fetch(:issue_number) == number && act.fetch(:issue_content_hash) == content_hash }
        end
      end
    end
  end
end
