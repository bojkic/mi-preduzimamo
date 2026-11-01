# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"

# Unit coverage for the figures behind the homepage hero stats strip
# (decidim-bih engine). The contract: org-scoped, sr-RS dot-delimited
# formatting, zero/empty stats omitted (except the fixed campaign figure,
# which is always shown), and EVERY stat individually rescued so one broken
# query can never blank the homepage.
class MiHeroStatsTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
  end

  test "computes citizens, proposals, campaign and verified sent-report stats" do
    create(:user, :confirmed, organization: @organization)
    create(:user, organization: @organization) # unconfirmed → not counted

    proposal_component = create(:proposal_component, organization: @organization)
    create(:proposal, component: proposal_component, published_at: Time.current)

    12.times { |i| seed_report(status: i < 9 ? "proslijedjeno" : "primljeno", forwarded_at: i < 9 ? Time.current : nil) }

    stats = Decidim::Bih::MiHeroStats.for(@organization)

    # 2 = the confirmed user above + the proposal factory's confirmed author.
    assert_equal "2", value_for(stats, "citizens")
    assert_equal "1", value_for(stats, "proposals")
    # The campaign tile replaced the old budget tile: a fixed, foundation-owned
    # figure instead of a summed demo budget nobody could stand behind.
    assert_equal "6.000 KM", value_for(stats, "campaign")
    assert_nil value_for(stats, "budget"), "the demo budget tile must stay gone"
    assert_equal "9", value_for(stats, "reports_sent")
    assert_nil value_for(stats, "reports_percent")
    assert_nil value_for(stats, "reports")
  end

  test "omits empty stats but always shows the fixed campaign figure" do
    stats = Decidim::Bih::MiHeroStats.for(@organization)

    assert_equal(["campaign"], stats.map { |stat| stat[:key] })
    assert_equal "6.000 KM", value_for(stats, "campaign")
  end

  test "shows recorded forwarding even below ten reports" do
    3.times { seed_report(status: "rijeseno", forwarded_at: Time.current) }
    2.times { seed_report(status: "primljeno") }

    assert_equal "3", value_for(Decidim::Bih::MiHeroStats.for(@organization), "reports_sent")
  end

  test "hides the forwarding figure when nothing has been sent" do
    2.times { seed_report(status: "primljeno") }

    assert_nil value_for(Decidim::Bih::MiHeroStats.for(@organization), "reports_sent")
  end

  test "each stat rescues independently so one failure hides only itself" do
    create(:user, :confirmed, organization: @organization)
    seed_report(status: "rijeseno", forwarded_at: Time.current)

    boom = ->(*) { raise "boom" }

    Decidim::Bih::Report.stub(:where, boom) do
      stats = Decidim::Bih::MiHeroStats.for(@organization)

      assert_nil value_for(stats, "reports_sent")
      assert_equal "1", value_for(stats, "citizens")
    end

    Decidim::User.stub(:where, boom) do
      stats = Decidim::Bih::MiHeroStats.for(@organization)

      assert_nil value_for(stats, "citizens")
      assert_equal "1", value_for(stats, "reports_sent")
    end
  end

  test "a transient per-stat failure is not cached as a partial result" do
    create(:user, :confirmed, organization: @organization)
    5.times { seed_report(status: "rijeseno", forwarded_at: Time.current) }

    cache = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, cache) do
      original_where = Decidim::Bih::Report.method(:where)
      fail_once = transient_failure(original_where)

      # First read: the reports-total stat raises transiently. The complete set must
      # NOT be cached as a partial — otherwise the figure stays hidden for the
      # full 10-minute TTL even after recovery.
      Decidim::Bih::Report.stub(:where, fail_once) do
        partial = Decidim::Bih::MiHeroStats.for(@organization)
        # The first Report.where call belongs to the raw total. The forwarded
        # count query is still allowed to recover within the same read.
        assert_nil value_for(partial, "reports_total")
        assert_equal "5", value_for(partial, "reports_sent")
        assert_equal "1", value_for(partial, "citizens")
      end

      # Second read (transient failure cleared): the reports figure must come
      # back, proving the partial was never cached.
      recovered = Decidim::Bih::MiHeroStats.for(@organization)
      assert_equal "5", value_for(recovered, "reports_total")
      assert_equal "5", value_for(recovered, "reports_sent")
      assert_equal "1", value_for(recovered, "citizens")
    end
  end

  test "forwarding count excludes other tenants, duplicates, and status-only claims" do
    main = seed_report(status: "proslijedjeno", forwarded_at: Time.current)
    seed_report(status: "odbijeno", forwarded_at: Time.current, duplicate_of: main)
    seed_report(status: "proslijedjeno")
    seed_report(status: "planirano")
    Decidim::Bih::Report.create!(organization: create_organization, description: "Other tenant", status: "proslijedjeno", forwarded_at: Time.current)

    assert_equal "1", value_for(Decidim::Bih::MiHeroStats.for(@organization), "reports_sent")
  end

  private

  # A stub callable that raises on its first invocation and afterwards delegates
  # to the captured original scope method.
  def transient_failure(real_method)
    raised = false
    lambda do |*args, &blk|
      unless raised
        raised = true
        raise "transient boom"
      end
      real_method.call(*args, &blk)
    end
  end

  def seed_report(status:, **attributes)
    Decidim::Bih::Report.create!(organization: @organization, description: "Test prijava", status:, **attributes)
  end

  def value_for(stats, key)
    stats.find { |stat| stat[:key] == key }&.fetch(:value)
  end
end
