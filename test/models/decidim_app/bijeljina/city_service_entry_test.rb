# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_service_directory"

module DecidimApp
  module Bijeljina
    class CityServiceEntryTest < ActiveSupport::TestCase
      include SyntheticServiceDirectory
      setup { install_synthetic_service_directory }
      teardown { restore_synthetic_service_directory }
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "only shipped FAQ keys can be overridden, once per organization" do
        entry = build_entry(key: "nepostojeci_kljuc")

        assert_not entry.valid?
        assert_includes entry.errors[:key], I18n.t("activerecord.errors.models.decidim_app/bijeljina/city_service_entry.attributes.key.not_shipped")

        build_entry.save!
        duplicate = build_entry

        assert_not duplicate.valid?
        assert_includes duplicate.errors.attribute_names, :key
      end

      test "requires title, body and a public http(s) source without credentials" do
        entry = build_entry(title: "", body: "", source_url: "ftp://user:pw@example.org/x")

        assert_not entry.valid?
        assert_includes entry.errors.attribute_names, :title
        assert_includes entry.errors.attribute_names, :body
        assert_includes entry.errors.attribute_names, :source_url

        entry.assign_attributes(title: "Odvoz", body: "Tekst", source_url: "https://user:pw@waste.example.invalid/")
        assert_not entry.valid?
        assert_includes entry.errors.attribute_names, :source_url

        entry.source_url = "https://waste.example.invalid/raspored"
        assert_predicate entry, :valid?
      end

      test "state is one of draft, approved and rolled_back and the checked date cannot be in the future" do
        entry = build_entry(state: "published")
        assert_not entry.valid?
        assert_includes entry.errors.attribute_names, :state

        entry.state = "draft"
        entry.source_checked_on = Date.current + 1
        assert_not entry.valid?
        assert_includes entry.errors.attribute_names, :source_checked_on
      end

      test "the content hash covers title, body and source_url and is only recorded at approval" do
        entry = build_entry
        entry.save!

        assert_nil entry.reviewed_content_hash
        assert_not_predicate entry, :live?
        assert_equal Digest::SHA256.hexdigest(["Odvoz smeća (novi termin)", "Novi tekst odgovora.", "https://waste.example.invalid/novo"].join("")),
                     entry.content_hash
      end

      test "approve records the hash, the approver and the time, and only a permitted actor may do it" do
        entry = build_entry
        entry.save!

        assert_equal :not_authorized, entry.approve!(actor: @citizen)
        assert_predicate entry.reload, :draft?

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_entry_approved").count }, 1 do
          assert_equal :approved, entry.approve!(actor: @admin)
        end
        entry.reload
        assert_predicate entry, :approved?
        assert_predicate entry, :live?
        assert_equal entry.content_hash, entry.reviewed_content_hash
        assert_equal @admin.id, entry.approved_by_id
        assert_in_delta Time.current, entry.approved_at, 5.seconds
      end

      test "editing approved content drops the row back to draft so the shipped constant is used until re-approval" do
        entry = build_entry
        entry.save!
        entry.approve!(actor: @admin)

        entry.stage(title: "Odvoz smeća (novi termin)")
        assert_predicate entry, :approved?, "saving without a content change keeps approval"

        entry.stage(body: "Izmijenjen tekst.")
        entry.save!

        assert_predicate entry, :draft?
        assert_not_predicate entry, :live?
        assert_not_equal entry.content_hash, entry.reviewed_content_hash
      end

      test "rollback withdraws an approved override and keeps its text for a later draft" do
        entry = build_entry
        entry.save!

        assert_equal :not_approved, entry.rollback!(actor: @admin)

        entry.approve!(actor: @admin)
        assert_equal :not_authorized, entry.rollback!(actor: @citizen)

        assert_difference -> { Decidim::Bih::OperatorAuditEvent.where(event_type: "city_service_entry_rolled_back").count }, 1 do
          assert_equal :rolled_back, entry.rollback!(actor: @admin)
        end
        entry.reload
        assert_predicate entry, :rolled_back?
        assert_not_predicate entry, :live?
        assert_nil entry.approved_at
        assert_nil entry.approved_by_id
        assert_equal "Novi tekst odgovora.", entry.body

        entry.stage(body: "Treći tekst.")
        assert_predicate entry, :draft?
      end

      test "override attributes feed the directory entry shape" do
        entry = build_entry(source_checked_on: Date.new(2026, 9, 12))

        assert_equal({ title: "Odvoz smeća (novi termin)", answer: "Novi tekst odgovora.",
                       source_url: "https://waste.example.invalid/novo", source_checked_on: "2026-09-12" },
                     entry.override_attributes)
      end

      private

      def build_entry(**attributes)
        CityServiceEntry.new(
          {
            organization: @organization,
            key: "otpad",
            title: "Odvoz smeća (novi termin)",
            body: "Novi tekst odgovora.",
            source_url: "https://waste.example.invalid/novo",
            source_checked_on: Date.current
          }.merge(attributes)
        )
      end
    end
  end
end
