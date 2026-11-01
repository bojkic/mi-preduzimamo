# frozen_string_literal: true

require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # Only the installation's explicitly public operator settings. No user,
      # partner, mailer credential or municipality record is queried here.
      module PlatformSupportContact
        def self.values(settings: Decidim::Bih)
          name = clean(settings.public_support_name, limit: 200)
          email = clean(settings.public_support_email, limit: 254)
          website = clean(settings.public_support_website, limit: 2_000)
          email = nil unless email && URI::MailTo::EMAIL_REGEXP.match?(email)
          website = nil unless website && public_website?(website)
          { "name" => name, "email" => email, "website" => website }.compact.freeze
        end

        def self.clean(value, limit:)
          return unless value.is_a?(String) && value.valid_encoding?

          text = value.encode(Encoding::UTF_8)
          return if text.length > limit || text.match?(/[[:cntrl:]]/)

          text = text.strip
          text unless text.empty?
        rescue EncodingError
          nil
        end

        def self.public_website?(value)
          uri = URI.parse(value)
          uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && uri.port == 443 && uri.userinfo.nil?
        rescue URI::InvalidURIError
          false
        end
        private_class_method :clean, :public_website?
      end
    end
  end
end
