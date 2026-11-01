# frozen_string_literal: true

require "test_helper"
require "erb"
require "yaml"

module Decidim
  module Bih
    class JobQueueContractTest < ActiveSupport::TestCase
      test "custom jobs use named queues" do
        assert_equal "goodwill", Decidim::Bih::Goodwill::GoodwillAwardJob.queue_name
        assert_equal "goodwill", Decidim::Bih::Goodwill::ReferralRewardJob.queue_name
        assert_equal "integrations", Decidim::Bih::Odoo::RefreshDonationTotalsJob.queue_name
        assert_equal "integrations", Decidim::Bih::Infobip::SendSmsJob.queue_name
        assert_equal "integrations", Decidim::Bih::Infobip::SendViberBusinessTextJob.queue_name
        assert_equal "integrations", Decidim::Bih::Infobip::SendViberTextJob.queue_name
        assert_equal "integrations", Decidim::Bih::Infobip::SendViberImageJob.queue_name
        assert_equal "reports", Decidim::Bih::ReportProcessingJob.queue_name
      end

      # Phase 2 Task 2.7: authentication capacity is reserved. The ordered
      # phone-delivery job is the whole of sign-in and phone verification, and
      # it must not share a queue with optional traffic — a campaign or
      # city-alert backlog in `integrations` would otherwise sit in front of a
      # citizen's verification code.
      test "authentication work has a queue optional traffic does not share" do
        assert_equal "authentication_critical", Decidim::Bih::Infobip::SendPhoneMessageJob.queue_name
        assert_equal "integrations", Decidim::Bih::AccountNotificationJob.queue_name
        assert_not_equal Decidim::Bih::Infobip::SendPhoneMessageJob.queue_name,
                         Decidim::Bih::AccountNotificationJob.queue_name
      end

      # The literal in the job and the engine's priority mapping are two
      # statements of the same fact, so they are pinned to each other here
      # rather than left to drift.
      test "the reserved queue is the one Messaging::Priority names for authentication" do
        assert_equal Decidim::Bih::Messaging::Priority.queue_for_priority("authentication").to_s,
                     Decidim::Bih::Infobip::SendPhoneMessageJob.queue_name
        assert_equal Decidim::Bih::Messaging::Priority.queue_for_priority("routine").to_s,
                     Decidim::Bih::AccountNotificationJob.queue_name
      end

      test "sidekiq listens to queues used by custom jobs" do
        queues = sidekiq_queue_names

        assert_includes queues, "mailers"
        assert_includes queues, "goodwill"
        assert_includes queues, "integrations"
        assert_includes queues, "reports"
        assert_includes queues, "authentication_critical"
      end

      # A job that enqueues to a queue no worker consumes is invisible: the
      # enqueue succeeds, the work never runs and nothing raises. That is the
      # deploy hazard of moving a queue, so it is checked over EVERY engine job
      # rather than over a hand-maintained list.
      test "sidekiq listens to every queue an engine job enqueues to" do
        Rails.application.eager_load!
        engine_jobs = ActiveJob::Base.descendants.select { |job| job.name.to_s.start_with?("Decidim::Bih::") }
        # ActionMailer's delivery jobs compute their queue from a Proc, so it
        # cannot be read off the class. They are checked by name instead of
        # skipped, or a job could hide a bad queue behind a block.
        named, computed = engine_jobs.partition { |job| job.queue_name.is_a?(String) }

        assert_operator engine_jobs.size, :>=, 20, "eager loading did not reach the engine's jobs"
        assert_empty named.map(&:queue_name).uniq - sidekiq_queue_names,
                     "an engine job enqueues to a queue config/sidekiq.yml does not list"
        assert(computed.all? { |job| job <= ActionMailer::MailDeliveryJob },
               "a job computes its queue at runtime without being a mail delivery job")
        assert_includes sidekiq_queue_names, ActionMailer::Base.deliver_later_queue_name.to_s
      end

      # Weight, not just presence: the reservation is worthless if the reserved
      # queue is drained after the queue it was split away from.
      test "the reserved authentication queue outranks the optional-traffic queue" do
        weights = sidekiq_queues.to_h { |queue, weight| [queue, weight] }

        assert_operator weights.fetch("authentication_critical"), :>, weights.fetch("integrations")
      end

      test "Infobip delivery jobs do not log sensitive arguments" do
        assert_not Decidim::Bih::Infobip::SendSmsJob.log_arguments?
        assert_not Decidim::Bih::Infobip::SendPhoneMessageJob.log_arguments?
        assert_not Decidim::Bih::Infobip::SendViberBusinessTextJob.log_arguments?
        assert_not Decidim::Bih::Infobip::SendViberTextJob.log_arguments?
        assert_not Decidim::Bih::Infobip::SendViberImageJob.log_arguments?
      end

      # 2026-10-21: a restart cut a case-agent call off and stranded the
      # proposal. The restart contract is three numbers in three files; they
      # are pinned to each other here (see the comment in config/sidekiq.yml).
      test "sidekiq shutdown timeout covers in-flight delivery" do
        timeout = sidekiq_config.fetch(:timeout)
        mailbox = { "host" => "imap.example.org", "port" => 993, "tls" => true, "username" => "reports@example.org", "password" => "x" }
        smtp = Decidim::Bih::ReportMailbox::Config.new(mailbox).smtp_settings

        assert_operator timeout, :>=, smtp.fetch(:read_timeout), "report mail SMTP send would be cut off"
        assert_operator timeout, :>=, 2 * Decidim::Bih::Infobip::Client::DEFAULT_TIMEOUT, "Infobip phone chain would be cut off"
      end

      # GeminiClient applies the call timeout to connect and to read; a live
      # lease goes untouched across two calls (repair + check).
      test "an interrupted case-agent lease turns stale only after any live lease would have finished" do
        agent = Decidim::Bih::Ai::CaseAgent
        worst_call = agent::CALL_TIMEOUT + agent::CALL_TIMEOUT

        assert_operator agent::STALE_LEASE, :>, (2 * worst_call).seconds
        assert_operator Decidim::Bih::ReportReviewProposalRecovery::WINDOW, :>, agent::STALE_LEASE
      end

      # After TSTP a quiet case agent still finishes its call in flight; a
      # release drain shorter than that aborts every release that meets one.

      # The real engine initializer, run as the Sidekiq server runs it.
      test "the engine raises the worker shutdown flag on Sidekiq's quiet event" do
        quiet = Sidekiq.default_configuration[:lifecycle_events][:quiet]
        before = quiet.dup
        initializer = Rails.application.initializers.find { |candidate| candidate.name == "decidim_bih.worker_shutdown" }
        Sidekiq.stub(:server?, true) { initializer.run(Rails.application) }

        added = quiet - before
        assert_equal 1, added.size
        assert_not_predicate Decidim::Bih::WorkerShutdown, :requested?
        added.each(&:call)
        assert_predicate Decidim::Bih::WorkerShutdown, :requested?
      ensure
        quiet&.replace(before) if before
        Decidim::Bih::WorkerShutdown.reset!
      end

      private


      def sidekiq_queue_names
        sidekiq_queues.map(&:first)
      end

      def sidekiq_queues
        sidekiq_config.fetch(:queues)
      end

      def sidekiq_config
        YAML.safe_load(
          ERB.new(Rails.root.join("config/sidekiq.yml").read).result,
          permitted_classes: [Symbol],
          aliases: true
        )
      end
    end
  end
end
