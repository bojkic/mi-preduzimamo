# frozen_string_literal: true

require "date"
require "uri"
require "yaml"

module DecidimApp
  module Bijeljina
    # Reviewed, dated facts for the three civic domains added by task 8:
    # heating, billing and recycling. This is DATA plus its provenance, not
    # machinery — the readers in DecidimApp::Bijeljina::Milica turn it into
    # answers.
    #
    # Three properties are load-bearing and are enforced here rather than
    # trusted to every call site:
    #
    #   * A fact with `publishable: false` is retained as evidence and is never
    #     returned to a caller. That is how the heating duty-technician number
    #     from 2023 stays on file without being read out as current.
    #   * Every published fact carries both the date of the publication or
    #     decision it rests on (`source_on`) and the date it was last reviewed
    #     (`reviewed_on`). There is no implied "as of today".
    #   * A blocker is a first-class answer. `blockers` are loaded, addressable
    #     by id, and rendered; they are not a to-do list hidden from citizens.
    #
    # Freshness for these domains never comes from an HTTP header: the provider
    # hosts send Last-Modified equal to the request time or send none at all
    # (see HTTP_FRESHNESS_UNUSABLE_HOSTS in CityServiceSources). It comes from
    # the date inside the content plus a content hash.
    module CivicDomainFacts
      DOMAINS = %w(heating billing recycling).freeze
      CONFIG_DIR = ENV.fetch("MI_CIVIC_FACTS_DIR", "").freeze
      REQUIRED_FACT_KEYS = %w(id text source_url reviewed_on source_on).freeze
      # A reviewed fact may cite only a host an operator reviewed. Adding a host
      # here is part of reviewing it, not a formality: MIlica links these URLs.
      REFERENCE_REVIEWED_HOSTS = %w(
        www.gradskatoplanabijeljina.com www.komunalacbn.com www.bnvodovod.com
        elektrobijeljina.com www.gradbijeljina.org www.ekodep.com
      ).freeze

      REVIEWED_HOSTS = ENV.fetch("MI_CIVIC_REVIEWED_HOSTS", "").split(",").map { |host| host.strip.downcase }.reject(&:empty?).freeze

      class MissingDomain < KeyError; end

      Fact = Struct.new(:id, :text, :source_url, :source_label, :source_on, :reviewed_on, :warning_codes, :only_for, keyword_init: true) do
        def to_h_for_read
          { "id" => id, "text" => text, "source_url" => source_url, "source_label" => source_label,
            "source_on" => source_on.iso8601, "reviewed_on" => reviewed_on.iso8601,
            "warning_codes" => warning_codes }
        end
      end

      Blocker = Struct.new(:id, :severity, :question, :text, :unblock, keyword_init: true)

      class << self
        def domain(name)
          key = name.to_s
          raise MissingDomain, "unknown civic domain: #{key}" unless DOMAINS.include?(key)

          cache[key] ||= load_domain(key)
        end

        def reviewed_on(name)
          Date.iso8601(domain(name).fetch("reviewed_on"))
        end

        def revision(name)
          domain(name).fetch("revision")
        end

        # Publishable facts only. An unpublishable row never leaves this module.
        # `scope` admits the facts a reader has earned: a row marked
        # `only_for: self_haul` is withheld until the citizen actually asks
        # about taking the waste to the landfill themselves.
        def facts(name, scope: nil)
          Array(domain(name)["facts"]).select { |row| row["publishable"] && in_scope?(row, scope) }.map { |row| build_fact(row) }
        end

        def fact(name, id)
          facts(name, scope: :all).find { |row| row.id == id.to_s }
        end

        # Ids present in the file but withheld from every answer. Exposed so a
        # test can prove the withholding rather than trust it.
        def retained_fact_ids(name)
          Array(domain(name)["facts"]).reject { |row| row["publishable"] }.map { |row| row.fetch("id") }
        end

        def blockers(name)
          Array(domain(name)["blockers"]).map do |row|
            Blocker.new(id: row.fetch("id"), severity: row.fetch("severity", "medium"), question: row["question"],
                        text: squish(row.fetch("text")), unblock: squish(row["unblock"]))
          end
        end

        def blocker(name, id)
          blockers(name).find { |row| row.id == id.to_s }
        end

        def next_steps(name)
          Array(domain(name)["next_steps"]).map do |row|
            { "id" => row.fetch("id"), "text" => squish(row.fetch("text")), "source_url" => row["source_url"] }
          end
        end

        # Billing is five separate billers, so it is the one domain whose facts
        # hang off a routing key rather than off the domain.
        def billers
          Array(domain("billing").fetch("billers"))
        end

        def biller(id)
          billers.find { |row| row.fetch("id") == id.to_s }
        end

        def biller_facts(id)
          Array(biller(id)&.fetch("facts", [])).select { |row| row["publishable"] }.map { |row| build_fact(row) }
        end

        def excluded_authenticated_paths
          Array(domain("billing")["excluded_authenticated_paths"])
        end

        # A path we have promised never to fetch. Kept as a predicate so a test
        # can assert the promise instead of trusting a comment.
        def excluded_authenticated_path?(url)
          value = url.to_s.strip
          return false if value.empty?

          excluded_authenticated_paths.any? { |path| value.start_with?(path) }
        end

        def reset!
          @cache = nil
        end

        private

        def cache
          @cache ||= {}
        end

        def load_domain(key)
          raise MissingDomain, "community civic sources are not configured" if CONFIG_DIR.empty?

          path = File.join(CONFIG_DIR, "#{key}_reviewed_facts.yml")
          data = YAML.safe_load_file(path)
          raise MissingDomain, "civic domain file is not a mapping: #{path}" unless data.is_a?(Hash)
          raise MissingDomain, "civic domain mismatch in #{path}" unless data["domain"] == key

          validate!(data, path)
          deep_freeze(data)
        end

        def validate!(data, path)
          Date.iso8601(data.fetch("reviewed_on"))
          rows = Array(data["facts"]) + Array(data["billers"]).flat_map { |biller| Array(biller["facts"]) }
          rows.each do |row|
            missing = REQUIRED_FACT_KEYS.reject { |field| row[field].present? }
            raise MissingDomain, "fact #{row["id"].inspect} in #{path} is missing #{missing.join(", ")}" if missing.any?

            Date.iso8601(row.fetch("source_on"))
            Date.iso8601(row.fetch("reviewed_on"))
            reviewed_host!(row.fetch("source_url"), row.fetch("id"), path)
          end
        end

        def reviewed_host!(url, id, path)
          uri = URI.parse(url.to_s)
          raise MissingDomain, "fact #{id.inspect} in #{path} must cite an https URL" unless uri.scheme == "https" && uri.userinfo.nil? && uri.port == 443
          raise MissingDomain, "fact #{id.inspect} in #{path} cites unreviewed host #{uri.host}" unless REVIEWED_HOSTS.include?(uri.host.to_s.downcase)
        rescue URI::InvalidURIError
          raise MissingDomain, "fact #{id.inspect} in #{path} has an invalid source URL"
        end

        def in_scope?(row, scope)
          return true if scope.to_s == "all"

          marker = row["only_for"].to_s
          marker.empty? || marker == scope.to_s
        end

        def build_fact(row)
          Fact.new(
            id: row.fetch("id"), text: squish(row.fetch("text")), source_url: row.fetch("source_url"),
            source_label: row["source_label"], source_on: Date.iso8601(row.fetch("source_on")),
            reviewed_on: Date.iso8601(row.fetch("reviewed_on")),
            warning_codes: Array(row["warning_codes"]).map(&:to_s), only_for: row["only_for"]
          )
        end

        def squish(value)
          return if value.nil?

          value.to_s.gsub(/[[:space:]\u00a0]+/, " ").strip
        end

        def deep_freeze(value)
          case value
          when Hash then value.each { |_key, item| deep_freeze(item) }.freeze
          when Array then value.each { |item| deep_freeze(item) }.freeze
          else value.freeze
          end
        end
      end
    end
  end
end
