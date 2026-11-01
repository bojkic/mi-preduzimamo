# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_procedures"

module DecidimApp
  module Bijeljina
    module Milica
      class ProcedureReadTest < ActiveSupport::TestCase
        include SyntheticProcedures
        setup { install_synthetic_procedures }
        teardown { restore_synthetic_procedures }

        test "registry fee stays unknown and statutory deadline is not a completion promise" do
          store = Object.new
          store.define_singleton_method(:snapshot) { |**| nil }
          card = ServiceProcedures.find("TEST_4")
          result = ProcedureRead.new(source_store: store).call(card:, locale: "sr", now: Time.utc(2040, 9, 15))
          row = result.fetch(:facts).first
          assert_nil row.fetch("fee")
          assert_equal "ТЕСТ_4", row.fetch("provider_procedure_code")
          assert_includes row.fetch("text"), "Taksa nije navedena"
          assert_not_includes row.fetch("text"), "besplatno"
          assert_equal false, row.fetch("processing_time").fetch(:guaranteed_completion)
          assert_equal "not_verified", row.fetch("current_legal_status")
        end

        test "changed official content cannot carry a previous procedure approval" do
          store = Object.new
          store.define_singleton_method(:snapshot) { |**| Struct.new(:check_payload).new({ "status" => "unreviewed" }) }
          result = ProcedureRead.new(source_store: store).call(card: ServiceProcedures.find(:maticar), locale: "sr", now: Time.utc(2040, 9, 9))
          assert_equal "unreviewed", result[:status]
          assert_empty result.fetch(:facts, [])
          assert_includes result[:warnings], "procedure_source_changed_review_required"
        end

        test "reviewed instructions leave unknown processing time unknown and keep identifiers on the official form" do
          store = Object.new
          store.define_singleton_method(:snapshot) { |**| nil }
          result = ProcedureRead.new(source_store: store).call(card: ServiceProcedures.find(:pracenje_predmeta), locale: "sr", now: Time.utc(2040, 9, 9))
          assert_equal "ok", result[:status]
          assert_nil result[:facts].first.fetch("processing_time")
          assert_includes result[:facts].first.fetch("text"), "samo u službeni obrazac"
        end
        def read_card(card: ServiceProcedures.find("maticar"), now: Time.utc(2040, 9, 9, 12), payload: nil, locale: "sr")
          @read_keys = []
          keys = @read_keys
          store = Object.new
          store.define_singleton_method(:snapshot) do |source_key:|
            keys << source_key
            payload && Struct.new(:check_payload).new(payload)
          end
          ProcedureRead.new(source_store: store).call(card:, locale:, now:)
        end

        test "zero administrative fee does not imply postage without an explicit delivery cost" do
          original = ServiceProcedures.find("maticar")
          [nil, "none", "unknown"].each do |cost|
            card = original.merge(fee: { administrative_fee_bam: 0, delivery_cost: cost, postage_amount_bam: nil })
            result = read_card(card:)
            assert_equal "ok", result.fetch(:status)
            assert_includes result.fetch(:facts).first.fetch("text"), "Administrativna taksa: 0 KM"
            assert_not_includes result.fetch(:facts).first.fetch("text"), "poštarina se plaća"
            assert_not_includes result.fetch(:facts).first.fetch("text"), "Poštarina:"
          end
        end

        test "explicit postal cost is independent from fee and unknown postage is never zero" do
          result = read_card
          fact = result.fetch(:facts).first
          assert_includes fact.fetch("text"), "Iznos poštarine nije potvrđen"
          assert_not_includes fact.fetch("text"), "Poštarina: 0"
          card = ServiceProcedures.find("maticar").merge(fee: { administrative_fee_bam: 4, delivery_cost: "postage", postage_amount_bam: 2.5 })
          fact = read_card(card:).fetch(:facts).first
          assert_includes fact.fetch("text"), "Administrativna taksa: 4 KM"
          assert_includes fact.fetch("text"), "Poštarina: 2.5 KM"
          assert_not_includes fact.fetch("text"), "6.5 KM"
        end

        test "invalid monetary amounts remain unknown in structured facts" do
          original = ServiceProcedures.find("maticar")
          [-1, "0", Float::INFINITY].each do |value|
            card = original.merge(fee: { administrative_fee_bam: value, delivery_cost: "postage", postage_amount_bam: value })
            fact = read_card(card:).fetch(:facts).first
            assert_nil fact.fetch("fee").fetch(:administrative_fee_bam)
            assert_nil fact.fetch("fee").fetch(:postage_amount_bam)
            assert_not_includes fact.fetch("text"), "Administrativna taksa: 0"
            assert_includes fact.fetch("text"), "Iznos poštarine nije potvrđen"
          end
        end

        test "unreviewed and revoked cards do not read source snapshots" do
          %w(pending unreviewed revoked).each do |state|
            result = read_card(card: ServiceProcedures.find("maticar").merge(review_status: state))
            assert_equal "unreviewed", result.fetch(:status)
            assert_empty result.fetch(:facts, [])
            assert_empty @read_keys
          end
        end

        test "effective procedure bounds are inclusive and do not replace review freshness" do
          original = ServiceProcedures.find("maticar")
          [{ effective_from: "2040-09-10" }, { effective_until: "2040-09-08" }].each do |changes|
            result = read_card(card: original.merge(changes))
            assert_equal "stale", result.fetch(:status)
            assert_empty result.fetch(:facts, [])
            assert_includes result.fetch(:warnings), "procedure_not_effective_on_requested_day"
          end
          card = original.merge(effective_from: "2040-09-09", effective_until: "2040-09-09")
          assert_equal "ok", read_card(card:).fetch(:status)
          assert_equal "stale", read_card(card: original, now: Time.utc(2041, 9, 10, 12)).fetch(:status)
        end

        test "invalid reversed or incomplete procedure records fail without exposing their data" do
          original = ServiceProcedures.find("maticar")
          [original.merge(effective_from: "2040-09-10", effective_until: "2040-09-09"),
           original.merge(source_checked_on: "2040-02-30"), original.merge(reviewed_content_hash: "unverified"),
           original.merge(record_kind: "personal_record"), original.merge(steps: ["bad\u0000text"]), nil].each do |card|
            result = read_card(card:)
            assert_equal "unavailable", result.fetch(:status)
            assert_empty result.fetch(:facts, [])
            assert_empty @read_keys
          end
        end

        test "only reviewed https origins can appear in procedure and download citations" do
          original = ServiceProcedures.find("maticar")
          ["http://community.example.invalid/procedure", "https://user:password@community.example.invalid/procedure",
           "https://community.example.invalid:444/procedure", "https://other.example.invalid/procedure"].each do |url|
            %i(source_url form_download_url).each do |field|
              result = read_card(card: original.merge(field => url))
              assert_equal "unavailable", result.fetch(:status)
              assert_empty result.fetch(:facts, [])
              assert_empty @read_keys
              assert_not_includes result.to_s, "password"
            end
          end
        end

        test "a source-change review barrier survives a later failed check" do
          card = ServiceProcedures.find("maticar")
          result = read_card(card:, payload: { "status" => "unavailable", "review_required_for_hash" => card.fetch(:reviewed_content_hash), "source_url" => card.fetch(:source_url) })
          assert_equal "unreviewed", result.fetch(:status)
          assert_empty result.fetch(:facts, [])
          assert_includes result.fetch(:warnings), "procedure_source_changed_review_required"
          restored = read_card(card:, payload: { "status" => "ok" })
          assert_equal "ok", restored.fetch(:status)
        end

        test "review dates use the Sarajevo day and Cyrillic keeps source urls unchanged" do
          card = ServiceProcedures.find("maticar").merge(source_checked_on: "2040-09-10")
          assert_equal "ok", read_card(card:, now: Time.utc(2040, 9, 9, 22, 30)).fetch(:status)
          assert_equal "stale", read_card(card:, now: Time.utc(2040, 9, 9, 20)).fetch(:status)
          fact = read_card(locale: "sr-Cyrl").fetch(:facts).first
          assert_match(/\p{Cyrillic}/, fact.fetch("text"))
          assert_equal ServiceProcedures.find("maticar").fetch(:source_url), fact.fetch("source_url")
        end

        test "malformed channel delivery exemptions and document metadata are not readable facts" do
          original = ServiceProcedures.find("maticar")
          [{ channel: "private" }, { document_kind: "not a type" }, { organization_host: "https://other.example.invalid/" },
           { delivery: { document_method: "unknown-provider-mode" } }, { delivery: { instructions_method: "sms" } },
           { delivery: { delivery_guaranteed: true } }, { fee_exemptions: "bad\u0000text" },
           { required_documents: "not a reviewed list" }, { processing_time: { text: "bad\u0000text" } }].each do |changes|
            result = read_card(card: original.merge(changes))
            assert_equal "unavailable", result.fetch(:status)
            assert_empty result.fetch(:facts, [])
            assert_empty @read_keys
          end
        end

        test "generic procedure does not acquire birth channel or delivery metadata by default" do
          card = ServiceProcedures.find("e_registar")
          result = read_card(card:)
          assert_equal "ok", result.fetch(:status)
          fact = result.fetch(:facts).first
          assert_nil fact.fetch("channel")
          assert_nil fact.fetch("document_kind")
          assert_nil fact.fetch("delivery")
          assert_nil fact.fetch("fee_exemptions")
        end

        test "structured steps channel and delivery remain distinct when prose needs truncation" do
          original = ServiceProcedures.find("maticar")
          steps = ["Prvi autorski korak: " + "a" * 700, "Drugi autorski korak: " + "b" * 700]
          card = original.merge(steps:, fee_exemptions: "Izmišljeno pravilo samo online kanala.")
          result = read_card(card:)
          fact = result.fetch(:facts).first
          assert_equal steps, fact.fetch("steps")
          assert_equal "online", fact.fetch("channel")
          assert_equal "birth_extract", fact.fetch("document_kind")
          assert_equal "postal", fact.fetch("delivery").fetch(:document_method)
          assert_equal "email", fact.fetch("delivery").fetch(:instructions_method)
          assert_equal card.fetch(:fee_exemptions), fact.fetch("fee_exemptions")
          assert_includes result.fetch(:warnings), "procedure_text_truncated_use_structured_steps"
          assert_operator fact.fetch("text").length, :<=, 1_000
        end

      end
    end
  end
end
