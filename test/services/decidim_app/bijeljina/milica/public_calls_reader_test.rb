# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_event_source_registry"
require_relative "../../../../support/synthetic_public_call_snapshot"

module DecidimApp
  module Bijeljina
    module Milica
      class PublicCallsReaderTest < ActiveSupport::TestCase
        include SyntheticEventSourceRegistry
        include SyntheticPublicCallSnapshot
        URL = "https://www.gradbijeljina.org/lat/news/obavjestenja/900001.izmisljeni-poziv.html"
        LISTING_URL = "https://www.gradbijeljina.org/lat/news/obavjestenja/"
        Row = Struct.new(:source_version, :check_payload, keyword_init: true)
        class Store
          attr_reader :row, :source_key

          def version_for(*) = "parent-source-v1"

          def snapshot(**) = @row

          def promote(source_key:, source_version:, payload:, **)
            @source_key = source_key
            @row = Row.new(source_version:, check_payload: payload)
          end
        end

        setup do
          travel_to Time.utc(2040, 9, 9, 12)
          # Discovery is a reference adapter for this fixed host/path grammar;
          # article content and local alias evidence remain authored test data.
          rows = CityServiceSources::SOURCES.map do |row|
            row[:key] == PublicCallsPreparation::PARENT_SOURCE_KEY ? row.merge(source_url: LISTING_URL) : row
          end
          CityServiceSources.send(:remove_const, :SOURCES)
          CityServiceSources.const_set(:SOURCES, rows.freeze)
          @organization = create_organization
          @store = Store.new
          @reader = PublicCallsReader.new(organization: @organization, source_checker: @store)
          @html = Rails.root.join("test/fixtures/files/synthetic/public_call.html").read
        end

        teardown { travel_back }

        test "authored source shape keeps publication distinct from explicit application window and form provenance" do
          prepared = prepare
          assert_equal "ok", prepared["status"]
          assert_equal "public_calls:#{@organization.id}", @store.source_key
          item = prepared.fetch("items").first
          assert_equal "2040-09-04", item["source_published_on"]
          assert_equal "2040-09-03", item["opens_on"]
          assert_equal "2040-10-02", item["closes_on"]
          assert_equal "bounded_window", item["temporal_status"]
          assert_equal false, item["eligibility_complete"]
          assert_equal "https://www.gradbijeljina.org/UcitaneSlike/admin/Dokumenti/izmisljeni-obrazac.docx", item["attachments"].first["url"]
          result = read
          assert_equal "ok", result[:status]
          assert_equal "within_explicit_application_window", result[:facts].first["active_status"]
          assert_equal URL, result[:facts].first["source_url"]
        end

        test "default HTTP fetch returns the streamed article rather than the response object" do
          response = Net::HTTPOK.new("1.1", "200", "OK")
          response["content-type"] = "text/html; charset=utf-8"
          html = @html
          response.define_singleton_method(:read_body) { |&block| block.call(html) }
          http = Object.new
          http.define_singleton_method(:request) do |_request, &block|
            block.call(response)
            response # Net::HTTP ignores the response block's return value.
          end
          start = ->(*, **, &block) { block.call(http) }
          policy = Object.new
          policy.define_singleton_method(:before_request) { |_uri, timeout:| timeout }
          policy.define_singleton_method(:observe_response) { |_uri, _response| nil }
          CitySourceRequestPolicy.stub(:default, policy) do
            Net::HTTP.stub(:start, start) do
              prepared = PublicCallsPreparation.new(organization: @organization, source_store: @store)
                                               .call(html: listing, source_url: LISTING_URL, fetched_at: Time.current)
              assert_equal "ok", prepared["status"]
              assert_equal URL, prepared.fetch("items").first.fetch("source_url")
              assert_equal "2040-10-02", prepared.fetch("items").first.fetch("closes_on")
            end
          end
        end

        test "sidebar unrelated dates and attachment links never become application evidence" do
          @html += "<aside><h1>Javni poziv</h1><p>Prijave do 31. decembra 2050.</p></aside>"
          item = prepare["items"].first
          assert_equal "2040-10-02", item["closes_on"]
          assert_equal 1, item["attachments"].size
        end

        test "cancelled and unknown deadline calls never become active" do
          @html = @html.sub("raspisan Javni", "poništen Javni")
          assert_equal "cancelled", prepare["items"].first["temporal_status"]
          assert_empty read[:facts]
          @html = @html.sub("poništen Javni", "raspisan Javni").sub("od 3. septembra do 2. oktobra 2040. godine", "do daljnjeg")
          assert_equal "unknown", prepare["items"].first["temporal_status"]
          result = read
          assert_equal "unreviewed", result[:status]
          assert_empty result[:facts]
        end

        test "required documents and application evidence remain public and incomplete" do
          @html = @html.sub("</span>", "<br />Uz prijavu priložiti potvrdu kluba.<br />Prijave dostaviti putem navedenog obrasca.</span>")
          item = prepare["items"].first
          assert_equal "Grad Bijeljina", item["issuer"]
          assert_includes item["required_documents_evidence"], "Uz prijavu priložiti potvrdu kluba."
          assert_equal false, item["required_documents_complete"]
          assert_equal URL, read[:facts].first["application_url"]
        end

        test "linked amendment suppresses original deadline and unlinked update requires review" do
          original = prepare["items"].first.deep_dup
          @html = @html.sub("raspisan Javni", "produžen Javni")
          assert_equal "unreviewed", prepare["status"]
          assert_empty read[:facts]
          update_url = URL.sub("900001.", "900002.")
          @html = @html.sub("</span>", %(<br /><a href="#{URL}">Originalni javni poziv</a></span>))
          prep = PublicCallsPreparation.new(organization: @organization, source_store: @store)
          amendment = prep.extract(@html, update_url, Time.current)
          items = [original, amendment]
          assert_not prep.send(:reconcile_updates, items)
          assert_equal "superseded", original["temporal_status"]
          assert_equal update_url, original["superseded_by"]
          @store.row.check_payload.merge!("status" => "ok", "items" => items)
          assert_equal([amendment["id"]], read[:facts].map { |fact| fact["id"] })
        end

        test "a place in a title alone is not an eligibility territory" do
          @html = @html.sub("sportske stipendije", "sportske stipendije MZ Izmišljeni vrt")
          item = prepare["items"].first
          assert_empty item.dig("coverage", "area_slugs")
          assert_equal "unknown", item.dig("coverage", "geographic_scope")
        end

        test "conflicting or reversed application dates remain unreviewed" do
          @html = @html.sub("</span>", "Prijave od 3. septembra do 4. oktobra 2040. godine.<br /></span>")
          item = prepare["items"].first
          assert_equal "unknown", item["temporal_status"]
          assert_includes item["warnings"], "application_deadline_conflicting"
        end

        test "numeric windows and explicit standalone deadlines remain distinct" do
          @html = @html.sub("od 3. septembra do 2. oktobra 2040. godine", "od 03.09.2040. do 02.10.2040.")
          item = prepare["items"].first
          assert_equal "2040-09-03", item["opens_on"]
          assert_equal "2040-10-02", item["closes_on"]
          @html = @html.sub("Podnošenje prijava traje od 03.09.2040. do 02.10.2040..", "Rok za prijavu je 02.10.2040.")
          item = prepare["items"].first
          assert_nil item["opens_on"]
          assert_equal "2040-10-02", item["closes_on"]
          assert_equal "unknown_opening_date", read[:facts].first["active_status"]
        end

        test "expiration and relevance filters occur before limit" do
          prepare
          template = @store.row.check_payload.fetch("items").first
          expired = 12.times.map { |index| template.merge("id" => "expired:#{index}", "closes_on" => "2040-09-08") }
          @store.row.check_payload["items"] = expired + [template]
          assert_equal([template["id"]], read[:facts].map { |fact| fact["id"] })
          assert_empty read(entities: { "date" => "2040-10-03" })[:facts]
          assert_equal 1, read(entities: { "date" => "2040-10-02" })[:facts].size
        end

        test "explicit closing clock expires at its boundary instead of local midnight" do
          @html = @html.sub("2. oktobra 2040. godine", "9. septembra 2040. godine u 14:00")
          item = prepare["items"].first
          assert_equal "2040-09-09T14:00:00+02:00", item["closes_at"]
          assert_empty read[:facts]
        end

        test "missing stale failed and wrong version snapshots never fetch in reader" do
          assert_equal "unavailable", read[:status]
          prepare
          @store.row.check_payload["checked_at"] = 30.days.ago.iso8601
          assert_equal "stale", read[:status]
          prepare
          @store.row.check_payload["status"] = "unreviewed"
          assert_equal "unreviewed", read[:status]
          @store.row.source_version = "old parser"
          assert_equal "unavailable", read[:status]
        end

        test "different origin links are not followed and a redirected article fails safely" do
          calls = []
          fetcher = lambda do |**options|
            calls << options[:url]
            { http_status: 200, final_url: "https://other.example.invalid/call.html", body: @html }
          end
          prep = PublicCallsPreparation.new(organization: @organization, source_store: @store, fetcher:)
          result = prep.call(html: listing(extra_link: "https://other.example.invalid/call.html"), source_url: LISTING_URL, fetched_at: Time.current)
          assert_equal [URL], calls
          assert_equal "unreviewed", result["status"]
          assert_empty read[:facts]
        end

        test "tenant permission and malformed date produce safe bounded outcomes" do
          prepare
          @store.row.check_payload["organization_id"] = @organization.id + 1
          assert_equal "unavailable", read[:status]
          assert_equal "not_authorized", read(capabilities: [])[:status]
          assert_equal "ambiguous", read(entities: { "date" => "2040-02-30" })[:status]
        end

        test "absent or disabled parent source returns unavailable without touching stored calls" do
          sources = CityServiceSources
          previous = sources::SOURCES
          configured = previous.find { |row| row[:key] == PublicCallsPreparation::PARENT_SOURCE_KEY }
          @store.define_singleton_method(:snapshot) { |**| raise "disabled call source must not read a snapshot" }
          [[], [configured.merge(enabled: false)]].each do |rows|
            sources.send(:remove_const, :SOURCES)
            sources.const_set(:SOURCES, rows.freeze)
            result = read
            assert_equal "unavailable", result[:status]
            assert_empty result[:facts]
            assert_includes result[:warnings], "public_calls_source_not_configured"
            assert_nil result[:source] if rows.empty?
          end
        ensure
          sources.send(:remove_const, :SOURCES)
          sources.const_set(:SOURCES, previous)
        end

        test "missing reviewed place configuration stops preparation before any article fetch" do
          owner = PlaceAliasRegistry
          prior = owner::CONFIG_PATH
          owner.send(:remove_const, :CONFIG_PATH)
          owner.const_set(:CONFIG_PATH, "")
          preparer = PublicCallsPreparation.new(organization: @organization, source_store: @store,
            fetcher: ->(**) { raise "missing reviewed place evidence must not fetch an article" })
          result = preparer.call(html: listing, source_url: LISTING_URL, fetched_at: Time.current)
          assert_equal "unreviewed", result.fetch("status")
          assert_empty result.fetch("items")
          assert_equal "public_calls_preparation_incomplete", result.fetch("error_code")
        ensure
          owner.send(:remove_const, :CONFIG_PATH)
          owner.const_set(:CONFIG_PATH, prior)
        end

        test "reviewed timing keeps past current and upcoming agricultural calls separate" do
          items = [synthetic_public_call(id: "past", opens_on: "2040-09-02", closes_on: "2040-09-08"),
                   synthetic_public_call(id: "current"),
                   synthetic_public_call(id: "future", opens_on: "2040-09-10", closes_on: "2040-10-10")]
          with_synthetic_public_call_snapshot(items:, organization: @organization, now: Time.current) do |store|
            reader = PublicCallsReader.new(organization: @organization, source_checker: store)
            result = reader.call(entities: { "query" => "poljoprivreda" }, context: timing_context, locale: "sr", view: "reviewed_timing")
            assert_equal "ok", result.fetch(:status)
            assert_equal %w(closed within_explicit_application_window not_yet_open), result.fetch(:facts).map { |row| row.fetch("active_status") }
            assert_equal ["past", "current", "future"], result.fetch(:facts).map { |row| row.fetch("id") }
            assert_includes result.fetch(:warnings), "reviewed_application_timing_not_live_status"
            assert_equal "https://community.example.invalid/forms/authored-application.pdf", result.fetch(:facts).first.fetch("attachments").first.fetch("url")
            assert_equal ["public_calls:#{@organization.id}"], store.requested_keys
            active = reader.call(entities: { "query" => "poljoprivreda" }, context: timing_context, locale: "sr")
            assert_equal ["current"], active.fetch(:facts).map { |row| row.fetch("id") }
          end
        end

        test "reviewed deadline-only timing never asserts an opening date" do
          with_synthetic_public_call_snapshot(items: [synthetic_public_call(opens_on: nil, temporal_status: "deadline_only")],
                                             organization: @organization, now: Time.current) do |store|
            result = PublicCallsReader.new(organization: @organization, source_checker: store)
                                      .call(entities: {}, context: timing_context, locale: "sr", view: "reviewed_timing")
            fact = result.fetch(:facts).first
            assert_equal "unknown_opening_date", fact.fetch("active_status")
            assert_nil fact.fetch("validity").fetch("opens_on")
            assert_equal false, fact.fetch("eligibility_complete")
          end
        end

        test "cancelled unknown unpublished and reversed windows stay withheld in reviewed timing" do
          items = [synthetic_public_call(id: "cancelled", temporal_status: "cancelled"),
                   synthetic_public_call(id: "unknown", temporal_status: "unknown"),
                   synthetic_public_call(id: "unpublished", source_published_on: "2040-09-10"),
                   synthetic_public_call(id: "reversed", opens_on: "2040-10-03")]
          with_synthetic_public_call_snapshot(items:, organization: @organization, now: Time.current) do |store|
            result = PublicCallsReader.new(organization: @organization, source_checker: store)
                                      .call(entities: {}, context: timing_context, locale: "sr", view: "reviewed_timing")
            assert_empty result.fetch(:facts)
            assert_equal "unreviewed", result.fetch(:status)
          end
        end

        test "reviewed closing clocks use Sarajevo time and do not extend an elapsed deadline" do
          items = [synthetic_public_call(id: "elapsed-clock", closes_on: "2040-09-09", closes_at: "2040-09-09T13:30:00+02:00"),
                   synthetic_public_call(id: "future-clock", closes_on: "2040-09-09", closes_at: "2040-09-09T14:30:00+02:00"),
                   synthetic_public_call(id: "wrong-clock-date", closes_on: "2040-09-09", closes_at: "2040-09-10T14:30:00+02:00")]
          with_synthetic_public_call_snapshot(items:, organization: @organization, now: Time.current) do |store|
            result = PublicCallsReader.new(organization: @organization, source_checker: store)
                                      .call(entities: {}, context: timing_context, locale: "sr", view: "reviewed_timing")
            assert_equal %w(closed within_explicit_application_window), result.fetch(:facts).map { |row| row.fetch("active_status") }
            assert_equal %w(elapsed-clock future-clock), result.fetch(:facts).map { |row| row.fetch("id") }
          end
        end

        test "reviewed timing retains snapshot freshness version tenant and read permissions" do
          with_synthetic_public_call_snapshot(items: [synthetic_public_call], organization: @organization, now: Time.current) do |store|
            reader = PublicCallsReader.new(organization: @organization, source_checker: store)
            request = ->(context = timing_context) { reader.call(entities: {}, context:, locale: "sr", view: "reviewed_timing") }
            original = store.row
            store.row = nil
            assert_equal "unavailable", request.call.fetch(:status)
            store.row = SyntheticPublicCallSnapshot::Row.new(source_version: "changed", check_payload: original.check_payload)
            assert_equal "unavailable", request.call.fetch(:status)
            store.row = original
            original.check_payload["checked_at"] = (Time.current - 1.year).iso8601
            assert_equal "stale", request.call.fetch(:status)
            original.check_payload["checked_at"] = Time.current.iso8601
            original.check_payload["organization_id"] = @organization.id + 1
            assert_equal "unavailable", request.call.fetch(:status)
            original.check_payload["organization_id"] = @organization.id
            assert_equal "not_authorized", request.call(timing_context.with(capabilities: [])).fetch(:status)
          end
        end

        test "reviewed timing rejects unsupported views and caller dates rather than silently changing the clock" do
          with_synthetic_public_call_snapshot(items: [synthetic_public_call], organization: @organization, now: Time.current) do |store|
            reader = PublicCallsReader.new(organization: @organization, source_checker: store)
            result = reader.call(entities: {}, context: timing_context, locale: "sr", view: "arbitrary")
            assert_equal "unavailable", result.fetch(:status)
            assert_empty result.fetch(:facts)
            [{ "date" => "2040-10-01" }, { "time_expression" => "sutra" }].each do |entities|
              result = reader.call(entities:, context: timing_context, locale: "sr", view: "reviewed_timing")
              assert_equal "ambiguous", result.fetch(:status)
              assert_empty result.fetch(:facts)
            end
          end
        end

        test "fact publisher labels come from the configured community source in both views" do
          with_synthetic_public_call_snapshot(items: [synthetic_public_call], organization: @organization, now: Time.current) do |store|
            reader = PublicCallsReader.new(organization: @organization, source_checker: store)
            %w(active reviewed_timing).each do |view|
              result = reader.call(entities: {}, context: timing_context, locale: "sr", view:)
              assert_equal "Izmišljeni pozivi zajednice", result.fetch(:facts).first.fetch("source_label")
              refute_includes result.fetch(:facts).first.fetch("source_label"), "Bijeljina"
            end
          end
        end

        test "association subject filtering happens before the bounded result limit" do
          items = 8.times.map do |i|
            synthetic_public_call(id: "unrelated-#{i}", title: "IZMIŠLJENI poziv za nepovezanu djelatnost", closes_on: "2040-09-20")
          end
          items << synthetic_public_call(id: "association", title: "IZMIŠLJENI javni poziv za udruženja", closes_on: "2040-10-02")
          with_synthetic_public_call_snapshot(items:, organization: @organization, now: Time.current) do |store|
            result = PublicCallsReader.new(organization: @organization, source_checker: store)
                                      .call(entities: { "query" => "udruženja" }, context: timing_context, locale: "sr")
            assert_equal "ok", result.fetch(:status)
            assert_equal ["association"], result.fetch(:facts).map { |row| row.fetch("id") }
            assert_equal "https://community.example.invalid/calls/", result.fetch(:source).fetch("url")
            assert_includes result.fetch(:warnings), "selected_calls_not_complete_inventory"
          end
        end

        test "unavailable call listing metadata rejects credentials nonhttps unexpected ports and malformed urls" do
          with_synthetic_public_call_snapshot(items: [], organization: @organization, now: Time.current) do |store|
            store.row = nil
            configured = CityServiceSources.fetch(PublicCallsPreparation::PARENT_SOURCE_KEY)
            ["http://community.example.invalid/calls/", "https://user:password@community.example.invalid/calls/",
             "https://community.example.invalid:444/calls/", "://bad url", "", "https://community.example.invalid/" + "x" * 2_000].each do |url|
              CityServiceSources.stub(:find, configured.merge(source_url: url)) do
                result = PublicCallsReader.new(organization: @organization, source_checker: store)
                                          .call(entities: {}, context: timing_context, locale: "sr")
                assert_equal "unavailable", result.fetch(:status)
                assert_nil result.fetch(:source)
                assert_empty result.fetch(:facts)
                refute_includes result.to_s, "password"
              end
            end
          end
        end

        def timing_context
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "c" * 64, capabilities: ["public_reads"], now: Time.current
          )
        end

        private

        def prepare
          fetcher = ->(**) { { http_status: 200, final_url: URL, content_type: "text/html", body: @html } }
          PublicCallsPreparation.new(organization: @organization, source_store: @store, fetcher:)
                                .call(html: listing, source_url: LISTING_URL, fetched_at: Time.current)
        end

        def listing(extra_link: nil)
          links = [URL, extra_link].compact.map { |url| "<article><h2 class='entry__title'><a href='#{url}'>Javni poziv za sportske stipendije</a></h2></article>" }.join
          "<div class='blog__content'>#{links}</div>"
        end

        def read(entities: {}, capabilities: ["public_reads"])
          context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "c" * 64, capabilities:, now: Time.current
          )
          @reader.call(entities:, context:, locale: "sr")
        end
      end
    end
  end
end
