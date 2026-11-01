# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/synthetic_citizen_notice_sources"

module DecidimApp
  module Bijeljina
    class CitizenNoticePilotsTest < ActiveSupport::TestCase
      include SyntheticCitizenNoticeSources
      Row = Struct.new(:source_version, :check_payload, :last_good_payload, keyword_init: true)
      class Store
        attr_reader :row

        def with_refresh_lock(*) = yield

        def snapshot(**) = @row

        def promote(source_version:, payload:, success:, **)
          @row ||= Row.new(source_version:, last_good_payload: {})
          @row.source_version = source_version if success
          @row.check_payload = payload
          @row.last_good_payload = payload.deep_dup if success
        end
      end

      setup do
        @now = Time.iso8601("2040-09-15T08:00:00Z")
        @store = Store.new
      end

      test "benefit pilot routing requires payment arrival or schooling deadline intent" do
        {
          "Kad će penzija?" => "pio_notices",
          "Кад ће пензија?" => "pio_notices",
          "Kad stiže penzija za avgust?" => "pio_notices",
          "Kada počinje isplata Fond PIO?" => "pio_notices",
          "Kada je isplata dječijeg dodatka?" => "jfdz_notices",
          "Kad će materinski dodatak?" => "jfdz_notices",
          "Do kada dostaviti potvrdu o školovanju za porodičnu penziju?" => "pio_notices",
          "Rok za potvrdu o školovanju Fond PIO" => "pio_notices"
        }.each do |query, key|
          assert_equal key, Milica::CitizenNoticeRead.source_key(topic: "social_welfare", entities: { "query" => query }), query
        end
      end

      test "benefit pilot does not swallow hours contacts websites or generic procedures" do
        [
          "Kad radi Fond PIO?", "Кад ради Фонд ПИО?", "Kada se otvara Fond PIO?",
          "Do koliko radi Fond PIO?", "Koje je radno vrijeme JFDZ?", "Radi li Fond PIO subotom?",
          "Kad mogu kontaktirati Fond PIO?", "Koji je telefon za isplatu penzija?",
          "Koja je web stranica sa datumom isplate dječijeg dodatka?",
          "Kad će penzija i koji je telefon Fond PIO?", "Gdje je Fond PIO i kad je isplata?",
          "Kad mogu podnijeti zahtjev za penziju?", "Kako se prijaviti za isplatu dječijeg dodatka?",
          "Kada ostvarujem pravo na penziju?", "Koji dokumenti trebaju za isplatu penzije?",
          "Rok za žalbu Fond PIO", "Kad počinje rad Fond PIO?", "Kad je Fond PIO osnovan?"
        ].each do |query|
          assert_nil Milica::CitizenNoticeRead.source_key(topic: "social_welfare", entities: { "query" => query }), query
        end
      end

      test "border pilot requires actual status and declines contact or mixed requests" do
        ["Kolika je gužva na Rači?", "Koliko se čeka na granici?", "Kakvo je stanje na GP Popovi?",
         "Status graničnog prelaza Šepak", "Da li je granica prohodna?"].each do |query|
          assert_equal "bihamk_border", Milica::CitizenNoticeRead.source_key(topic: "roads", entities: { "query" => query }), query
        end
        ["Koji je telefon graničnog prelaza Rača?", "Koja je web stranica graničnog prelaza Rača?",
         "Koliko se čeka na Rači i koji je telefon prelaza?", "Gdje je granični prelaz Rača?",
         "Koje je radno vrijeme graničnog prelaza?", "Granični prelaz Rača"].each do |query|
          assert_nil Milica::CitizenNoticeRead.source_key(topic: "roads", entities: { "query" => query }), query
        end
      end

      test "border identities, passenger ceilings and report clock stay separate" do
        records = CitizenNoticePilotParser.borders(border_html, now: @now)
        assert_equal(%w(bihamk:raca bihamk:popovi bihamk:sepak), records.map { |record| record["id"] })
        assert_equal([11, 23, 17], records.map { |record| record["wait_ceiling_minutes"] })
        assert_nil records.first["wait_measurement_minutes"]
        assert_equal "2040-09-15T09:00:00+02:00", records.first["observed_at"]
        assert_includes records.last["standing_notice"], "teretna"
        assert_equal "passenger_vehicles", records.last["vehicle_scope"]
        assert_raises(CitizenNoticePilots::InvalidSource) { CitizenNoticePilotParser.borders(border_html.sub("datetime=", "data-unknown="), now: @now) }
        assert_raises(CitizenNoticePilots::InvalidSource) { CitizenNoticePilotParser.borders(border_html, now: @now - 7200) }
      end

      test "child benefit payment month publication and start are separate from bank receipt" do
        records = CitizenNoticePilotParser.child_benefit(child_article, url: child_url, now: @now)
        assert_equal 1, records.size
        record = records.first
        assert_equal "2040-08", record["period_covered"]
        assert_equal "2040-09-04", record["source_published_on"]
        assert_equal "2040-09-04", record["payment_starts_on"]
        assert_equal false, record["personal_status"]
        assert_includes record["warnings"], "payment_start_not_individual_receipt"
        assert_not_includes JSON.generate(record), "AUTHORED_UNRELATED_TOTAL"
      end

      test "benefit governance and sensitive result lists are not payment answers" do
        governance = child_article.sub("Redovna isplata počela je danas", "Sjednica kolegijuma").sub(%r{<p>.*</p>}m, "<p>Kolegijum zasjeda.</p>")
        assert_empty CitizenNoticePilotParser.child_benefit(governance, url: child_url, now: @now)
        sensitive = child_article.sub("Redovna isplata počela je danas", "Lista korisnika prava")
        assert_empty CitizenNoticePilotParser.child_benefit(sensitive, url: child_url, now: @now)
      end

      test "pension RSS supplies payment start with original publication and covered month" do
        body = "<rss><channel><title>Autorski testni fond</title><item><title>Autorska testna penzija za avgust</title><link>https://pension.example.invalid/authored-payment</link>" \
               "<pubDate>Sat, 08 Sep 2040 08:10:13 +0200</pubDate><description><![CDATA[" \
               "<p>Autorski test: isplata za avgust 2040. godine počinje 08. septembra 2040. godine.</p>]]></description></item></channel></rss>"
        record = CitizenNoticePilotParser.pension_feed(body, now: @now).first
        assert_equal "2040-08", record["period_covered"]
        assert_equal "2040-09-08", record["payment_starts_on"]
        assert_equal "2040-09-08", record["source_published_on"]
      end

      test "school and university obligations retain separate deadlines and expired records are excluded" do
        details = { title: "Potvrde o školovanju za penziju", url: "https://pension.example.invalid/authored-school-deadline", published: Date.new(2040, 8, 26), key: "pio_notices" }
        body = "<p>Učenici srednjih škola dostavljaju potvrdu o školovanju do 24.09.2040.</p>" \
               "<p>Studenti dostavljaju potvrdu o školovanju do 24.10.2040.</p>"
        records = CitizenNoticePilotParser.benefit_records(body, details:, now: @now)
        assert_equal(%w(2040-09-24 2040-10-24), records.map { |record| record["deadline_on"] })
        reader = Milica::CitizenNoticeRead.new(source_store: @store)
        after_school_deadline = reader.send(:selected_deadlines, records, query: "rok za potvrdu o skolovanju", now: @now + 20.days)
        assert_equal(["university_students"], after_school_deadline.map { |record| record["audience"] })
        assert_nil CitizenNoticePilotParser.source_date("24.09.2040. ili 24.10.2040.")
        assert_empty reader.send(:selected_deadlines, records, query: "rok za potvrdu o skolovanju 2039", now: @now)
      end

      test "bounded refresh promotes public records and TLS failure preserves last good with explicit caveat" do
        prepare_border
        original = @store.row.last_good_payload.deep_dup
        fetcher = ->(**) { raise OpenSSL::SSL::SSLError, "certificate verify failed" }
        failed = CitizenNoticePilots.new(source_store: @store, fetcher:).refresh(key: "bihamk_border", now: @now)
        assert_equal "tls_verification_failed", failed["error_code"]
        assert_equal original, @store.row.last_good_payload
        response = read_border
        assert_equal "unreviewed", response[:status]
        assert_equal true, response.dig(:validity, "last_known_only")
        assert_includes response[:warnings], "latest_pilot_attempt_failed"
        assert_includes response[:facts].first["text"], "trenutni status nije potvrđen"
      end

      test "reader uses prepared crossing identity without HTTP or mixing Popovi and Raca" do
        prepare_border
        response = read_border(query: "Kolika je gužva na Pavlovića mostu?")
        assert_equal "ok", response[:status]
        assert_equal(["bihamk:popovi"], response[:facts].map { |fact| fact["id"] })
        assert_equal 23, response[:facts].first["wait_ceiling_minutes"]
        assert_equal "unavailable", read_border(query: "Koliko čekaju kamioni na granici?")[:status]
        assert_equal "unavailable", read_border(entities: { "time_expression" => "sutra" })[:status]
        assert_equal "not_authorized", read_border(capabilities: [])[:status]
      end

      test "stale reports stay dated last known and parser version mismatch cannot be served" do
        prepare_border
        response = read_border(now: @now + 14_400)
        assert_equal "unreviewed", response[:status]
        assert_includes response[:warnings], "last_known_notice_not_current_status"
        @store.row.source_version = "old"
        assert_empty read_border[:facts]
      end

      test "cached future or offsetless observation clocks fail closed in the reader" do
        prepare_border
        @store.row.check_payload["records"].first["observed_at"] = (@now + 60).iso8601
        assert_equal "unavailable", read_border[:status]
        assert_empty read_border[:facts]
        @store.row.check_payload["records"].first["observed_at"] = "2040-09-15T09:00:00"
        assert_empty read_border[:facts]
        prepare_border
        @store.row.check_payload["checked_at"] = (@now + 60).iso8601
        assert_empty read_border[:facts]
      end

      test "cached publication cannot be future but an announced future payment start remains valid" do
        prepare_child
        @store.row.check_payload["records"].first["source_published_on"] = "2040-09-16"
        assert_equal "unavailable", read_child[:status]
        assert_empty read_child[:facts]
        @store.row.check_payload["records"].first.merge!("source_published_on" => "2040-09-15", "payment_starts_on" => "2040-09-16")
        assert_equal "ok", read_child[:status]
        assert_equal "2040-09-16", read_child[:facts].first["payment_starts_on"]
      end

      test "an explicit payment year and month cannot return another year's or month's notice" do
        prepare_child
        assert_empty read_child(query: "Kada počinje isplata dječijeg dodatka za avgust 2039?")[:facts]
        assert_empty read_child(query: "Kada počinje isplata dječijeg dodatka za april 2040?")[:facts]
        assert_empty read_child(query: "Kada počinje isplata dječijeg dodatka za 2039?")[:facts]
        assert_equal 1, read_child(query: "Kada počinje isplata dječijeg dodatka za august 2040?")[:facts].size
        assert_equal "unavailable", read_child(query: "Kada počinje isplata dječijeg dodatka za avgust 2039 i 2040?")[:status]
      end

      test "child listing fetch is bounded and body-bearing results never replace payment records" do
        urls = []
        fetcher = lambda do |url:, **|
          urls << url
          body = url == "https://benefit.example.invalid/sr" ? %(<a href="#{child_url}">Redovna isplata</a>) : child_article
          { http_status: 200, final_url: url, body: }
        end
        result = CitizenNoticePilots.new(source_store: @store, fetcher:).refresh(key: "jfdz_notices", now: @now)
        assert_equal "ok", result["status"]
        assert_equal ["https://benefit.example.invalid/sr", child_url], urls
        assert_equal 1, result["records"].size
      end

      test "authored Bosnian and Croatian provider months retain the covered period and future start" do
        details = { title: "Autorska testna penzijska objava", url: "https://pension.example.invalid/authored-locale-payment",
                    published: @now.to_date, key: "pio_notices" }
        { "juni" => "2040-06", "juli" => "2040-07", "kolovoz" => "2040-08" }.each do |month, expected|
          body = "<p>Autorski test: isplata za #{month} 2040. godine počinje 16. rujna 2040. godine.</p>"
          record = CitizenNoticePilotParser.benefit_records(body, details:, now: @now).sole
          assert_equal expected, record["period_covered"]
          assert_equal "2040-09-16", record["payment_starts_on"]
          assert_equal "2040-09-15", record["source_published_on"]
          assert_equal false, record["personal_status"]
        end
      end

      test "cached benefits require public issuer scope a valid period and a real start date" do
        prepare_child
        original = @store.row.check_payload.deep_dup
        [{ "personal_status" => true }, { "subject_id" => "authored-other-fund" },
         { "period_covered" => "2040-99" }, { "period_covered" => "2040-8" },
         { "payment_starts_on" => "2040-09-31" }, { "payment_starts_on" => "AUTHORED_PRIVATE_DATE_MARKER" }].each do |change|
          @store.row.check_payload = original.deep_dup
          @store.row.check_payload["records"][0].merge!(change)
          result = read_child
          assert_equal "unavailable", result[:status]
          assert_empty result[:facts]
          assert_not_includes result.to_json, "AUTHORED_PRIVATE_DATE_MARKER"
        end
      end

      test "old parser snapshot identity is not silently promoted after the locale grammar change" do
        prepare_child
        saved = @store.row.last_good_payload.deep_dup
        previous = Digest::SHA256.hexdigest(JSON.generate(["citizen-notice-pilots-v2", CitizenNoticePilots::SOURCES.fetch("jfdz_notices")]))
        assert_not_equal previous, @store.row.source_version
        @store.row.source_version = previous
        result = read_child
        assert_equal "unavailable", result[:status]
        assert_empty result[:facts]
        assert_equal saved, @store.row.last_good_payload
        prepare_child
        assert_equal "ok", read_child[:status]
        assert_equal CitizenNoticePilots.version_for("jfdz_notices"), @store.row.source_version
      end

      test "exact month and source survive all four supported reader locales" do
        prepare_child
        queries = { "sr" => "Kada počinje isplata dječijeg dodatka za avgust 2040?",
                    "sr-Cyrl" => "Када почиње исплата дјечијег додатка за август 2040?",
                    "bs" => "Kada počinje isplata dječijeg dodatka za august 2040?",
                    "hr" => "Kada počinje isplata dječijeg dodatka za kolovoz 2040?" }
        queries.each do |locale, query|
          result = read_child(query:, locale:)
          assert_equal "ok", result[:status], locale
          row = result[:facts].sole
          assert_equal "2040-08", row["period_covered"]
          assert_equal "2040-09-04", row["payment_starts_on"]
          assert_equal child_url, row["source_url"]
          assert_equal false, row["personal_status"]
        end
        assert_equal "unavailable", read_child(query: "Isplata dječijeg dodatka za juli i kolovoz 2040?")[:status]
      end

      private

      def child_url = "https://benefit.example.invalid/sr/news/101/authored-payment"

      def child_article
        '<article class="mb-60"><span class="text-muted">04.09.2040.</span><h1>Autorska testna objava: Redovna isplata počela je danas</h1>' \
          "<p>Autorski test: isplata za mjesec avgust 2040. godine počinje danas, 04. septembra 2040. godine.</p><p>Autorski izmišljeni zbir: AUTHORED_UNRELATED_TOTAL.</p></article>"
      end

      def border_html
        rows = [%w(Rača 11), %w(Popovi 23), %w(Šepak 17)].map do |name, ceiling|
          restriction = name == "Šepak" ? "<p>Autorski scenario: teretna vozila nisu obuhvaćena putničkim izvještajem.</p>" : ""
          %(<article><h3>GP #{name}</h3><p>Autorski izvještaj: zadržavanja putničkih vozila nisu duža od #{ceiling} minuta.</p>#{restriction}</article>)
        end.join
        %(<h1>Granični prijelazi</h1><time datetime="2040-09-15 09:00:00">15.09.2040.</time>#{rows})
      end

      def prepare_border
        fetcher = ->(**) { { http_status: 200, body: border_html } }
        CitizenNoticePilots.new(source_store: @store, fetcher:).refresh(key: "bihamk_border", now: @now)
      end

      def prepare_child
        fetcher = lambda do |url:, **|
          { http_status: 200, final_url: url, body: url == "https://benefit.example.invalid/sr" ? %(<a href="#{child_url}">Redovna isplata</a>) : child_article }
        end
        CitizenNoticePilots.new(source_store: @store, fetcher:).refresh(key: "jfdz_notices", now: @now)
      end

      def read_child(query: "Kada počinje isplata dječijeg dodatka?", locale: "sr")
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, capabilities: ["public_reads"], now: @now)
        Milica::CitizenNoticeRead.new(source_store: @store).call(topic: "social_welfare", entities: { "query" => query }, context:, locale:)
      end

      def read_border(query: "Kolika je gužva na Rači?", entities: {}, now: @now, capabilities: ["public_reads"])
        context = Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, capabilities:, now:)
        Milica::CitizenNoticeRead.new(source_store: @store).call(topic: "roads", entities: { "query" => query }.merge(entities), context:, locale: "sr")
      end
    end
  end
end
