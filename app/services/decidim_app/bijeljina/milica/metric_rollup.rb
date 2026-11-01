# frozen_string_literal: true

require "open3"

module DecidimApp
  module Bijeljina
    module Milica
      # Rolls the 48-hour Redis counters (AnswerMetrics, ReadMetrics and the
      # understanding/rendering stage timings) into
      # Decidim::Bih::ConciergeMetricRollup rows for yesterday and today in the
      # application time zone (Europe/Sarajevo).
      #
      # Idempotent by construction: every bucket is written with the count the
      # snapshot reports (never incremented or decreased), and a zero count is never written,
      # so a late run that meets expired keys cannot erase a day already stored.
      # Aggregate-only: the snapshots carry no identity, text, channel or
      # location dimension, and neither do the rows.
      class MetricRollup
        Result = Struct.new(:days, :written, :release_sha, :prompt_version, keyword_init: true)

        MAX_SNAPSHOT_HOURS = 48

        # The host checkout's HEAD, or nil when git or the repository is absent.
        def self.release_sha(root: Rails.root)
          output, status = Open3.capture2("git", "-C", root.to_s, "rev-parse", "HEAD", err: File::NULL)
          sha = output.to_s.strip
          status.success? && sha.match?(Decidim::Bih::ConciergeMetricRollup::RELEASE_SHA_FORMAT) ? sha : nil
        rescue SystemCallError
          nil
        end

        def initialize(organization:, now: Time.current, release_sha: self.class.release_sha,
                       prompt_version: Decidim::Bih::Concierge::Dialogue::Contracts::VERSION)
          @organization = organization
          @now = now.in_time_zone
          @release_sha = release_sha
          @prompt_version = prompt_version
        end

        attr_reader :organization, :now, :release_sha, :prompt_version

        def days
          today = now.to_date
          [today - 1, today]
        end

        def call
          written = days.sum do |day|
            snapshot_now, hours = window_for(day)
            write_answers(day, AnswerMetrics.snapshot(now: snapshot_now, hours:)) +
              write_reads(day, ReadMetrics.snapshot(now: snapshot_now, hours:)) +
              write_stages(day, ReadMetrics.stage_snapshot(now: snapshot_now, hours:)) +
              write_dimensions(day, snapshot_now:, hours:)
          end
          Result.new(days:, written:, release_sha:, prompt_version:)
        end

        private

        # The snapshot sums the hour buckets ending at +snapshot_now+; for a
        # finished day that is its last second and every local hour (23, 24 or
        # 25 on a DST day), for today it is now and the hours elapsed so far.
        def window_for(day)
          start = day.in_time_zone
          day_end = start + 1.day - 1.second
          snapshot_now = [day_end, now].min
          hours = ((snapshot_now - start) / 1.hour).floor + 1
          [snapshot_now, hours.clamp(1, MAX_SNAPSHOT_HOURS)]
        end

        def write_answers(day, snapshot)
          snapshot.fetch(:rows).sum do |row|
            row.fetch(:outcomes).count do |outcome, count|
              store_bucket(count, day:, kind: "answer", topic: row.fetch(:topic), label: outcome, latency_bucket: nil)
            end
          end
        end

        def write_reads(day, snapshot)
          snapshot.sum do |topic, statuses|
            statuses.sum do |status, buckets|
              buckets.count { |bucket, count| store_bucket(count, day:, kind: "read", topic:, label: status, latency_bucket: bucket) }
            end
          end
        end

        def write_dimensions(day, snapshot_now:, hours:)
          rows = DimensionedAnswerMetrics.snapshot(organization_id: organization.id, now: snapshot_now, hours:)
          rows.count do |attributes|
            store_snapshot(attributes.merge(day:, kind: "answer_detail", latency_bucket: nil), detail: true)
          end
        rescue NoMethodError => e
          # MemoryStore/NullStore have no Redis hashes. Keep legacy rollups
          # functional and leave the new cohort absent rather than invent zero.
          raise unless e.name == :redis

          0
        end

        def write_stages(day, snapshot)
          snapshot.sum do |stage, statuses|
            statuses.sum do |status, buckets|
              buckets.count { |bucket, count| store_bucket(count, day:, kind: "stage", topic: stage, label: status, latency_bucket: bucket) }
            end
          end
        end

        # Writes the bucket identified by +key+ (day, kind, topic, label,
        # latency_bucket) with the snapshot count, through model validations.
        # Returns false for a zero count, which is never stored.
        def store_bucket(count, key)
          return false unless count.to_i.positive?

          store_snapshot(key.merge(count: count.to_i, release_sha:, prompt_version:), detail: false)
        end

        # Validation keeps bounded vocabularies; PostgreSQL arbitrates the
        # complete bucket identity atomically. Ruby read/max/save can lose a
        # larger concurrent snapshot or race the first insert. Do not increment:
        # snapshots are cumulative and the same run can be retried safely.
        def store_snapshot(attributes, detail:)
          return false unless attributes.fetch(:count).to_i.positive?

          model = Decidim::Bih::ConciergeMetricRollup
          row = model.new(organization:, **attributes)
          row.validate!
          index = detail ? :idx_bih_concierge_metric_detail_unique : :idx_bih_concierge_metric_rollups_unique
          updates = '"count" = GREATEST("decidim_bih_concierge_metric_rollups"."count", EXCLUDED."count"), "updated_at" = EXCLUDED."updated_at"'
          updates += ', "release_sha" = EXCLUDED."release_sha", "prompt_version" = EXCLUDED."prompt_version"' unless detail
          # The row above has already passed the model's complete validations.
          model.upsert(row.attributes.except("id", "created_at", "updated_at"), unique_by: index, on_duplicate: Arel.sql(updates), returning: false) # rubocop:disable Rails/SkipsModelValidations
          true
        end
      end
    end
  end
end
