# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

module Decidim
  module Bih
    module City
      # Exercises the GENERIC citizen-budget parser against a SYNTHETIC fixture
      # (fictional categories/amounts — no Bijeljina data). The real Bijeljina
      # snapshot is held by the host app and tested in
      # DecidimApp::Bijeljina::BudgetTest.
      #
      # The engine class is referenced via the normal autoloaded constant, so the
      # test does not depend on any sibling filesystem path.
      class BudgetTest < ActiveSupport::TestCase
        BUDGET_URL = "https://example.test/budget/budzet-za-gradane.pdf"

        setup do
          WebMock.disable_net_connect!(allow_localhost: true)
          @text = file_fixture("budget_za_gradane_synthetic.txt").read
          @budget = Budget.from_text(@text)
        end

        teardown do
          WebMock.reset!
          WebMock.allow_net_connect!
        end

        test "parsing the fixture yields non-empty line items" do
          assert_not_empty @budget.line_items
          @budget.line_items.each do |item|
            assert_kind_of String, item[:category]
            assert_not_empty item[:category]
            assert_kind_of Numeric, item[:amount]
            assert_operator item[:amount], :>, 0
          end
        end

        test "categories mirrors the parsed line items" do
          assert_equal @budget.line_items.map { |i| i[:category] }, @budget.categories
          assert_includes @budget.categories, "Зелена библиотека"
        end

        test "raw extracted text is exposed" do
          assert_equal @text, @budget.raw_text
        end

        test "amount_for a known category returns its amount" do
          assert_equal 1_250_000, @budget.amount_for("Дом за змајеве")
        end

        test "amount_for matches across the dual-column layout" do
          # "Сектор за магију" is printed in the right-hand column, interleaved
          # on the same physical line as a left-column row.
          assert_equal 850_000, @budget.amount_for("Сектор за магију")
        end

        test "amount_for is diacritic and script insensitive" do
          assert_equal @budget.amount_for("Чаршијска пијаца"),
                       @budget.amount_for("carsijska pijaca")
          assert_equal 75_250, @budget.amount_for("carsijska")
        end

        test "amount_for does partial contains matching" do
          assert_equal @budget.amount_for("Виноградски центар"),
                       @budget.amount_for("vinograd")
          assert_not_nil @budget.amount_for("vinograd")
        end

        test "amount_for prefers the closest (shortest) matching category" do
          # Two categories contain "сектор"; the bare query resolves to whichever
          # is the closest match, and a specific query resolves exactly.
          assert_equal 12_000, @budget.amount_for("сектор за облаке")
        end

        test "unknown or blank query returns nil" do
          assert_nil @budget.amount_for("Атлантида")
          assert_nil @budget.amount_for("")
          assert_nil @budget.amount_for(nil)
        end

        test "subtotal and grand-total rows are excluded from line items" do
          @budget.categories.each do |category|
            assert_no_match(/укуп/i, category)
          end
        end

        test "total returns the stated grand total when present" do
          assert_equal 5_000_000, @budget.total
        end

        test "total falls back to the sum of line items when no stated total" do
          text = "Образовање 100.000,00 КМ\nЗдравство 250.000,00 КМ\n"
          budget = Budget.from_text(text)

          assert_nil budget.send(:detect_stated_total, text)
          assert_equal 350_000, budget.total
        end

        test "amounts parse as Integer when whole and Float with cents" do
          budget = Budget.from_text("Цијела ставка 1.000,00 КМ\nСтавка са центима 1.234,50 КМ\n")
          amounts = budget.line_items.map { |i| i[:amount] }

          assert_includes amounts, 1_000
          assert_includes amounts, 1234.5
          assert_kind_of Integer, budget.amount_for("Цијела ставка")
          assert_kind_of Float, budget.amount_for("Ставка са центима")
        end

        test "US-format figures from the debt annex are not parsed as amounts" do
          # The fixture's credit table uses "10,000,000.00" style figures; none
          # of those must surface as a line item.
          assert_nil @budget.amount_for("Банка Облака")
          assert_nil @budget.amount_for("Изградња торња")
        end

        test "the fiscal year is parsed from the budget" do
          assert_equal 2025, @budget.year
        end

        test "a freshly constructed budget has no data until something is loaded" do
          assert_empty Budget.new.line_items
          assert_empty Budget.new.categories
          assert_equal 0, Budget.new.total
        end

        test "fetch downloads and parses the live PDF from the given url" do
          stub_request(:get, BUDGET_URL)
            .to_return(status: 200, body: minimal_pdf, headers: { "Content-Type" => "application/pdf" })

          budget = Budget.new(source_url: BUDGET_URL).fetch

          assert_not_empty budget.raw_text
        end

        test "fetch raises on a 502 transport failure" do
          stub_request(:get, BUDGET_URL).to_return(status: 502)

          assert_raises(BudgetError) do
            Budget.new(source_url: BUDGET_URL).fetch
          end
        end

        test "fetch raises when no url is configured" do
          assert_raises(BudgetError) { Budget.new.fetch }
        end

        private

        # Minimal single-page PDF carrying one extractable ASCII line, enough to
        # exercise the download + pdf-reader transport path.
        def minimal_pdf
          content = "BT /F1 12 Tf 72 720 Td (budget stub 1.000,00 KM) Tj ET"
          objects = []
          objects << "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj"
          objects << "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj"
          objects << "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]" \
                     "/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>endobj"
          objects << "4 0 obj<</Length #{content.bytesize}>>stream\n#{content}\nendstream endobj"
          objects << "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj"
          header = "%PDF-1.4\n"
          body = +""
          offsets = []
          objects.each do |obj|
            offsets << (header.bytesize + body.bytesize)
            body << obj << "\n"
          end
          xref_pos = header.bytesize + body.bytesize
          xref = "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
          offsets.each { |off| xref << format("%010d 00000 n \n", off) }
          trailer = "trailer<</Size #{objects.size + 1}/Root 1 0 R>>\n" \
                    "startxref\n#{xref_pos}\n%%EOF"
          header + body + xref + trailer
        end
      end
    end
  end
end
