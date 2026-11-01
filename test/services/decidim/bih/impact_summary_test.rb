# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ImpactSummaryTest < ActiveSupport::TestCase
      FakeTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
      FakeProject = Struct.new(:title, :donate_url, :totals, keyword_init: true)
      FakeProvider = Struct.new(:totals, :donate_url, :currency_label, :project_mappings, keyword_init: true)

      setup do
        @organization = create_organization
        @other_organization = create_organization
        @original_provider = Decidim::Bih.donations_provider
        Decidim::Bih.donations_provider = fake_provider
        @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Tajno Ime")
        @other_citizen = FactoryBot.create(:user, :confirmed, organization: @other_organization)
        @mz = LocalArea.create!(
          organization: @organization,
          kind: "mz",
          slug: "mz-centar",
          name: { "sr" => "Centar" }
        )
        @komsiluk = LocalArea.create!(
          organization: @organization,
          kind: "komsiluk",
          slug: "komsiluk-centar",
          primary_mz_slug: @mz.slug,
          name: { "sr" => "Centar sjever" }
        )
      end

      teardown do
        Decidim::Bih.donations_provider = @original_provider
      end

      test "builds organization-scoped public aggregate totals" do
        create_report(status: "rijeseno", category: "putevi")
        create_report(status: "rijeseno", category: "rasvjeta")
        create_report(status: "u_obradi", category: "putevi")
        Decidim::Bih::Report.create!(
          organization: @other_organization,
          description: "Foreign report",
          status: "rijeseno",
          category: "putevi",
          mz_slug: @mz.slug
        )

        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Sadnja",
          active: true,
          review_status: "approved",
          starts_at: 2.days.from_now
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 4,
          status: "approved"
        )
        other_opportunity = VolunteerOpportunity.create!(
          organization: @other_organization,
          title: "Other",
          active: true,
          review_status: "approved"
        )
        create_legacy_volunteer_log!(
          organization: @other_organization,
          opportunity: other_opportunity,
          user: @other_citizen,
          hours: 9,
          status: "approved"
        )

        ledger = Goodwill::Ledger.new
        ledger.award(@citizen, 120, reason: "volunteer_hour")
        ledger.spend(owner: @citizen, amount: 10, kind: "redeem", reason: "reward")
        ledger.award(@other_citizen, 900, reason: "foreign")

        3.times { |idx| create_post(title: "Tajni naslov #{idx}") }

        summary = ImpactSummary.new(organization: @organization).call

        assert_equal 3, summary.reports.total
        assert_equal 2, summary.reports.resolved
        assert_equal 1, summary.reports.open
        assert_equal 1, summary.reports.local_area_count
        assert_equal({ "putevi" => 2, "rasvjeta" => 1 }, summary.reports.category_counts)
        assert_equal BigDecimal("1250.25"), summary.donations.total_amount
        assert_equal 8, summary.donations.orders_count
        assert_equal "KM", summary.donations.currency_label
        assert_equal ["Novi vrtić"], summary.donations.projects.map(&:title)
        assert_equal 120, summary.goodwill.points_issued
        assert_equal 1, summary.goodwill.earn_transactions
        assert_equal 1, summary.goodwill.active_earners
        assert_equal 1, summary.goodwill.reward_redemptions
        assert_equal 4, summary.volunteering.approved_hours
        assert_equal 1, summary.volunteering.active_opportunities
        assert_equal 1, summary.volunteering.upcoming_opportunities
        assert_equal 3, summary.komsiluk.posts
        assert_equal 3, summary.komsiluk.visible
        assert_equal 1, summary.komsiluk.active_komsiluci
        assert_equal 1, summary.area_activity.size
        assert_equal "Centar", summary.area_activity.first.name
        assert_equal 3, summary.area_activity.first.public_reports
        assert_nil summary.area_activity.first.public_resolved_reports
        assert_equal 3, summary.area_activity.first.public_komsiluk_posts
      end

      test "builds public trend metrics from current and previous aggregate windows" do
        now = Time.zone.local(2026, 6, 18, 12, 0, 0)

        create_report(created_at: now - 2.days)
        create_report(created_at: now - 30.days)
        create_report(created_at: now - 45.days)
        create_report(created_at: now - 70.days)
        Decidim::Bih::Report.create!(
          organization: @other_organization,
          description: "Foreign current report",
          created_at: now - 2.days
        )

        current_resolved = nil
        previous_resolved = nil
        previous_resolved_edited_later = nil
        travel_to(now - 70.days) { current_resolved = create_report }
        travel_to(now - 5.days) { current_resolved.update!(status: "rijeseno") }
        travel_to(now - 70.days) { previous_resolved = create_report }
        travel_to(now - 40.days) { previous_resolved.update!(status: "rijeseno") }
        travel_to(now - 70.days) { previous_resolved_edited_later = create_report }
        travel_to(now - 40.days) { previous_resolved_edited_later.update!(status: "rijeseno") }
        travel_to(now - 5.days) { previous_resolved_edited_later.update!(internal_note: "Operator edit") }

        ledger = Goodwill::Ledger.new
        travel_to(now - 35.days) { ledger.award(@citizen, 50, reason: "previous trend secret") }
        travel_to(now - 3.days) { ledger.award(@citizen, 80, reason: "current trend secret") }
        travel_to(now - 2.days) { ledger.spend(owner: @citizen, amount: 5, kind: "redeem", reason: "redeem ignored") }
        travel_to(now - 2.days) { ledger.award(@other_citizen, 900, reason: "foreign ignored") }

        opportunity = VolunteerOpportunity.create!(
          organization: @organization,
          title: "Trend akcija",
          active: true,
          review_status: "approved"
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 4,
          status: "approved",
          verified_at: now - 4.days,
          created_at: now - 20.days
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 2,
          status: "approved",
          verified_at: now - 40.days,
          created_at: now - 45.days
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 6,
          status: "approved",
          verified_at: now - 40.days,
          created_at: now - 2.days
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 1,
          status: "approved",
          created_at: now - 2.days
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 9,
          status: "pending",
          created_at: now - 2.days
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @citizen,
          hours: 8,
          status: "rejected",
          verified_at: now - 2.days,
          created_at: now - 2.days
        )

        create_post(created_at: now - 1.day)
        create_post(created_at: now - 2.days)
        create_post(created_at: now - 40.days)
        create_post(status: "hidden", created_at: now - 1.day)
        other_komsiluk = LocalArea.create!(
          organization: @other_organization,
          kind: "komsiluk",
          slug: "other-komsiluk",
          name: { "sr" => "Drugi komšiluk" }
        )
        KomsilukPost.create!(
          organization: @other_organization,
          author: @other_citizen,
          komsiluk: other_komsiluk,
          title: "Foreign post",
          body: "Foreign body",
          created_at: now - 1.day
        )

        summary = nil
        travel_to(now) do
          summary = ImpactSummary.new(organization: @organization, since: 30.days.ago).call
        end
        metrics = summary.trend_metrics.index_by(&:key)

        assert_equal(
          [
            :reports_created,
            :reports_resolved,
            :goodwill_points_earned,
            :volunteer_hours_verified,
            :komsiluk_posts_created
          ],
          summary.trend_metrics.map(&:key)
        )

        assert_equal 2, metrics.fetch(:reports_created).current
        assert_equal 1, metrics.fetch(:reports_created).previous
        assert_equal 1, metrics.fetch(:reports_created).delta
        assert_equal "up", metrics.fetch(:reports_created).direction

        assert_equal 1, metrics.fetch(:reports_resolved).current
        assert_equal 2, metrics.fetch(:reports_resolved).previous
        assert_equal(-1, metrics.fetch(:reports_resolved).delta)
        assert_equal "down", metrics.fetch(:reports_resolved).direction

        assert_equal 80, metrics.fetch(:goodwill_points_earned).current
        assert_equal 50, metrics.fetch(:goodwill_points_earned).previous
        assert_equal 5, metrics.fetch(:volunteer_hours_verified).current
        assert_equal 8, metrics.fetch(:volunteer_hours_verified).previous
        assert_equal 2, metrics.fetch(:komsiluk_posts_created).current
        assert_equal 1, metrics.fetch(:komsiluk_posts_created).previous
      end

      test "does not carry raw PII into the public result payload" do
        report = create_report(
          description: "Tajni opis 065123456",
          reporter_email: "tajni@example.org",
          reporter_phone: "+38765123456",
          latitude: 44.755,
          longitude: 19.215
        )
        VolunteerAvailability.create!(
          organization: @organization,
          user: @citizen,
          availability: "Samo nedjeljom na privatnoj adresi",
          interests: "Privatna bilješka"
        )
        create_post(title: "Privatan naslov", body: "Privatan tekst komšiluka")
        Goodwill::Ledger.new.award(@citizen, 20, reason: "report")

        payload = ImpactSummary.new(organization: @organization).call.to_h.to_json

        assert_not_includes payload, "Tajni opis"
        assert_not_includes payload, report.reference
        assert_not_includes payload, report.status_token
        assert_not_includes payload, "065123456"
        assert_not_includes payload, "tajni@example.org"
        assert_not_includes payload, "44.755"
        assert_not_includes payload, "19.215"
        assert_not_includes payload, "Samo nedjeljom"
        assert_not_includes payload, "Privatna bilješka"
        assert_not_includes payload, "Privatan naslov"
        assert_not_includes payload, "Privatan tekst"
        assert_not_includes payload, "Tajno Ime"
      end

      test "suppresses sparse MZ activity rows" do
        create_report(status: "rijeseno")
        create_post

        summary = ImpactSummary.new(organization: @organization).call

        assert_empty summary.area_activity
      end

      private

      def fake_provider
        FakeProvider.new(
          totals: FakeTotals.new(total: BigDecimal("1250.25"), count: 8, currency: "BAM", as_of: Time.current),
          donate_url: "https://fondacijabijeljina.com",
          currency_label: "KM",
          project_mappings: [
            FakeProject.new(
              title: "Novi vrtić",
              donate_url: "https://fondacijabijeljina.com?utm_campaign=novi-vrtic",
              totals: FakeTotals.new(total: BigDecimal("300"), count: 2, currency: "BAM", as_of: Time.current)
            )
          ]
        )
      end

      def create_report(**attrs)
        Decidim::Bih::Report.create!(
          {
            organization: @organization,
            description: "Javni problem",
            category: "putevi",
            mz_slug: @mz.slug
          }.merge(attrs)
        )
      end

      def create_post(**attrs)
        Decidim::Bih::KomsilukPost.create!(
          {
            organization: @organization,
            author: @citizen,
            komsiluk: @komsiluk,
            category: "general",
            title: "Komšiluk objava",
            body: "Tekst objave"
          }.merge(attrs)
        )
      end
    end
  end
end
