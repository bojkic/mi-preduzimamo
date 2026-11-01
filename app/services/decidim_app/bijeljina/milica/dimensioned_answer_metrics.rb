# frozen_string_literal: true

require "json"

module DecidimApp
  module Bijeljina
    module Milica
      # Tenant-partitioned, bounded answer-boundary counts. A Redis hash per UTC
      # hour avoids enumerating the Cartesian product of optional dimensions.
      # It contains closed tokens/counts only, no messages or citizen identity.
      module DimensionedAnswerMetrics
        RETENTION = 48.hours
        MAX_FIELDS = 20_000
        INCREMENT = <<~LUA
          if redis.call('HEXISTS', KEYS[1], ARGV[1]) == 0 and redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[3]) then
            return 0
          end
          redis.call('HINCRBY', KEYS[1], ARGV[1], 1)
          redis.call('EXPIRE', KEYS[1], ARGV[2])
          return 1
        LUA

        module_function

        # Configured once at process boot. A later checkout change must not
        # restamp answers produced by a process that still runs older code.
        def configure(release_sha:, prompt_version:)
          @release_sha = release_sha if release_sha.nil? || release_sha.match?(model::RELEASE_SHA_FORMAT)
          @prompt_version = prompt_version if prompt_version.is_a?(Integer) && prompt_version.positive?
        end

        def record(organization_id:, topic:, outcome:, facet:, now: Time.current)
          return unless valid_organization?(organization_id)

          dimensions = { topic:, label: outcome, facet:, traffic_kind:, release_sha: @release_sha, prompt_version: @prompt_version }
          return unless valid_dimensions?(dimensions)

          field = JSON.generate(dimensions.values)
          with_redis { |redis| redis.eval(INCREMENT, keys: [cache_key(organization_id, now)], argv: [field, RETENTION.to_i, MAX_FIELDS]) }
        rescue StandardError
          # Observation failures cannot change answers or trigger a retry.
          nil
        end

        # Explicitly trusted process configuration. Absence is unclassified,
        # never "citizen"; request parameters/headers cannot set provenance.
        def traffic_kind
          ENV["MILICA_METRICS_TRAFFIC_KIND"] == "synthetic" ? "synthetic" : "unclassified"
        end

        def snapshot(organization_id:, now: Time.current, hours: 24)
          raise ArgumentError, "invalid organization or hours" unless valid_organization?(organization_id) && (1..48).cover?(hours)

          totals = Hash.new(0)
          with_redis do |redis|
            hours.times do |offset|
              redis.hgetall(cache_key(organization_id, now - offset.hours)).each do |field, count|
                dimensions = decode(field)
                next unless dimensions && count.to_s.match?(/\A[1-9]\d*\z/)

                totals[dimensions] += count.to_i
              end
            end
          end
          totals.map { |dimensions, count| dimensions.merge(count:) }
        end

        def decode(field)
          values = JSON.parse(field)
          return unless values.is_a?(Array) && values.length == 6

          dimensions = [:topic, :label, :facet, :traffic_kind, :release_sha, :prompt_version].zip(values).to_h
          dimensions if valid_dimensions?(dimensions)
        rescue JSON::ParserError
          nil
        end

        def valid_dimensions?(row)
          model.topics_for("answer_detail").include?(row[:topic]) && model.labels_for("answer_detail").include?(row[:label]) &&
            model::FACETS.include?(row[:facet]) && model::TRAFFIC_KINDS.include?(row[:traffic_kind]) &&
            valid_release?(row[:release_sha]) &&
            (row[:prompt_version].nil? || (row[:prompt_version].is_a?(Integer) && row[:prompt_version].positive?))
        end

        def valid_release?(value)
          value.nil? || (value.is_a?(String) && value.match?(model::RELEASE_SHA_FORMAT))
        end

        def valid_organization?(value) = value.is_a?(Integer) && value.positive?

        def model = Decidim::Bih::ConciergeMetricRollup

        def cache_key(organization_id, time)
          # Direct Redis hashes must retain the Rails cache namespace, including
          # isolated test/host namespaces, rather than bypassing that boundary.
          namespace = Rails.cache.options[:namespace] if Rails.cache.respond_to?(:options)
          namespace = namespace.call if namespace.respond_to?(:call)
          [namespace, "milica/answer-dimensions/v1/#{organization_id}/#{time.getutc.strftime("%Y%m%d%H")}"].compact.join(":")
        end

        def with_redis(&)
          # The deployed cache exposes a pool; accepting a direct connection
          # keeps adapters/test fakes usable without global Redis access.
          connection = Rails.cache.redis
          connection.respond_to?(:with) ? connection.with(&) : yield(connection)
        end
      end
    end
  end
end
