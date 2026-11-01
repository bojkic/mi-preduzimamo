# frozen_string_literal: true

require "test_helper"
require "support/synthetic_messaging_configuration"

module Decidim
  module Bih
    module Sistem48
      # Round 25 (W4.4) — Sistem 48 forwarding targets (central intake + per-
      # category routing) are now DB-overridable per organization via
      # Decidim::Bih::Setting, with the same fallback discipline: an EMPTY store
      # must route exactly as the ENV/default path did before.
      class DepartmentRoutingSettingsTest < ActiveSupport::TestCase
        include SyntheticMessagingConfiguration

        teardown { restore_synthetic_intake }
        setup do
          install_synthetic_intake
          @organization = create_organization
        end

        # ---- fallback discipline: empty store == ENV/default --------------- #

        test "empty store routes every category to the central default" do
          assert_equal DepartmentRouting.central_intake,
                       DepartmentRouting.email_for(:putevi, @organization)
        end

        test "no organization given routes to the central default" do
          assert_equal DepartmentRouting.central_intake,
                       DepartmentRouting.email_for(:putevi)
        end

        test "central_intake reports the default when store empty" do
          assert_equal DepartmentRouting.central_intake,
                       DepartmentRouting.central_intake(@organization)
        end

        # ---- overrides ----------------------------------------------------- #

        test "a per-category override changes the forward target" do
          Decidim::Bih::Setting.put(
            @organization, DepartmentRouting::NAMESPACE, "putevi", "putevi@grad.example"
          )

          assert_equal "putevi@grad.example",
                       DepartmentRouting.email_for(:putevi, @organization)
          # A category without an override still routes to the default.
          assert_equal DepartmentRouting.central_intake,
                       DepartmentRouting.email_for(:rasvjeta, @organization)
        end

        test "a central-intake override changes the default for unmapped categories" do
          Decidim::Bih::Setting.put(
            @organization, DepartmentRouting::NAMESPACE,
            DepartmentRouting::CENTRAL_INTAKE_KEY, "intake@grad.example"
          )

          assert_equal "intake@grad.example",
                       DepartmentRouting.email_for(:rasvjeta, @organization)
          assert_equal "intake@grad.example",
                       DepartmentRouting.central_intake(@organization)
        end

        test "an override is scoped to its organization" do
          other = create_organization
          Decidim::Bih::Setting.put(
            @organization, DepartmentRouting::NAMESPACE, "putevi", "putevi@grad.example"
          )

          assert_equal DepartmentRouting.central_intake,
                       DepartmentRouting.email_for(:putevi, other)
        end

        # ---- mailer honours the override (end-to-end to: header) ----------- #

        test "the report mailer forwards to the per-category override" do
          Decidim::Bih::Setting.put(
            @organization, DepartmentRouting::NAMESPACE, "putevi", "putevi@grad.example"
          )

          mail = ReportMailer.report_email(
            organization_id: @organization.id,
            reference: "ABC123",
            category: :putevi,
            department: "Putevi",
            severity: :normalan,
            description: "Rupa",
            address: "Ulica 1",
            lat: 44.0,
            lng: 19.0
          )

          assert_equal ["putevi@grad.example"], mail.to
        end

        test "the report mailer falls back to the default with an empty store" do
          mail = ReportMailer.report_email(
            organization_id: @organization.id,
            reference: "ABC124",
            category: :putevi,
            department: "Putevi",
            severity: :normalan,
            description: "Rupa",
            address: "Ulica 1",
            lat: 44.0,
            lng: 19.0
          )

          assert_equal [DepartmentRouting.central_intake], mail.to
        end
      end
    end
  end
end
