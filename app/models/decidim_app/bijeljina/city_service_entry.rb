# frozen_string_literal: true

require "digest"
require "uri"

module DecidimApp
  module Bijeljina
    # An operator-reviewed override of ONE shipped city-service FAQ entry
    # (CityServicesData::ENTRIES), so the foundation can correct an answer
    # without a deploy.
    #
    # Lifecycle: draft -> approved -> rolled_back (-> draft again). Only an
    # APPROVED row whose title/body/source_url still hash to the value recorded
    # at approval is `live?`; CityDirectory reads exactly those rows. A draft,
    # a rolled-back row, or an approved row edited afterwards leaves the shipped
    # constant in force. The row stores no citizen data; `approved_by_id` is an
    # operator audit field.
    class CityServiceEntry < ApplicationRecord
      self.table_name = "decidim_app_city_service_entries"

      STATES = %w(draft approved rolled_back).freeze
      PERMISSION = :city_alerts_manage
      CONTENT_ATTRIBUTES = %w(title body source_url).freeze
      EDITABLE_ATTRIBUTES = (CONTENT_ATTRIBUTES + %w(source_checked_on)).freeze
      HASH_SEPARATOR = ""

      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: "decidim_organization_id"
      belongs_to :approver, class_name: "Decidim::User", foreign_key: "approved_by_id", optional: true

      validates :key, presence: true, uniqueness: { scope: :decidim_organization_id }
      validates :title, presence: true, length: { maximum: 200 }
      validates :body, presence: true, length: { maximum: 2_000 }
      validates :source_url, presence: true, length: { maximum: 500 }
      validates :state, inclusion: { in: STATES }
      validate :key_is_shipped
      validate :source_url_is_public_http
      validate :source_checked_on_not_in_future

      scope :for_organization, ->(organization) { where(decidim_organization_id: organization.id) }
      scope :approved, -> { where(state: "approved") }

      STATES.each { |value| define_method(:"#{value}?") { state == value } }

      class << self
        def shipped_keys
          CityServicesData::ENTRIES.map { |entry| entry.fetch(:key).to_s }
        end

        def shipped_entry(key)
          CityServicesData::ENTRIES.find { |entry| entry.fetch(:key).to_s == key.to_s }
        end

        def content_hash(title:, body:, source_url:)
          Digest::SHA256.hexdigest([title, body, source_url].map(&:to_s).join(HASH_SEPARATOR))
        end

        # The draft row for +key+, or a new one pre-filled from the shipped entry.
        def for_organization_and_key(organization, key)
          shipped = shipped_entry(key)
          return unless shipped

          for_organization(organization).find_by(key: key.to_s) ||
            new(organization:, key: key.to_s, title: shipped.fetch(:title), body: shipped.fetch(:answer),
                source_url: shipped.fetch(:source_url), source_checked_on: Date.iso8601(shipped.fetch(:source_checked_on)))
        end
      end

      def shipped_entry
        self.class.shipped_entry(key)
      end

      def content_hash
        self.class.content_hash(title:, body:, source_url:)
      end

      # True only for content the chat may render.
      def live?
        approved? && reviewed_content_hash.present? && reviewed_content_hash == content_hash
      end

      def approval_stale?
        approved? && !live?
      end

      # Assigns operator edits. Any content change ends the current approval:
      # the shipped constant is used until the new text is approved again.
      def stage(attributes)
        assign_attributes(attributes.to_h.slice(*EDITABLE_ATTRIBUTES, *EDITABLE_ATTRIBUTES.map(&:to_sym)))
        self.state = "draft" unless live?
        self
      end

      def override_attributes
        { title:, answer: body, source_url:, source_checked_on: source_checked_on&.iso8601 }
      end

      def approve!(actor:)
        return :not_authorized unless permitted?(actor)
        return :invalid unless valid?

        with_lock do
          from_state = state
          update!(state: "approved", reviewed_content_hash: content_hash, approved_at: Time.current, approver: actor)
          audit!(actor:, event_type: "city_service_entry_approved", from_state:)
        end
        :approved
      end

      def rollback!(actor:)
        return :not_authorized unless permitted?(actor)
        return :not_approved unless approved?

        with_lock do
          from_state = state
          update!(state: "rolled_back", approved_at: nil, approver: nil)
          audit!(actor:, event_type: "city_service_entry_rolled_back", from_state:)
        end
        :rolled_back
      end

      private

      def permitted?(actor)
        Decidim::Bih::OperatorAuthorization.allowed?(actor, PERMISSION, organization:)
      end

      def audit!(actor:, event_type:, from_state:)
        Decidim::Bih::OperatorAuditEvent.record!(
          organization:, actor:, event_type:, permission: PERMISSION.to_s,
          role: Decidim::Bih::OperatorAuthorization.role_for(actor, PERMISSION, organization:), resource: self,
          metadata: { key:, from_state:, to_state: state, reviewed_content_hash: }
        )
      end

      def key_is_shipped
        return if key.blank? || self.class.shipped_keys.include?(key.to_s)

        errors.add(:key, :not_shipped)
      end

      def source_url_is_public_http
        return if source_url.blank?

        uri = URI.parse(source_url)
        return if %w(http https).include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?

        errors.add(:source_url, :not_public_http)
      rescue URI::InvalidURIError
        errors.add(:source_url, :not_public_http)
      end

      def source_checked_on_not_in_future
        return if source_checked_on.blank? || source_checked_on <= Date.current

        errors.add(:source_checked_on, :in_future)
      end
    end
  end
end
