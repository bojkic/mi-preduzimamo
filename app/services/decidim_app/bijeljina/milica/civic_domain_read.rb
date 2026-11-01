# frozen_string_literal: true

require "digest"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # Typed reads for the three domains task 8 added: heating network
      # coverage, billing and recycling. Every fact comes from
      # CivicDomainFacts — reviewed, dated, and never fetched inside a citizen
      # request.
      #
      # The shape of each answer is deliberate:
      #
      #   * Billing routes before it answers. Five bodies bill a Bijeljina
      #     household, so an unrouted billing question is `ambiguous` with the
      #     five candidates, not a guess at the likeliest one.
      #   * A blocked amount is an answer. The reply names the blocker, links
      #     the price list and gives the provider; it never quotes an undated
      #     example figure and never invents one.
      #   * A personal bill is refused by design, with the provider path. The
      #     authenticated provider URLs discovered during source review are
      #     recorded as exclusions and are never emitted.
      #   * Recycling never returns the mixed-waste collection day. Its
      #     container locations are a named blocker, and glass is reported as
      #     absent from the published list without asserting either direction.
      #   * "Is my house on the heating network?" is unmapped coverage, not an
      #     empty result and not a no.
      class CivicDomainRead
        include Read::Base

        # Matches the read port's own cap. It has to fit the worst real case -
        # a personal waste-bill question: boundary, three published facts, the
        # blocked tariff, the complaint route and the bank-account caveat.
        MAX_FACTS = 8
        # Machine-readable promise that a recycling question was not answered
        # from the mixed-waste calendar. Asserted by the regression tests.
        RECYCLING_SEPARATION = "recycling_not_regular_waste_schedule"

        def initialize(organization:)
          @organization = organization
        end

        def call(question:, context:, locale:)
          return not_authorized_result unless authorized?(context)

          values = case question.domain
                   when :billing then billing(question, context)
                   when :recycling then recycling(question, context)
                   when :heating_network then heating_network(context)
                   end
          return { status: "unavailable", warnings: ["unsupported_civic_domain"] } unless values

          values[:facts] = Array(values[:facts]).first(MAX_FACTS).each { |fact| fact["text"] = cyrillize(clean_text(fact.fetch("text"), limit: 900), locale:) }
          values
        rescue CivicDomainFacts::MissingDomain, Date::Error => e
          Rails.logger.warn("[CivicDomainRead] reviewed facts unavailable error_class=#{e.class.name}")
          { status: "unavailable", warnings: ["reviewed_civic_facts_unavailable"] }
        end

        private

        attr_reader :organization

        # ------------------------------------------------------------------
        # Billing
        # ------------------------------------------------------------------

        def billing(question, context)
          biller = question.biller && CivicDomainFacts.biller(question.biller)
          return billing_routing_required(context) unless biller

          blocker_facts = Array(biller["blockers"]).filter_map { |id| CivicDomainFacts.blocker("billing", id) }
          {
            status: "ok", facts: billing_facts(biller, question, blocker_facts), source: biller_source(biller), checked_at: nil,
            coverage: billing_coverage(biller, question),
            validity: billing_validity(biller, blocker_facts),
            warnings: billing_warnings(question, blocker_facts)
          }
        end

        # Order matters, because the list is capped. The boundary first when the
        # question was about the citizen's own amount, then the published facts,
        # then the missing amount, then where to go - and only then the
        # lower-severity caveats. A truncated list must never be the one that
        # lost the provider's phone number.
        def billing_facts(biller, question, blocker_facts)
          blocking, caveats = blocker_facts.partition { |blocker| blocker.severity == "high" }
          facts = []
          facts << personal_boundary_fact(biller) if question.focus == :personal
          facts.concat(CivicDomainFacts.biller_facts(biller.fetch("id")).map { |fact| billing_fact(fact, biller) })
          facts.concat(blocking.map { |blocker| blocker_fact(blocker, biller_source(biller), "billing_blocker") })
          facts << complaint_route_fact(biller) if biller["complaint_route"].present?
          facts.concat(caveats.map { |blocker| blocker_fact(blocker, biller_source(biller), "billing_blocker") })
          facts
        end

        def billing_warnings(question, blocker_facts)
          warnings = ["billing_is_not_an_outage_answer"]
          warnings.concat(CivicDomainFacts.domain("billing").fetch("personal_bill_boundary").fetch("warning_codes")) if question.focus == :personal
          warnings.concat(blocker_facts.map(&:id))
          warnings << "reviewed_amount_not_available" if blocker_facts.any? { |blocker| blocker.severity == "high" }
          warnings.uniq
        end

        def billing_routing_required(_context)
          candidates = CivicDomainFacts.billers.map do |biller|
            { "id" => biller.fetch("id"), "label" => biller.fetch("provider"), "kind" => "biller",
              "subject" => biller.fetch("subject") }
          end
          {
            status: "ambiguous", facts: [], candidates:,
            coverage: { "organization_id" => organization.id, "scope" => "billing_routing", "status" => "ambiguous",
                        "biller_count" => candidates.size },
            warnings: %w(billing_provider_required billing_is_not_an_outage_answer)
          }
        end

        def billing_coverage(biller, question)
          {
            "organization_id" => organization.id,
            "scope" => "reviewed_billing_process",
            "status" => "resolved",
            "biller" => biller.fetch("id"),
            "provider" => biller.fetch("provider"),
            "subject" => biller.fetch("subject"),
            "personal_data_scope" => question.focus == :personal ? "excluded_provider_account_required" : "not_requested"
          }
        end

        def billing_validity(biller, blocker_facts)
          amounts = CivicDomainFacts.biller_facts(biller.fetch("id")).map(&:source_on)
          {
            "live_status" => false,
            "reviewed_on" => CivicDomainFacts.reviewed_on("billing").iso8601,
            "amount_available" => blocker_facts.none? { |blocker| blocker.severity == "high" },
            "oldest_source_on" => amounts.min&.iso8601,
            "newest_source_on" => amounts.max&.iso8601
          }.compact
        end

        def personal_boundary_fact(biller)
          boundary = CivicDomainFacts.domain("billing").fetch("personal_bill_boundary")
          envelope(
            key: "personal_boundary:#{biller.fetch("id")}", kind: "billing_boundary",
            text: squish(boundary.fetch("text")), source: biller_source(biller),
            source_on: nil, reviewed_on: CivicDomainFacts.reviewed_on("billing"),
            warning_codes: boundary.fetch("warning_codes")
          )
        end

        def billing_fact(fact, biller)
          envelope(key: "#{biller.fetch("id")}:#{fact.id}", kind: "billing_fact", text: fact.text,
                   source: { "id" => "billing:#{biller.fetch("id")}", "label" => fact.source_label || biller.fetch("provider"), "url" => fact.source_url },
                   source_on: fact.source_on, reviewed_on: fact.reviewed_on, warning_codes: fact.warning_codes)
        end

        def complaint_route_fact(biller)
          envelope(key: "complaint:#{biller.fetch("id")}", kind: "billing_next_step", text: squish(biller.fetch("complaint_route")),
                   source: biller_source(biller), source_on: nil,
                   reviewed_on: CivicDomainFacts.reviewed_on("billing"), warning_codes: [])
        end

        def biller_source(biller)
          { "id" => "billing:#{biller.fetch("id")}", "label" => biller.fetch("provider"), "url" => biller.fetch("source_url") }
        end

        # ------------------------------------------------------------------
        # Recycling
        # ------------------------------------------------------------------

        def recycling(question, _context)
          scope = question.focus == :self_haul ? "self_haul" : nil
          facts = CivicDomainFacts.facts("recycling", scope:).map { |fact| domain_fact(fact, "recycling") }
          blockers = recycling_blockers(question.focus)
          facts.concat(blockers.map { |blocker| blocker_fact(blocker, recycling_source, "recycling_blocker") })
          facts.concat(CivicDomainFacts.next_steps("recycling").map { |step| next_step_fact(step, "recycling") })

          {
            status: "ok", facts:, source: recycling_source, checked_at: nil,
            coverage: {
              "organization_id" => organization.id, "scope" => "reviewed_recycling_service",
              # The provider statement is company-wide; nothing in it supports a
              # per-komšiluk or per-street recycling answer.
              "status" => question.focus == :location ? "unmapped" : "citywide_provider_statement",
              "container_locations_published" => false,
              "collected" => CivicDomainFacts.domain("recycling").fetch("recyclables_collected"),
              "glass_listed" => CivicDomainFacts.domain("recycling").fetch("glass_listed")
            },
            validity: { "live_status" => false, "reviewed_on" => CivicDomainFacts.reviewed_on("recycling").iso8601,
                        "glass_collection_known" => false, "container_locations_known" => false },
            warnings: ([RECYCLING_SEPARATION] + blockers.map(&:id)).uniq
          }
        end

        def recycling_blockers(focus)
          all = CivicDomainFacts.blockers("recycling")
          case focus
          when :location then all.select { |blocker| %w(container_locations_not_published no_what_goes_where_guide).include?(blocker.id) }
          when :glass then all.select { |blocker| %w(glass_collection_unstated container_locations_not_published).include?(blocker.id) }
          else all.select { |blocker| blocker.id == "no_what_goes_where_guide" }
          end
        end

        def recycling_source
          collector = CivicDomainFacts.domain("recycling").fetch("collector")
          { "id" => "recycling:komunalac", "label" => collector.fetch("name"), "url" => collector.fetch("source_url") }
        end

        # ------------------------------------------------------------------
        # Heating network coverage
        # ------------------------------------------------------------------

        def heating_network(_context)
          blocker = CivicDomainFacts.blocker("heating", "heating_network_footprint_not_published")
          facts = [blocker_fact(blocker, heating_source, "heating_blocker")]
          facts.concat(CivicDomainFacts.facts("heating").select { |fact| %w(heating_network_footprint_unknown heating_provider).include?(fact.id) }
                                       .map { |fact| domain_fact(fact, "heating") })
          {
            status: "ok", facts:, source: heating_source, checked_at: nil,
            coverage: { "organization_id" => organization.id, "scope" => "heating_network_footprint",
                        "status" => "unmapped", "network_footprint" => "not_published" },
            validity: { "live_status" => false, "household_coverage_known" => false,
                        "reviewed_on" => CivicDomainFacts.reviewed_on("heating").iso8601 },
            warnings: %w(heating_network_footprint_not_published coverage_unmapped)
          }
        end

        def heating_source
          provider = CivicDomainFacts.domain("heating").fetch("provider")
          { "id" => "heating:toplana", "label" => provider.fetch("name"), "url" => provider.fetch("source_url") }
        end

        # ------------------------------------------------------------------
        # Shared envelope
        # ------------------------------------------------------------------

        def domain_fact(fact, domain)
          envelope(key: "#{domain}:#{fact.id}", kind: "#{domain}_fact", text: fact.text,
                   source: { "id" => "#{domain}:#{fact.id}", "label" => fact.source_label, "url" => fact.source_url },
                   source_on: fact.source_on, reviewed_on: fact.reviewed_on, warning_codes: fact.warning_codes)
        end

        def blocker_fact(blocker, source, kind)
          envelope(key: "blocker:#{blocker.id}", kind:, text: blocker.text, source:,
                   source_on: nil, reviewed_on: reviewed_on_for(kind), warning_codes: [blocker.id, "reviewed_fact_not_available"])
        end

        def next_step_fact(step, domain)
          envelope(key: "next_step:#{step.fetch("id")}", kind: "#{domain}_next_step", text: step.fetch("text"),
                   source: { "id" => "#{domain}:#{step.fetch("id")}", "label" => nil, "url" => step["source_url"] },
                   source_on: nil, reviewed_on: CivicDomainFacts.reviewed_on(domain), warning_codes: [])
        end

        def reviewed_on_for(kind)
          CivicDomainFacts.reviewed_on(kind.to_s.split("_").first)
        end

        # Every fact carries both dates on purpose: the date of the publication
        # or decision it rests on, and the date it was reviewed. Neither is
        # allowed to become an implied "as of today".
        def envelope(key:, kind:, text:, source:, source_on:, reviewed_on:, warning_codes:) # rubocop:disable Metrics/ParameterLists
          {
            "id" => "#{kind}:#{Digest::SHA256.hexdigest(key)[0, 16]}",
            "kind" => kind,
            "text" => text,
            "source_id" => source.fetch("id"),
            "source_label" => source["label"],
            "source_url" => source["url"],
            "source_published_on" => source_on&.iso8601,
            "reviewed_on" => reviewed_on.iso8601,
            "warning_codes" => Array(warning_codes).map(&:to_s)
          }.compact
        end

        def squish(value)
          value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
        end
      end
    end
  end
end
