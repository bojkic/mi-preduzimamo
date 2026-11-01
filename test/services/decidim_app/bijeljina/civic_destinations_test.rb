# frozen_string_literal: true

require "test_helper"
# Resolving a component path goes through Decidim::UrlOptionResolver, which
# reads Capybara.server_port in the test environment: without this the lookup
# raises NameError, CivicDestinations rescues it, and the case silently
# measures the process-page fallback instead of the component path.
require "capybara"

module DecidimApp
  module Bijeljina
    # "Gdje da predam prijedlog?" returned the foundation's partner profile,
    # including its donation account and IBAN. The reviewed card that now
    # answers it needs a destination, and the destination is a database fact:
    # the flagship process's published proposals component.
    class CivicDestinationsTest < ActiveSupport::TestCase
      setup do
        @prior_process_slug = Decidim::Bih.flagship_process_slug
        Decidim::Bih.flagship_process_slug = "authored-proposals"
      end

      teardown do
        Decidim::Bih.flagship_process_slug = @prior_process_slug
      end

      test "an unconfigured process cannot invent a proposal destination" do
        Decidim::Bih.flagship_process_slug = nil
        assert_nil CivicDestinations.proposal_path
        assert_nil Decidim::Bih.proposal_path.call
      end

      test "a blank configured process cannot invent a proposal destination" do
        Decidim::Bih.flagship_process_slug = "  "
        assert_nil CivicDestinations.proposal_path
        assert_nil Decidim::Bih.proposal_path.call
      end
      test "the proposals component wins when it is published" do
        organization = create_organization
        process = Decidim::ParticipatoryProcess.create!(
          organization:, slug: Decidim::Bih.flagship_process_slug,
          title: { "sr" => "Ti se pitaš" }, subtitle: { "sr" => "Prijedlozi" },
          short_description: { "sr" => "Kratko" }, description: { "sr" => "Opis" },
          start_date: Date.current, published_at: Time.current
        )
        component = Decidim::Component.create!(
          participatory_space: process, manifest_name: "proposals",
          name: { "sr" => "Prijedlozi" }, published_at: Time.current
        )

        path = CivicDestinations.proposal_path

        assert_includes path, "/processes/#{process.slug}"
        assert_includes path, "/f/#{component.id}/"
      end

      test "an unpublished component falls back to the process page, never to nothing useful" do
        assert_equal "/processes/#{Decidim::Bih.flagship_process_slug}", CivicDestinations.proposal_path
      end

      test "the engine reads the path through the host accessor" do
        provider = Decidim::Bih.proposal_path

        assert_respond_to provider, :call
        assert_equal CivicDestinations.proposal_path, provider.call
        assert provider.call.start_with?("/"), "a destination must be a path"
      end
    end
  end
end
