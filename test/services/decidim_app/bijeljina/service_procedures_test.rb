# frozen_string_literal: true

require "test_helper"
require "tempfile"
require_relative "../../../support/synthetic_procedures"

module DecidimApp
  module Bijeljina
    class ServiceProceduresTest < ActiveSupport::TestCase
      include SyntheticProcedures
      setup { install_synthetic_procedures }
      teardown { restore_synthetic_procedures }

      test "provider code is distinct from page id and blank fee remains unknown" do
        card = ServiceProcedures.find("TEST_4")
        assert_equal "ТЕСТ_4", card[:provider_procedure_code]
        assert_equal "test-page-A", card[:source_page_id]
        assert_nil card[:fee]
        assert_nil card[:form_download_url]
        assert_equal 3, card[:required_documents].size
        assert_equal false, card[:processing_time][:guaranteed_completion]
      end

      test "reviewed code title and mirror aliases resolve without broad topic guessing" do
        assert_equal "registry_b4_1", ServiceProcedures.match_query("Koliko košta izmišljena potvrda?")[:key]
        assert_equal "registry_b4_1", ServiceProcedures.match_query("Шта треба за ТЕСТ_4?")[:key]
        assert_nil ServiceProcedures.match_query("porez")
        assert_nil ServiceProcedures.match_query("XTEST_4123")
        assert_nil ServiceProcedures.match_query("TEST_4 ili e-matičar")
        assert_equal "maticar", ServiceProcedures.find("https://community.example.invalid/mirror/maticar")[:key]
      end

      test "malformed missing and duplicate configured procedure identities fail without exposing payload" do
        owner = ServiceProcedures
        prior_path = owner::PATH
        prior_cards = owner.instance_variable_get(:@all)
        Tempfile.create(["authored-procedure-catalogue", ".json"]) do |file|
          owner.send(:remove_const, :PATH)
          owner.const_set(:PATH, file.path)
          ["{private-value", "[]", '{"procedures":{}}', '{"procedures":["private-value"]}',
           '{"procedures":[{}]}', '{"procedures":[{"key":"same"},{"key":"same"}]}'].each do |raw|
            file.rewind
            file.truncate(0)
            file.write(raw)
            file.flush
            owner.remove_instance_variable(:@all) if owner.instance_variable_defined?(:@all)
            error = assert_raises(ServiceProcedures::InvalidConfiguration) { owner.all }
            assert_equal "procedure configuration is invalid", error.message
            assert_nil error.cause
            assert_not_includes error.message, "private-value"
          end
          file.rewind
          file.truncate(0)
          file.write(JSON.generate("procedures" => synthetic_procedure_cards(day: Date.new(2040, 9, 9))))
          file.flush
          owner.remove_instance_variable(:@all) if owner.instance_variable_defined?(:@all)
          assert_equal 4, owner.all.size
          assert_equal "birth_extract", owner.find("maticar").fetch(:document_kind)
          assert_equal "online", owner.find("maticar").fetch(:channel)
        end
      ensure
        owner.send(:remove_const, :PATH)
        owner.const_set(:PATH, prior_path)
        owner.instance_variable_set(:@all, prior_cards)
      end

      test "registry review hash is scoped to detail rather than navigation" do
        card = ServiceProcedures.find("TEST_4")
        html = synthetic_procedure_html("registry_b4_1")
        assert_equal card[:reviewed_content_hash], CityReferenceRefresh.procedure_content_hash(html, selector: "registry_detail")
        assert_equal card[:reviewed_content_hash], CityReferenceRefresh.procedure_content_hash("#{html}<footer>Different navigation</footer>", selector: "registry_detail")
        assert_raises(ArgumentError) { CityReferenceRefresh.procedure_content_hash("<body>maintenance</body>", selector: "registry_detail") }
      end
    end
  end
end
