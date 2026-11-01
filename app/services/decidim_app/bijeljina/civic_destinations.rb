# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # WHERE A CITIZEN IS SENT for the civic actions Milica explains but never
    # performs. Today that is one destination: the live proposals component.
    #
    # "Gdje da predam prijedlog?" was answered with 1.298 characters of the
    # foundation's partner profile, including its published donation account
    # and IBAN — a payment instruction in answer to a proposal question. The
    # engine now has a reviewed card for it, and the card needs a path.
    #
    # Resolved PER TURN rather than at boot, because the component id is a
    # database fact: a republished component changes it, and an initializer
    # would have cached the stale one. Resolution is defensive at every step —
    # a failure returns nil and the engine declines the card rather than
    # pointing a citizen at a page that may not accept a proposal.
    module CivicDestinations
      module_function

      # The flagship process's published proposals component, its process page
      # as a fallback, or nil.
      def proposal_path
        component_path("proposals") || process_path
      end

      def component_path(manifest_name)
        process = flagship_process
        return unless process

        component = process.components.published.find_by(manifest_name:)
        return unless component

        Decidim::EngineRouter.main_proxy(component).root_path
      rescue StandardError
        nil
      end

      def process_path
        slug = process_slug
        slug.empty? ? nil : "/processes/#{slug}"
      end

      def flagship_process
        slug = process_slug
        return if slug.empty?

        Decidim::ParticipatoryProcess.published.find_by(slug:)
      rescue StandardError
        nil
      end

      def process_slug = Decidim::Bih.flagship_process_slug.to_s.strip
    end
  end
end
