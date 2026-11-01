# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      module Read
        class BaseTest < ActiveSupport::TestCase
          Organization = Data.define(:id)
          Contracts = Decidim::Bih::Concierge::Dialogue::Contracts

          class Reader
            include Base

            def initialize(organization: nil)
              @organization = organization
            end

            public :authorized?, :not_authorized_result, :local_date, :local_day_bounds, :requested_day, :relative_day,
                   :fold, :result, :localize, :cyrillize, :clean_text
          end

          def context(organization_id: 7, capabilities: ["public_reads"])
            Contracts::TrustedContext.new(organization_id:, conversation_key: "a" * 64, capabilities:, now: Time.utc(2026, 9, 13, 12))
          end

          test "authorization needs the trusted context type, the capability and the tenant" do
            reader = Reader.new(organization: Organization.new(7))
            assert reader.authorized?(context)
            assert_not reader.authorized?(Object.new)
            assert_not reader.authorized?(context(capabilities: []))
            assert_not reader.authorized?(context(organization_id: 8))
            assert_not reader.authorized?(context, "own_report_reads")
            assert reader.authorized?(context(capabilities: ["own_report_reads"]), "own_report_reads")
            assert_equal({ status: "not_authorized", warnings: ["public_reads_not_allowed"] }, reader.not_authorized_result)
            assert_equal ["own_report_reads_not_allowed"], reader.not_authorized_result("own_report_reads")[:warnings]
          end

          test "a tenant-free reader checks the type and the capability only" do
            reader = Reader.new
            assert reader.authorized?(context(organization_id: 99))
            assert_not reader.authorized?(context(capabilities: []))
            assert_not reader.authorized?(Struct.new(:organization_id).new(99))
          end

          test "the local date and the day bounds follow Europe/Sarajevo across both DST switches" do
            reader = Reader.new
            # Spring forward: 2026-03-29 01:00 UTC (CET -> CEST).
            assert_equal Date.new(2026, 3, 29), reader.local_date(Time.utc(2026, 3, 28, 23, 30)) # 00:30 CET
            assert_equal Date.new(2026, 3, 29), reader.local_date(Time.utc(2026, 3, 29, 21, 59)) # 23:59 CEST
            assert_equal Date.new(2026, 3, 30), reader.local_date(Time.utc(2026, 3, 29, 22, 0)) # 00:00 CEST
            # Fall back: 2026-10-25 01:00 UTC (CEST -> CET).
            assert_equal Date.new(2026, 10, 25), reader.local_date(Time.utc(2026, 10, 24, 22, 0)) # 00:00 CEST
            assert_equal Date.new(2026, 10, 25), reader.local_date(Time.utc(2026, 10, 25, 22, 30)) # 23:30 CET, not the 26th
            assert_equal Date.new(2026, 10, 26), reader.local_date(Time.utc(2026, 10, 25, 23, 0)) # 00:00 CET

            starts, ends = reader.local_day_bounds(Date.new(2026, 3, 29))
            assert_equal Time.utc(2026, 3, 28, 23), starts
            assert_equal Time.utc(2026, 3, 29, 22), ends
            assert_equal 23 * 3600, ends - starts
            starts, ends = reader.local_day_bounds(Date.new(2026, 10, 25))
            assert_equal Time.utc(2026, 10, 24, 22), starts
            assert_equal Time.utc(2026, 10, 25, 23), ends
            assert_equal 25 * 3600, ends - starts
            starts, ends = reader.local_day_bounds(Date.new(2026, 9, 13))
            assert_equal 24 * 3600, ends - starts
          end

          test "requested day classifies the closed vocabulary against the local day" do
            reader = Reader.new
            now = Time.utc(2026, 10, 25, 22, 30) # 23:30 CET on the fall-back day
            today = Date.new(2026, 10, 25)
            %w(Danas sada trenutno today now currently).each do |word|
              parsed = reader.requested_day({ "time_expression" => word }, now:)
              assert_equal [today, :today], [parsed.day, parsed.kind], word
            end
            %w(sutra Tomorrow).each do |word|
              parsed = reader.requested_day({ "time_expression" => word }, now:)
              assert_equal [today.next_day, :tomorrow], [parsed.day, parsed.kind], word
            end
            %w(jučer juce yesterday).each do |word|
              parsed = reader.requested_day({ "time_expression" => word }, now:)
              assert_equal [today.prev_day, :yesterday], [parsed.day, parsed.kind], word
            end
            [{}, { "time_expression" => "" }, { "time_expression" => nil }, { "date" => "" }].each do |entities|
              parsed = reader.requested_day(entities, now:)
              assert_equal [nil, :none, ""], [parsed.day, parsed.kind, parsed.expression], entities.inspect
            end
            parsed = reader.requested_day({ "time_expression" => "Sljedeća dva vikenda" }, now:)
            assert_equal [nil, :unsupported, "sljedeca dva vikenda"], [parsed.day, parsed.kind, parsed.expression]
          end

          test "an explicit ISO date wins over the expression and a malformed one raises Date::Error" do
            reader = Reader.new
            now = Time.utc(2026, 9, 13, 12)
            parsed = reader.requested_day({ "date" => "2026-09-09", "time_expression" => "sutra" }, now:)
            assert_equal [Date.new(2026, 9, 9), :explicit, "2026-09-09"], [parsed.day, parsed.kind, parsed.expression]
            assert_raises(Date::Error) { reader.requested_day({ "date" => "2026-02-30" }, now:) }
            assert_raises(Date::Error) { reader.requested_day({ "date" => "sutra" }, now:) }
          end

          test "a reader may hand over its own pre-processed expression" do
            reader = Reader.new
            now = Time.utc(2026, 9, 13, 12)
            parsed = reader.requested_day({ "time_expression" => "za sutra" }, now:, expression: "sutra")
            assert_equal [Date.new(2026, 9, 14), :tomorrow], [parsed.day, parsed.kind]
            assert_equal :unsupported, reader.requested_day({ "time_expression" => "za sutra" }, now:).kind
            assert_equal :none, reader.relative_day("", today: Date.new(2026, 9, 13)).kind
            assert_equal Date.new(2026, 9, 12), reader.relative_day("juce", today: Date.new(2026, 9, 13)).day
          end

          test "fold, the envelope and the two script policies" do
            reader = Reader.new
            assert_equal "cistoca zelenilo", reader.fold("Čistoća & Zelenilo!")
            assert_equal "drina", reader.fold("Дрина")
            assert_equal "", reader.fold(nil)

            envelope = reader.result("ok", source: { "id" => "x" }, facts: (1..10).to_a, warnings: ["a", nil, "a", "b"])
            assert_equal [:status, :facts, :source, :checked_at, :coverage, :validity, :candidates, :warnings], envelope.keys
            assert_equal (1..8).to_a, envelope[:facts]
            assert_equal %w(a b), envelope[:warnings]
            assert_nil envelope[:checked_at]
            assert_nil envelope[:coverage]
            assert_equal [], envelope[:candidates]
            assert_equal({ "id" => "x" }, envelope[:source])

            assert_equal "Дрина", reader.localize("Drina", locale: "sr-Cyrl")
            assert_equal "Drina", reader.localize("Дрина", locale: "sr")
            assert_equal "Дрина", reader.cyrillize("Drina", locale: "sr-Cyrl")
            assert_equal "Дрина", reader.cyrillize("Дрина", locale: "sr")
            assert_equal "Drina", reader.cyrillize("Drina", locale: :bs)

            assert_equal "ab", reader.clean_text("<b>a</b>#{1.chr}b", limit: 10)
            assert_equal "abc", reader.clean_text("abcdef", limit: 3)
          end
        end
      end
    end
  end
end
