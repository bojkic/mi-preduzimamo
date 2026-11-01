# frozen_string_literal: true

require "test_helper"

module DecidimApp
  class LaunchModeTest < ActiveSupport::TestCase
    setup { @organization = create_organization }

    def sarajevo(str) = ActiveSupport::TimeZone["Europe/Sarajevo"].parse(str)

    test "inactive before the race window" do
      assert_not LaunchMode.active?(@organization, now: sarajevo("2026-09-05 23:59"))
    end

    test "active inside the race window" do
      assert LaunchMode.active?(@organization, now: sarajevo("2026-09-17 20:00"))
    end

    test "inactive after the freeze" do
      assert_not LaunchMode.active?(@organization, now: sarajevo("2026-10-14 20:01"))
    end

    test "an explicit setting wins in both directions" do
      Decidim::Bih::Setting.put(@organization, "launch", "mode", "off")
      assert_not LaunchMode.active?(@organization, now: sarajevo("2026-09-17 20:00"))
      Decidim::Bih::Setting.put(@organization, "launch", "mode", "on")
      assert LaunchMode.active?(@organization, now: sarajevo("2026-11-01 12:00"))
    end

    # Spec 6.1: the predicate is consulted several times per render (menu x2,
    # hero CTAs, hero stat floor, header, quick actions, bottom nav), so it is
    # cached for the duration of the request. CurrentAttributes gives us the
    # reset for free -- per request and per job, via the Rails executor.
    test "the decision is memoized per organization for the duration of a request" do
      calls = 0
      counting = lambda do |_organization, _namespace|
        calls += 1
        {}
      end

      Decidim::Bih::Setting.stub(:namespace_for, counting) do
        DecidimApp::Current.set(launch_mode_by_org: nil) do
          LaunchMode.active?(@organization)
          LaunchMode.active?(@organization)
          assert_equal 1, calls, "the second call within one request must be served from the memo"

          DecidimApp::Current.reset
          LaunchMode.active?(@organization)
          assert_equal 2, calls, "DecidimApp::Current.reset must clear the memo"
        end
      end
    end

    test "the memo is keyed per organization" do
      other = create_organization
      calls = 0
      counting = lambda do |_organization, _namespace|
        calls += 1
        {}
      end

      Decidim::Bih::Setting.stub(:namespace_for, counting) do
        DecidimApp::Current.set(launch_mode_by_org: nil) do
          LaunchMode.active?(@organization)
          LaunchMode.active?(other)
          assert_equal 2, calls, "a second organization must not read the first one's memo"
        end
      end
    end

    test "an explicit now: bypasses the memo" do
      calls = 0
      counting = lambda do |_organization, _namespace|
        calls += 1
        {}
      end

      Decidim::Bih::Setting.stub(:namespace_for, counting) do
        DecidimApp::Current.set(launch_mode_by_org: nil) do
          LaunchMode.active?(@organization, now: sarajevo("2026-09-17 20:00"))
          LaunchMode.active?(@organization, now: sarajevo("2026-10-14 20:01"))
          assert_equal 2, calls, "an explicit now: must not be served from (or write to) the memo"
          assert_nil DecidimApp::Current.launch_mode_by_org
        end
      end
    end
  end
end
