# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_foundation_reference"

module DecidimApp
  module Bijeljina
    module Milica
      # F-1: a question about how to REACH the foundation used to match NAME,
      # fall through every intent branch and land on the city-service path,
      # where the Gradska uprava contact card answered "telefon" — which is how
      # the municipality's switchboard was returned as the foundation's.
      class FoundationReadContactTest < ActiveSupport::TestCase
        include SyntheticFoundationReference
        setup { install_synthetic_foundation_reference }
        teardown { restore_synthetic_foundation_reference }
        CONTACT_QUESTIONS = [
          "Koji je telefon Lokalne fondacije Bijeljina?",
          "Koja je adresa Lokalne fondacije Bijeljina?",
          "Gdje se nalazi Lokalna fondacija Bijeljina?",
          "Koji je kontakt mejl Lokalne fondacije Bijeljina?",
          "Daj mi broj Lokalne fondacije Bijeljina."
        ].freeze

        setup { @organization = create_organization }

        test "a contact question about the foundation is claimed by the foundation reader" do
          CONTACT_QUESTIONS.each do |query|
            assert_equal :contact, FoundationRead.intent(topic: "community", entities: { "query" => query }), query
            assert FoundationRead.handles?(topic: "community", entities: { "query" => query }), query
          end
        end

        test "the contact answer carries the published record and no phone number" do
          result = ask(CONTACT_QUESTIONS.first)

          assert_equal "ok", result.fetch(:status)
          contact = result.fetch(:facts).find { |fact| fact.fetch("id") == "lfbn:about:contact" }

          assert contact, "the contact fact is missing"
          assert_includes contact.fetch("text"), "Izmišljena ulica 42, Testni grad"
          assert_includes contact.fetch("text"), "office@foundation.example.invalid"
          # The only foundation phone in the database lives in a column named
          # `private_contact_phone`. Nothing here may ever read it, and the
          # municipality's switchboard is a different organisation's number.
          assert_no_match(%r{\+?387|\b0?55[\s/-]?2\d\d}, contact.fetch("text"))
        end

        test "every supported locale has the contact copy" do
          %w(sr sr-Cyrl bs hr en).each do |locale|
            fact = ask(CONTACT_QUESTIONS.first, locale:).fetch(:facts).find { |row| row.fetch("id") == "lfbn:about:contact" }

            assert fact, locale
            assert_includes fact.fetch("text"), Decidim::Bih.public_support_email, locale
            assert_includes fact.fetch("text"), Decidim::Bih.public_support_address, locale
            # The generated Cyrillic must never transliterate an e-mail address
            # or a domain; interpolating them is what keeps them Latin.
            assert_no_match(/фоундатион|оффице/, fact.fetch("text"), locale)
          end
        end

        # A contact question is not a question about the idea call, so it must
        # not drag the call's status along with it.
        test "a contact answer omits the idea-call status but keeps the identity fact" do
          ids = ask(CONTACT_QUESTIONS.first).fetch(:facts).map { |fact| fact.fetch("id") }

          assert_equal %w(lfbn:about:identity lfbn:about:contact), ids
        end

        test "the existing identity, funding and apply intents are unchanged" do
          assert_equal :identity, FoundationRead.intent(topic: "community", entities: { "query" => "Šta je Lokalna fondacija Bijeljina?" })
          assert_equal :funding,
                       FoundationRead.intent(topic: "community",
                                             entities: { "query" => "Da li Lokalna fondacija Bijeljina finansira projekte građana?" })
          assert_equal :apply,
                       FoundationRead.intent(topic: "community", entities: { "query" => "Gdje mogu prijaviti svoju ideju Lokalnoj fondaciji Bijeljina?" })
        end

        private

        def ask(query, locale: "sr")
          FoundationRead.new(organization: @organization)
                        .call(topic: "community", entities: { "query" => query }, context: context(Time.current), locale:)
        end

        def context(now)
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "b" * 64, actor_id: nil,
            account_state: "anonymous", capabilities: %w(public_reads), now:
          )
        end
      end
    end
  end
end
