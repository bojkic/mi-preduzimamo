# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_foundation_reference"

module DecidimApp
  module Bijeljina
    module Milica
      # The APPROVED FoundationStatusOverride replaces the shipped YAML for the
      # review dates and the call status; drafts and rolled-back rows do not.
      class FoundationReadOverrideTest < ActiveSupport::TestCase
        include SyntheticFoundationReference
        setup { install_synthetic_foundation_reference }
        teardown { restore_synthetic_foundation_reference }
        QUERY = "Da li Lokalna fondacija Bijeljina finansira projekte građana?"

        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @reviewed_on = Date.current - 1
          @expires_on = Date.current + 30
        end

        test "without an approved override the shipped YAML governs" do
          FoundationStatusOverride.for_organization(@organization).tap do |draft|
            draft.stage(current_open_status: "open", reviewed_on: @reviewed_on, review_expires_on: @expires_on)
            draft.save!
          end

          result = ask

          assert_equal "ok", result.fetch(:status)
          assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
          assert_equal @synthetic_foundation_metadata.fetch("review_expires_on"), result.fetch(:validity).fetch("review_expires_on")
          assert_equal false, result.fetch(:coverage).fetch("current_call_verified")
          assert_equal I18n.t("decidim_app.milica.foundation_answers.call_status", locale: "sr"), call_status_fact(result).fetch("text")
        end

        test "an approved open status is answered as open with the override's dates and a stable fact id" do
          approve!(current_open_status: "open", reviewed_on: @reviewed_on, review_expires_on: @expires_on)

          %w(sr sr-Cyrl bs hr en).each do |locale|
            result = ask(locale:)

            assert_equal "ok", result.fetch(:status), locale
            assert_equal "open", result.fetch(:validity).fetch("current_call_status")
            assert_equal true, result.fetch(:coverage).fetch("current_call_verified")
            assert_equal @reviewed_on.iso8601, result.fetch(:validity).fetch("reviewed_on")
            assert_equal @expires_on.iso8601, result.fetch(:validity).fetch("review_expires_on")
            fact = call_status_fact(result)
            assert_equal "lfbn:idea_call:call_status", fact.fetch("id")
            assert_equal I18n.t("decidim_app.milica.foundation_answers.call_status_open", locale:, raise: true), fact.fetch("text")
            assert_equal @reviewed_on.iso8601, fact.fetch("reviewed_on")
            assert_equal "https://foundation.example.invalid/idea", fact.fetch("source_url")
          end
          assert Decidim::Bih::Concierge::Dialogue::Contracts::ReadResult.new(**ask)
        end

        test "a closed status uses the closed copy and an unverified override keeps the cautious copy" do
          approve!(current_open_status: "closed", reviewed_on: @reviewed_on, review_expires_on: @expires_on)
          result = ask
          assert_equal "closed", result.fetch(:validity).fetch("current_call_status")
          assert_equal I18n.t("decidim_app.milica.foundation_answers.call_status_closed", locale: "sr"), call_status_fact(result).fetch("text")

          override = FoundationStatusOverride.approved_for(@organization)
          override.stage(current_open_status: "unverified")
          override.save!
          override.approve!(actor: @admin)
          result = ask
          assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
          assert_equal false, result.fetch(:coverage).fetch("current_call_verified")
          assert_equal I18n.t("decidim_app.milica.foundation_answers.call_status", locale: "sr"), call_status_fact(result).fetch("text")
        end

        test "the override's window drives the staleness rule: expired, or asked before the approval" do
          approve!(current_open_status: "open", reviewed_on: Date.current - 40, review_expires_on: Date.current - 10)
          result = ask
          assert_equal "stale", result.fetch(:status)
          assert_equal ["foundation_reference_review_due"], result.fetch(:warnings)
          assert_equal (Date.current - 10).iso8601, result.fetch(:validity).fetch("review_expires_on")
          assert_equal "open", result.fetch(:validity).fetch("current_call_status")
          assert_empty result.fetch(:facts, [])

          override = FoundationStatusOverride.approved_for(@organization)
          override.stage(review_expires_on: @expires_on)
          override.save!
          override.approve!(actor: @admin)
          assert_equal "ok", ask.fetch(:status)

          assert_equal "stale", ask(now: 1.hour.ago).fetch(:status), "a question dated before the approval cannot use it"
        end

        test "a rolled-back override hands control back to the YAML" do
          approve!(current_open_status: "open", reviewed_on: @reviewed_on, review_expires_on: @expires_on)
          FoundationStatusOverride.approved_for(@organization).rollback!(actor: @admin)

          result = ask

          assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
          assert_equal @synthetic_foundation_metadata.fetch("review_expires_on"), result.fetch(:validity).fetch("review_expires_on")
        end

        test "an injected override object and an explicit nil are honoured without consulting the database" do
          injected = Struct.new(:current_open_status, :reviewed_on, :review_expires_on, :approved_at)
                           .new("open", @reviewed_on, @expires_on, 1.day.ago)
          result = FoundationRead.new(organization: @organization, status_override: injected)
                                 .call(topic: "community", entities: { "query" => QUERY }, context: context(Time.current), locale: "sr")
          assert_equal "open", result.fetch(:validity).fetch("current_call_status")

          approve!(current_open_status: "closed", reviewed_on: @reviewed_on, review_expires_on: @expires_on)
          result = FoundationRead.new(organization: @organization, status_override: nil)
                                 .call(topic: "community", entities: { "query" => QUERY }, context: context(Time.current), locale: "sr")
          assert_equal "unverified", result.fetch(:validity).fetch("current_call_status")
        end

        private

        def ask(locale: "sr", now: Time.current)
          FoundationRead.new(organization: @organization)
                        .call(topic: "community", entities: { "query" => QUERY }, context: context(now), locale:)
        end

        def context(now)
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "a" * 64, capabilities: ["public_reads"], now:
          )
        end

        def approve!(**attributes)
          override = FoundationStatusOverride.for_organization(@organization)
          override.stage(attributes)
          override.save!
          assert_equal :approved, override.approve!(actor: @admin)
          override
        end

        def call_status_fact(result)
          result.fetch(:facts).find { |fact| fact.fetch("source_id") == "lfbn:idea_call" }
        end
      end
    end
  end
end
