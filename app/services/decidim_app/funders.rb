# frozen_string_literal: true

module DecidimApp
  # Zajednica dodaje svoje partnere i logotipe, uz provjerena prava korišćenja.
  module Funders
    Funder = Struct.new(:key, :name, :src, :url, :leading, :own, :width, :height, keyword_init: true) do
      def linked? = url.present?
    end
    LIST = [].freeze
    def self.all = LIST
    def self.leading = LIST.find(&:leading)
    def self.row = LIST.reject(&:leading)
    def self.funding_statement(locale: I18n.locale) = nil
  end
end
