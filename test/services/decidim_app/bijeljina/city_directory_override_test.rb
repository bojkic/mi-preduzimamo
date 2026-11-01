# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    # Approved operator overrides shadow the shipped FAQ constants; drafts,
    # rolled-back rows and edited-after-approval rows never do.
    class CityDirectoryOverrideTest < ActiveSupport::TestCase
      NEW_BODY = "Odvoz kabastog otpada je od oktobra 2026. svakog prvog ponedjeljka u mjesecu."

      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        # Izmišljeni početni sadržaj; test ne zavisi od podataka Bijeljine.
        @previous_directory = CityDirectory.instance_variable_get(:@directory)
        @previous_sources = CityServiceSources::SOURCES
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, [{ key: "synthetic_directory", source_url: "https://community.example.invalid/", enabled: true }].freeze)
        shipped = { key: :otpad, title: "Primjer odvoza smeća", keywords: %w(odvoz smeca smece otpad),
                    answer: "Izmišljeni početni raspored.", source_url: "https://community.example.invalid/waste",
                    source_checked_on: "2026-01-01", record_kind: "service_guidance", location_scope: "citywide",
                    verification_scope: "source_guidance", effective_from: nil, effective_until: nil }
        shipped[:facts] = CityServicesData.entry_facts(shipped, checked_on: Date.new(2026, 1, 1))
        parking = shipped.merge(key: :parking, title: "Izmišljeni parking", keywords: %w(parking sms),
                                answer: "Izmišljeni način plaćanja parkinga.",
                                source_url: "https://community.example.invalid/parking",
                                answer_sections: { payment: "Izmišljeni opis plaćanja; ne slati SMS." })
        parking[:facts] = CityServicesData.entry_facts(parking, checked_on: Date.new(2026, 1, 1))
        @previous_entries = CityServicesData::ENTRIES
        CityServicesData.send(:remove_const, :ENTRIES)
        CityServicesData.const_set(:ENTRIES, [shipped.freeze, parking.freeze].freeze)
        CityDirectory.instance_variable_set(:@directory, Decidim::Bih::City::ServiceDirectory.new(CityServicesData::ENTRIES))
        @shipped = CityDirectory.directory.find(:otpad)
        @previous_concierge_org_host = ENV.fetch("DECIDIM_CONCIERGE_ORG_HOST", nil)
        ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @organization.host
      end

      teardown do
        CityDirectory.instance_variable_set(:@directory, @previous_directory)
        CityServiceSources.send(:remove_const, :SOURCES)
        CityServiceSources.const_set(:SOURCES, @previous_sources)
        CityServicesData.send(:remove_const, :ENTRIES)
        CityServicesData.const_set(:ENTRIES, @previous_entries)
        @previous_concierge_org_host.nil? ? ENV.delete("DECIDIM_CONCIERGE_ORG_HOST") : ENV["DECIDIM_CONCIERGE_ORG_HOST"] = @previous_concierge_org_host
      end

      test "the raw directory is untouched and a draft never changes find, all or search" do
        create_entry

        assert_equal @shipped, CityDirectory.directory.find(:otpad)
        assert_equal @shipped.fetch(:answer), CityDirectory.find(:otpad, organization: @organization).fetch(:answer)
        assert_equal @shipped.fetch(:answer), CityDirectory.for(@organization).all.find { |entry| entry[:key] == :otpad }.fetch(:answer)
        assert_equal @shipped.fetch(:answer), CityDirectory.search("odvoz smeca", organization: @organization).first.fetch(:answer)
      end

      test "an approved override is preferred by find, all, search and metadata_for, for that organization only" do
        entry = create_entry
        entry.approve!(actor: @admin)
        other = create_organization

        live = CityDirectory.find(:otpad, organization: @organization)
        assert_equal NEW_BODY, live.fetch(:answer)
        assert_equal "Odvoz smeća (novi raspored)", live.fetch(:title)
        assert_equal "https://community.example.invalid/kabasti", live.fetch(:source_url)
        assert_equal "2026-09-12", live.fetch(:source_checked_on)
        assert_equal "admin_override", live.fetch(:content_origin)
        assert_equal @shipped.fetch(:keywords), live.fetch(:keywords), "search terms stay shipped"
        assert_equal [{ id: "service:otpad", kind: "service_guidance", source_checked_on: "2026-09-12",
                        source_url: "https://community.example.invalid/kabasti", validity: "reviewed_source_guidance_not_live_service_status" }],
                     live.fetch(:facts)
        assert_predicate live, :frozen?

        assert_equal NEW_BODY, CityDirectory.for(@organization).all.find { |item| item[:key] == :otpad }.fetch(:answer)
        assert_equal NEW_BODY, CityDirectory.search("odvoz smeca", organization: @organization).first.fetch(:answer)
        assert_equal "2026-09-12", CityDirectory.metadata_for(:otpad, organization: @organization).fetch(:source_checked_on)
        assert_equal CityDirectory.all(organization: @organization).size, CityDirectory.directory.all.size

        assert_equal @shipped.fetch(:answer), CityDirectory.find(:otpad, organization: other).fetch(:answer)
        assert_equal NEW_BODY, CityDirectory.find(:otpad).fetch(:answer), "with no organization the concierge organization is used"
      end

      test "rollback and a post-approval edit both fall back to the shipped constant" do
        entry = create_entry
        entry.approve!(actor: @admin)
        assert_equal NEW_BODY, CityDirectory.find(:otpad, organization: @organization).fetch(:answer)

        entry.rollback!(actor: @admin)
        assert_equal @shipped, CityDirectory.find(:otpad, organization: @organization)

        entry.stage(body: NEW_BODY)
        entry.save!
        entry.approve!(actor: @admin)
        assert_equal NEW_BODY, CityDirectory.find(:otpad, organization: @organization).fetch(:answer)

        entry.update_columns(body: "Neodobrena izmjena.") # rubocop:disable Rails/SkipsModelValidations
        assert_predicate entry.reload, :approval_stale?
        assert_equal @shipped, CityDirectory.find(:otpad, organization: @organization), "edited-after-approval content must not render"
      end

      test "an override of a sectioned entry is rendered whole by DirectoryAnswer" do
        parking = CityDirectory.directory.find(:parking)
        entry = CityServiceEntry.for_organization_and_key(@organization, :parking)
        entry.stage(body: "Izmišljeni opis plaćanja parkinga; ne slati SMS.")
        entry.save!
        entry.approve!(actor: @admin)

        live = CityDirectory.find(:parking, organization: @organization)
        assert_not live.has_key?(:answer_sections)
        assert_equal live.fetch(:answer), Milica::DirectoryAnswer.call(entry: live, query: "Koji je SMS broj za plavu zonu?", locale: "sr")
        assert_equal parking.fetch(:answer_sections).fetch(:payment),
                     Milica::DirectoryAnswer.call(entry: parking, query: "Koji je SMS broj za parking?", locale: "sr")
      end

      test "ReadPort answers from the approved override and cites its source date and title" do
        entry = create_entry
        entry.approve!(actor: @admin)
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "a" * 64, capabilities: ["public_reads"], now: Time.utc(2026, 9, 13, 12)
        )

        result = Milica::ReadPort.new(organization: @organization, directory: CityDirectory.for(@organization))
                                 .call(action: "ask_information", topic: "waste", entities: {}, context:)

        assert_equal "ok", result.status
        fact = result.facts.fetch(0)
        assert_equal "service:otpad", fact.fetch("id")
        assert_equal NEW_BODY, fact.fetch("text")
        assert_equal "Odvoz smeća (novi raspored)", fact.fetch("source_label")
        assert_equal "https://community.example.invalid/kabasti", fact.fetch("source_url")
        assert_equal "2026-09-12", fact.fetch("observed_at")
        assert_equal "2026-09-12", result.validity.fetch("reviewed_on")
      end

      test "missing waste data does not prevent constructing the reader and is reported unavailable" do
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
          organization_id: @organization.id, conversation_key: "b" * 64, capabilities: ["public_reads"], now: Time.utc(2040, 4, 9, 12)
        )
        unavailable = -> { raise Decidim::Bih::City::WasteScheduleError, "synthetic unconfigured schedule" }
        WasteSchedule.stub(:default, unavailable) do
          reader = Milica::ReadPort.new(organization: @organization)
          answer = reader.call(action: "ask_information", topic: "waste",
                               entities: { "query" => "Kada je odvoz smeća u Izmišljenoj ulici?", "street" => "Izmišljena ulica" }, context:)
          assert_equal "unavailable", answer.status
          assert_includes answer.warnings, "schedule_unavailable"
          assert_empty answer.facts
        end
      end

      test "override_entry is the pure merge the admin preview uses" do
        merged = CityDirectory.override_entry(@shipped, title: "Naslov", answer: "Tekst.", source_url: "https://community.example.invalid/x", source_checked_on: nil)

        assert_equal "Tekst.", merged.fetch(:answer)
        assert_equal @shipped.fetch(:source_checked_on), merged.fetch(:source_checked_on), "a missing date keeps the shipped one"
        assert_equal "service:otpad", merged.fetch(:facts).first.fetch(:id)
        assert_predicate merged, :frozen?
        assert_equal @shipped, CityDirectory.directory.find(:otpad), "the shipped entry is never mutated"
      end

      private

      def create_entry
        entry = CityServiceEntry.for_organization_and_key(@organization, :otpad)
        entry.stage(title: "Odvoz smeća (novi raspored)", body: NEW_BODY,
                    source_url: "https://community.example.invalid/kabasti", source_checked_on: Date.new(2026, 9, 12))
        entry.save!
        entry
      end
    end
  end
end
