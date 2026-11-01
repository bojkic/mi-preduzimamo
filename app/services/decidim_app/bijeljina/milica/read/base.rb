# frozen_string_literal: true

require "date"

module DecidimApp
  module Bijeljina
    module Milica
      module Read
        # The helpers every typed public reader shares, written once: the
        # authorization guard, the Europe/Sarajevo day arithmetic, the text
        # fold, the result envelope and the reply-script (sr-Cyrl) policy. A
        # reader keeps its own topic policy on top; nothing here reaches a
        # network, a model or a database. Mixed in with `include` (class
        # readers) or `extend` (module readers such as WaterLevelAnswer).
        module Base
          TIME_ZONE = "Europe/Sarajevo"
          MAX_FACTS = 8
          TODAY_EXPRESSIONS = %w(danas sada trenutno today now currently).freeze
          TOMORROW_EXPRESSIONS = %w(sutra tomorrow).freeze
          YESTERDAY_EXPRESSIONS = %w(juce jucer yesterday).freeze

          # `kind` is :explicit (an ISO `date` entity), :today / :tomorrow /
          # :yesterday (the closed relative vocabulary), :none (no expression)
          # or :unsupported (anything else; `day` is nil and `expression` keeps
          # the folded text for the reader's own fallback).
          RequestedDay = Data.define(:day, :kind, :expression)

          private

          # Trusted-context type, capability and tenant, in that order. A reader
          # without an @organization is tenant-free and skips the tenant check.
          def authorized?(context, capability = "public_reads")
            trusted_context?(context) && context.allows?(capability) && tenant_matches?(context)
          end

          def trusted_context?(context)
            context.is_a?(Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext)
          end

          def tenant_matches?(context)
            organization = tenant_organization
            organization.nil? || context.organization_id == organization.id
          end

          def tenant_organization
            @organization
          end

          # The minimal refusal the plain-hash readers return; envelope readers
          # pass the status through their own `result` instead.
          def not_authorized_result(capability = "public_reads")
            { status: "not_authorized", warnings: ["#{capability}_not_allowed"] }
          end

          def local_date(time, zone: TIME_ZONE)
            time.in_time_zone(zone).to_date
          end

          # Local midnight of `date` and of the following day, DST-correct
          # (a 23- or 25-hour day on the switch dates).
          def local_day_bounds(date, zone: TIME_ZONE)
            time_zone = ActiveSupport::TimeZone[zone]
            next_day = date.next_day
            [time_zone.local(date.year, date.month, date.day), time_zone.local(next_day.year, next_day.month, next_day.day)]
          end

          # An explicit ISO `date` entity wins (Date::Error propagates to the
          # reader's own rescue); otherwise the folded `time_expression`, or the
          # `expression:` a reader has already pre-processed, is classified.
          def requested_day(entities, now:, zone: TIME_ZONE, expression: nil)
            return RequestedDay.new(day: Date.iso8601(entities["date"]), kind: :explicit, expression: entities["date"]) if entities["date"].present?

            relative_day(expression || fold(entities["time_expression"]), today: local_date(now, zone:))
          end

          def relative_day(expression, today:)
            expression = expression.to_s
            return RequestedDay.new(day: nil, kind: :none, expression:) if expression.empty?
            return RequestedDay.new(day: today, kind: :today, expression:) if TODAY_EXPRESSIONS.include?(expression)
            return RequestedDay.new(day: today.next_day, kind: :tomorrow, expression:) if TOMORROW_EXPRESSIONS.include?(expression)
            return RequestedDay.new(day: today.prev_day, kind: :yesterday, expression:) if YESTERDAY_EXPRESSIONS.include?(expression)

            RequestedDay.new(day: nil, kind: :unsupported, expression:)
          end

          def fold(text)
            Decidim::Bih::Text.fold(text.to_s)
          end

          # The read-port envelope as a mutable hash (ReadPort#result rebuilds it
          # as a typed ReadResult and normalises warnings once more). Facts are
          # capped here exactly as ReadPort caps them.
          def result(status, source:, facts: [], checked_at: nil, coverage: nil, validity: nil, candidates: [], warnings: []) # rubocop:disable Metrics/ParameterLists
            { status:, facts: facts.first(MAX_FACTS), source:, checked_at:, coverage:, validity:, candidates:, warnings: warnings.compact.uniq }
          end

          # Reply script: Cyrillic under sr-Cyrl, Latin under every other locale.
          def localize(text, locale:)
            Decidim::Bih::Transliterator.localize(text, locale: locale.to_s)
          end

          # Prepared-source text keeps its stored script under Latin locales;
          # only sr-Cyrl transliterates (SourceRead, ReferenceRead).
          def cyrillize(text, locale:)
            locale.to_s == "sr-Cyrl" ? Decidim::Bih::Transliterator.call(text) : text
          end

          # Tags and control characters out, then the reader's own length cap.
          def clean_text(value, limit:)
            ActionController::Base.helpers.strip_tags(value.to_s).gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f]/, "")[0, limit]
          end
        end
      end
    end
  end
end
