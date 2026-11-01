# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # The foundation's own open/closed call status and review window, editable
    # by an operator instead of `config/milica/foundation_sources.yml`.
    #
    # One row per organization; draft -> approved -> rolled_back. Only the
    # APPROVED row reaches Milica::FoundationRead, which then takes the review
    # dates and the call status from it instead of the shipped YAML. Nothing
    # here is citizen data; `approved_by_id` is an operator audit field.
    class FoundationStatusOverride < ApplicationRecord
      self.table_name = "decidim_app_foundation_status_overrides"

      STATES = %w(draft approved rolled_back).freeze
      OPEN_STATUSES = %w(open closed unverified).freeze
      PERMISSION = CityServiceEntry::PERMISSION
      EDITABLE_ATTRIBUTES = %w(current_open_status reviewed_on review_expires_on).freeze

      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: "decidim_organization_id"
      belongs_to :approver, class_name: "Decidim::User", foreign_key: "approved_by_id", optional: true

      validates :decidim_organization_id, uniqueness: true
      validates :current_open_status, inclusion: { in: OPEN_STATUSES }
      validates :state, inclusion: { in: STATES }
      validates :reviewed_on, :review_expires_on, presence: true
      validate :reviewed_on_not_in_future
      validate :review_expires_after_reviewed_on

      scope :approved, -> { where(state: "approved") }

      STATES.each { |value| define_method(:"#{value}?") { state == value } }

      class << self
        def approved_for(organization)
          approved.find_by(decidim_organization_id: organization.id)
        end

        def for_organization(organization)
          find_or_initialize_by(decidim_organization_id: organization.id) do |row|
            row.current_open_status = "unverified"
            row.reviewed_on = Date.current
            row.review_expires_on = Date.current + 90
          end
        end
      end

      def live?
        approved?
      end

      # Assigns operator edits; a real change ends the current approval.
      def stage(attributes)
        assign_attributes(attributes.to_h.slice(*EDITABLE_ATTRIBUTES, *EDITABLE_ATTRIBUTES.map(&:to_sym)))
        self.state = "draft" if approved? && changed.intersect?(EDITABLE_ATTRIBUTES)
        self
      end

      def approve!(actor:)
        return :not_authorized unless permitted?(actor)
        return :invalid unless valid?

        with_lock do
          from_state = state
          update!(state: "approved", approved_at: Time.current, approver: actor)
          audit!(actor:, event_type: "foundation_status_approved", from_state:)
        end
        :approved
      end

      def rollback!(actor:)
        return :not_authorized unless permitted?(actor)
        return :not_approved unless approved?

        with_lock do
          from_state = state
          update!(state: "rolled_back", approved_at: nil, approver: nil)
          audit!(actor:, event_type: "foundation_status_rolled_back", from_state:)
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
          metadata: { from_state:, to_state: state, current_open_status:, reviewed_on: reviewed_on&.iso8601,
                      review_expires_on: review_expires_on&.iso8601 }
        )
      end

      def reviewed_on_not_in_future
        return if reviewed_on.blank? || reviewed_on <= Date.current

        errors.add(:reviewed_on, :in_future)
      end

      def review_expires_after_reviewed_on
        return if reviewed_on.blank? || review_expires_on.blank? || review_expires_on > reviewed_on

        errors.add(:review_expires_on, :not_after_reviewed_on)
      end
    end
  end
end
