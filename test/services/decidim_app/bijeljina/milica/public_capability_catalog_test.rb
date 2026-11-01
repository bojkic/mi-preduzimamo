# frozen_string_literal: true

require "test_helper"

module DecidimApp
  module Bijeljina
    module Milica
      class PublicCapabilityCatalogTest < ActiveSupport::TestCase
        Dialogue = Decidim::Bih::Concierge::Dialogue

        setup do
          organization = Struct.new(:id, :host).new(19, "mi.example.test")
          @catalog = PublicCapabilityCatalog.new(organization:)
        end

        test "reply script instructions remain composition requests even after platform script guidance" do
          states = [{}, { Dialogue::AnswerContext::KEY => { "subject" => "cap_script" } }]
          states.each do |state|
            ["Напиши ћирилицом.", "Напиши ћирилицом, али сачувај назив NAS.", "Odgovori latinicom."].each do |text|
              assert_nil @catalog.resolve(text:, locale: "sr", state:, channel: "web_chat"), text
            end
          end
        end

        test "actual platform script changes still resolve reviewed guidance in both scripts" do
          {
            "Kako da prebacim prikaz platforme na ćirilicu?" => "sr",
            "Како да промијеним писмо налога?" => "sr-Cyrl"
          }.each do |text, locale|
            capability = @catalog.resolve(text:, locale:, state: {}, channel: "web_chat")
            assert capability, text
            assert_equal "script", capability.key
            assert_equal "cap_script", capability.context_subject
            assert_includes capability.text, "https://mi.example.test/"
          end
        end

        test "anonymous reporting and private supplement guidance use the configured engine mount" do
          Decidim::Bih.stub(:normalized_public_mount_path, "/board-host") do
            anonymous = @catalog.resolve(text: "Moram li imati nalog da opišem komunalni problem?", locale: "sr", state: {}, channel: "web_chat")
            assert_equal "report_anonymous", anonymous.key
            assert_includes anonymous.text, "https://mi.example.test/board-host/prijave/new"

            supplement = @catalog.resolve(text: "Kako da dopunim prijavu?", locale: "sr", state: {}, channel: "web_chat")
            assert_equal "report_supplement", supplement.key
            assert_includes supplement.text, "https://mi.example.test/board-host/prijave?view=mine"
            assert_not_includes supplement.text, "https://mi.example.test/prijave"
          end
        end
      end
    end
  end
end
