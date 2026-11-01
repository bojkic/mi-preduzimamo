# frozen_string_literal: true

require "test_helper"
require_relative "../../../../support/synthetic_foundation_reference"

module DecidimApp
  module Bijeljina
    module Milica
      # Four donation questions, four different answers: how to give, which
      # approved project to give to, how much has been raised, and where it was
      # allocated. They used to collapse into the aggregate total — and the
      # foundation's payment instructions, which live on its own published
      # partner record, leaked into a race answer and into "where do I submit an
      # idea".
      #
      # Only the GIVING branch is the place those instructions belong. The
      # aggregate total is ReferenceRead's and is not touched here.
      class DonationQuestionReadTest < ActiveSupport::TestCase
        include SyntheticFoundationReference

        teardown do
          restore_synthetic_foundation_reference
        end
        PAYMENT_TEXT = "Donirati možete uplatom na račun 000-00000000000-00."

        setup do
          install_synthetic_foundation_reference
          @organization = create_organization
          @reader = PlatformCatalogRead.new(organization: @organization)
          @foundation = profile(display_name: Decidim::Bih.public_support_name, public_description: PAYMENT_TEXT)
          @other = profile(display_name: "Aktivni komšije", public_description: "Udruženje građana.")
        end

        test "a giving question leads with the foundation's own published record" do
          facts = read("Kako da doniram?", category: "organizacija")[:facts]

          assert_equal "partner_profile:#{@foundation.id}", facts.first["id"]
          assert_includes facts.first["text"], "račun"
        end

        test "a partner directory question is not reordered for the foundation" do
          facts = read("Koje organizacije su partneri?")[:facts]

          ids = facts.map { |fact| fact["id"] }

          assert_equal ["partner_profile:#{@other.id}", "partner_profile:#{@foundation.id}"], ids
        end

        # b2c30 / b2c31 asked which project to support and where the money went,
        # and were answered with the total raised. The allocation branch is the
        # approved-project family: with no approved project configured it is
        # honestly empty, and — the point of this test — it is NOT the partner
        # directory, which has two visible rows in this fixture.
        test "an allocation question reaches the project family and never the partner record" do
          result = read("Gdje mogu vidjeti kako se troše donacije i ko odlučuje o projektima?", category: "projekti")

          assert_equal "empty", result[:status]
          assert_empty result[:facts]
          assert_equal 2, read("Koje organizacije su partneri?")[:facts].length
        end

        test "no payment instruction reaches an allocation answer" do
          result = read("Mogu li prvo vidjeti projekte pa odabrati kome doniram?", category: "projekti")

          assert_no_match(/\bra[cč]un\b|\d{3}-\d{6,}/i, result[:facts].map { |fact| fact["text"] }.join(" "))
        end

        private

        def read(query, category: nil)
          entities = { "query" => query }
          entities["category"] = category if category
          @reader.call(topic: "community", entities:, context:, locale: "sr")
        end

        def context
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: @organization.id, conversation_key: "c" * 64, capabilities: ["public_reads"], now: Time.current
          )
        end

        def profile(**attributes)
          Decidim::Bih::PartnerProfile.create!(organization: @organization, slug: "p-#{SecureRandom.hex(4)}", kind: "association",
                                               verification_status: "verified", verified_at: Time.current, **attributes)
        end
      end
    end
  end
end
