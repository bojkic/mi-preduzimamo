# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Privacy
      # Every retention bucket must be wired at EVERY hop, or it registers but
      # never acts — the defect class where a bucket is displayed and never
      # deleted, or deleted and never displayed.
      #
      # Most hops now derive from PrivacyAuditContracts. The sweep service and
      # its job cannot: their cutoffs are Ruby keyword arguments. These tests
      # are the guard for the hops that must stay hand-written, so adding a
      # bucket to the contracts without wiring the service fails loudly here
      # instead of silently doing nothing in production.
      class RetentionBucketWiringTest < ActiveSupport::TestCase
        Contracts = Decidim::Bih::PrivacyAuditContracts

        test "sweep buckets are exactly those declaring a service cutoff key" do
          declared = Contracts.retention_buckets.select { |b| b[:service_cutoff_key].present? }

          assert_equal(declared.map { |b| b.fetch(:id) }, Contracts.sweep_buckets.map { |b| b.fetch(:id) })
          assert_predicate Contracts.sweep_buckets, :any?
        end

        test "RetentionSweep accepts every declared cutoff keyword" do
          accepted = Decidim::Bih::Privacy::RetentionSweep.instance_method(:initialize)
                                                          .parameters
                                                          .filter_map { |type, name| name if [:key, :keyreq].include?(type) }

          missing = Contracts.sweep_cutoff_keys - accepted
          assert_empty missing,
                       "RetentionSweep#initialize is missing cutoff keywords: #{missing.join(", ")}"
        end

        test "RetentionSweepJob forwards every declared cutoff keyword" do
          accepted = Decidim::Bih::Privacy::RetentionSweepJob.instance_method(:perform)
                                                             .parameters
                                                             .filter_map { |type, name| name if [:key, :keyreq].include?(type) }

          missing = Contracts.sweep_cutoff_keys - accepted
          assert_empty missing,
                       "RetentionSweepJob#perform is missing cutoff keywords: #{missing.join(", ")}"
        end

        test "the admin dashboard covers every sweep bucket" do
          assert_equal Contracts.sweep_bucket_ids,
                       Decidim::Bih::Admin::RetentionSummary::COUNT_KEYS
          assert_equal Contracts.sweep_bucket_ids.sort,
                       Decidim::Bih::Admin::RetentionSummary::CUTOFF_KEYS.keys.sort
        end

        test "every sweep bucket has a translated dashboard label" do
          missing = Contracts.sweep_bucket_ids.reject do |id|
            I18n.exists?("decidim.bih.admin.privacy_retention.buckets.#{id}", :sr)
          end

          assert_empty missing, "Missing sr labels for buckets: #{missing.join(", ")}"
        end

        test "scheduled report-only wrapper supplies every declared cutoff" do
          wrapper = Rails.root.join("bin/privacy-retention-sweep.sh").read
          Contracts.sweep_env_cutoffs.each_key do |key|
            assert_includes wrapper, "#{key}=", "Missing scheduled cutoff #{key}"
          end
          assert_includes wrapper, "script/lib/mi_retention_status.rb"
        end

        test "a sweep actually counts every declared bucket" do
          organization = create_organization
          # Delivery evidence requires a cutoff at least 90 days old.
          cutoffs = Contracts.sweep_cutoff_keys.index_with { 91.days.ago }

          result = Decidim::Bih::Privacy::RetentionSweep.call(
            **cutoffs, organization:, dry_run: true
          )

          missing = Contracts.sweep_bucket_ids - result.counts.keys
          assert_empty missing, "Sweep produced no count for buckets: #{missing.join(", ")}"
        end
      end
    end
  end
end
