# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    # Tests for BroadcastNotificationJob — Wave B2.
    # Verifies: one bell per eligible user; Viber only for linked users when
    # channel is on; blocked/deleted users excluded; no email.
    class BroadcastNotificationJobTest < ActiveJob::TestCase
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        @user1 = FactoryBot.create(:user, :confirmed, organization: @organization)
        @user2 = FactoryBot.create(:user, :confirmed, organization: @organization)
        @area_id = 42
      end

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
      end

      # ─── Queue (must be one Sidekiq actually consumes) ───────────────────────

      test "runs on a queue that the Sidekiq process consumes" do
        configured = YAML.load_file(Rails.root.join("config/sidekiq.yml"))[:queues].map { |q| q.first.to_s }
        assert_includes configured, BroadcastNotificationJob.new.queue_name,
                        "broadcast job queue must be listed in config/sidekiq.yml or it will never deliver"
      end

      # ─── Bell notification ───────────────────────────────────────────────────

      test "publishes one bell notification per eligible user" do
        bells_published = []
        stub_events_manager(bells_published) do
          BroadcastNotificationJob.perform_now(
            organization_id: @organization.id,
            user_ids: [@user1.id, @user2.id],
            message: "Čišćenje parka sutra!",
            area_name: "Centar",
            area_id: @area_id,
            channels: ["bell"]
          )
        end

        assert_equal 2, bells_published.size
        bells_published.each do |payload|
          assert_equal "decidim.events.bih.local_broadcast", payload[:event]
          assert_equal Decidim::Bih::LocalBroadcastEvent, payload[:event_class]
          assert_equal "Čišćenje parka sutra!", payload[:extra]["message"]
          assert_equal "Centar", payload[:extra]["area_name"]
          assert payload[:force_send]
        end
      end

      test "bell event resource is the individual recipient and affected_users contains only that user" do
        bells_published = []
        stub_events_manager(bells_published) do
          BroadcastNotificationJob.perform_now(
            organization_id: @organization.id,
            user_ids: [@user1.id, @user2.id],
            message: "Test",
            area_name: "Komšiluk A",
            area_id: @area_id,
            channels: ["bell"]
          )
        end

        resources = bells_published.map { |p| p[:resource] }
        assert_includes resources, @user1
        assert_includes resources, @user2

        # Each publish call must have affected_users containing ONLY the single
        # recipient — never both recipients in one call (which would expose membership).
        bells_published.each do |p|
          assert_equal 1, p[:affected_users].size,
                       "Each publish call must target exactly one user"
          assert_equal p[:resource], p[:affected_users].first
          # Extra must not include a 'user_ids' or 'recipients' key.
          assert_nil p[:extra]["user_ids"]
          assert_nil p[:extra]["recipients"]
        end
      end

      # ─── Viber ───────────────────────────────────────────────────────────────

      test "broadcast content is resolved by ID and account intents are deduplicated" do
        area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "broadcast-test", name: { "sr" => "Centar" })
        broadcast = Broadcast.create!(organization: @organization, area:, message: "Viber poruka", channels: "bell,viber", recipients_count: 2)
        assert_difference "AccountNotification.count", 2 do
          stub_events_manager([]) do
            2.times do
              BroadcastNotificationJob.perform_now(organization_id: @organization.id,
                                                   user_ids: [@user1.id, @user2.id], broadcast_id: broadcast.id)
            end
          end
        end
        assert_equal [@user1.id, @user2.id].sort, AccountNotification.order(:decidim_user_id).pluck(:decidim_user_id)
        assert_equal ["neighborhood_info"], AccountNotification.distinct.pluck(:topic)
        assert_not_includes enqueued_jobs.inspect, "Viber poruka"
      end

      test "Viber is NOT enqueued when the viber channel is absent" do
        create_viber_linkage(@user1, "38765100002")

        stub_events_manager([]) do
          assert_no_enqueued_jobs(only: Decidim::Bih::AccountNotificationJob) do
            BroadcastNotificationJob.perform_now(
              organization_id: @organization.id,
              user_ids: [@user1.id],
              message: "Bell only",
              area_name: "Centar",
              area_id: @area_id,
              channels: ["bell"]
            )
          end
        end
      end

      test "legacy broadcast jobs lacking stable IDs cannot enqueue paid sends" do
        # Neither user1 nor user2 has a Viber linkage.
        stub_events_manager([]) do
          assert_no_enqueued_jobs(only: Decidim::Bih::AccountNotificationJob) do
            BroadcastNotificationJob.perform_now(
              organization_id: @organization.id,
              user_ids: [@user1.id, @user2.id],
              message: "No viber",
              area_name: "Centar",
              area_id: @area_id,
              channels: %w(bell viber)
            )
          end
        end
      end

      # ─── User filtering ──────────────────────────────────────────────────────

      test "blocked users are skipped" do
        @user1.update!(blocked: true)
        bells = []
        stub_events_manager(bells) do
          BroadcastNotificationJob.perform_now(
            organization_id: @organization.id,
            user_ids: [@user1.id, @user2.id],
            message: "Test",
            area_name: "X",
            area_id: @area_id,
            channels: ["bell"]
          )
        end

        assert_equal 1, bells.size
        assert_equal @user2.id, bells.first[:resource].id
      end

      test "deleted users are skipped" do
        @user1.update!(deleted_at: Time.current, email: "deleted-test@example.invalid")
        bells = []
        stub_events_manager(bells) do
          BroadcastNotificationJob.perform_now(
            organization_id: @organization.id,
            user_ids: [@user1.id, @user2.id],
            message: "Test",
            area_name: "X",
            area_id: @area_id,
            channels: ["bell"]
          )
        end

        assert_equal 1, bells.size
        assert_equal @user2.id, bells.first[:resource].id
      end

      test "no email is sent (email channel is out of scope this wave)" do
        # Assert that the ActionMailer delivery queue is untouched.
        bells = []
        stub_events_manager(bells) do
          BroadcastNotificationJob.perform_now(
            organization_id: @organization.id,
            user_ids: [@user1.id],
            message: "Email scope deferred",
            area_name: "Centar",
            area_id: @area_id,
            channels: %w(bell viber)
          )
        end

        mail_jobs = enqueued_jobs.select { |j| j["job_class"]&.include?("Mail") }
        assert_empty mail_jobs, "No mailer jobs must be enqueued — email is out of scope this wave"
      end

      private

      # Stubs Decidim::EventsManager.publish and captures calls into +container+.
      def stub_events_manager(container)
        stubbed_publish = lambda do |event:, event_class:, resource:, affected_users:, force_send:, extra:|
          container << {
            event:, event_class:, resource:, affected_users:, force_send:, extra:
          }
        end
        Decidim::EventsManager.stub(:publish, stubbed_publish) { yield }
      end

      def create_viber_linkage(user, sender)
        Decidim::Bih::Viber::Linkage.create!(
          organization: @organization,
          decidim_user_id: user.id,
          viber_sender: sender,
          phone: sender,
          verified_at: Time.current
        )
      end
    end
  end
end
