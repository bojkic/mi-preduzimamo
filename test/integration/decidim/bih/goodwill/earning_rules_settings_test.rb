# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Goodwill
      # Round 25 (W4.2) — the earning schedule / daily caps / season start are now
      # DB-overridable per organization via Decidim::Bih::Setting, with strict
      # fallback discipline: an EMPTY store must behave byte-identically to the
      # pre-table DEFAULTS → config path. These tests pin that property and verify
      # that an override changes the awarded amount, the cap, and the season.
      class EarningRulesSettingsTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def award_report(user)
          report = Decidim::Bih::Report.create!(organization: user.organization, author: user, description: "Street light", status: "primljeno")
          EarningRules.new.award(user, :report, idempotency_key: IdempotencyKey.report(report.id))
        end

        # ---- fallback discipline: empty store == current behavior ---------- #

        test "empty store yields the default schedule values" do
          rules = EarningRules.new(organization: @organization)

          assert_equal EarningRules::DEFAULT_SCHEDULE[:report], rules.points_for(:report)
          assert_equal EarningRules::DEFAULT_SCHEDULE[:proposal], rules.points_for(:proposal)
        end

        test "empty store yields the default daily caps" do
          rules = EarningRules.new(organization: @organization)

          assert_equal EarningRules::DEFAULT_DAILY_CAPS[:report], rules.cap_for(:report)
        end

        test "no organization given keeps DEFAULTS -> config only" do
          rules = EarningRules.new

          assert_equal EarningRules::DEFAULT_SCHEDULE[:report], rules.points_for(:report)
        end

        test "empty store awards the default amount" do
          txn = award_report(@user)

          account = Ledger.new.account_for(@user)
          assert_equal EarningRules::DEFAULT_SCHEDULE[:report], account.balance
          assert txn.present?
        end

        # ---- schedule override changes the awarded amount ------------------ #

        test "a schedule override changes points_for" do
          Decidim::Bih::Setting.put(@organization, EarningRules::SCHEDULE_NAMESPACE, "report", 99)

          rules = EarningRules.new(organization: @organization)
          assert_equal 99, rules.points_for(:report)
        end

        test "a schedule override changes the awarded amount (no-org constructor)" do
          Decidim::Bih::Setting.put(@organization, EarningRules::SCHEDULE_NAMESPACE, "report", 77)

          award_report(@user)

          assert_equal 77, Ledger.new.account_for(@user).balance
        end

        test "an override is scoped to its organization" do
          other = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other)
          Decidim::Bih::Setting.put(@organization, EarningRules::SCHEDULE_NAMESPACE, "report", 99)

          award_report(other_user)

          # The other org has no override -> default amount.
          assert_equal EarningRules::DEFAULT_SCHEDULE[:report], Ledger.new.account_for(other_user).balance
        end

        # ---- cap override -------------------------------------------------- #

        test "a cap override changes cap_for" do
          Decidim::Bih::Setting.put(@organization, EarningRules::CAPS_NAMESPACE, "report", 1)

          rules = EarningRules.new(organization: @organization)
          assert_equal 1, rules.cap_for(:report)
        end

        test "a cap override is enforced on award" do
          Decidim::Bih::Setting.put(@organization, EarningRules::CAPS_NAMESPACE, "report", 1)

          first = award_report(@user)
          second = award_report(@user)

          assert first.present?, "first award under the cap should succeed"
          assert_nil second, "second award should be capped"
          assert_equal EarningRules::DEFAULT_SCHEDULE[:report], Ledger.new.account_for(@user).balance
        end

        # ---- season -------------------------------------------------------- #

        test "season_started_at falls back to config when store empty" do
          assert_equal Decidim::Bih.goodwill_season_started_at,
                       EarningRules.season_started_at(@organization)
        end

        test "a season override is respected" do
          Decidim::Bih::Setting.put(
            @organization, EarningRules::SEASON_NAMESPACE, EarningRules::SEASON_KEY, "2026-01-01"
          )

          season = EarningRules.season_started_at(@organization)
          assert_equal Time.zone.parse("2026-01-01"), season
        end

        test "a malformed season override falls back to config" do
          Decidim::Bih::Setting.put(
            @organization, EarningRules::SEASON_NAMESPACE, EarningRules::SEASON_KEY, "not-a-date"
          )

          assert_equal Decidim::Bih.goodwill_season_started_at,
                       EarningRules.season_started_at(@organization)
        end
      end
    end
  end
end
