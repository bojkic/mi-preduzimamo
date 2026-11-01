# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "uri"

module DecidimApp
  module Bijeljina
    module Milica
      # Pure public-data manifest. Callers supply allowlisted projections, never
      # arbitrary database rows. Exclusions deliberately contain no source text.
      class KnowledgeManifest
        VERSION = 1
        REQUIRED = %w(document_id organization_id domain public source_id source_url title language body review_status
                      reviewed_at review_expires_at authority_kind source_locator coverage limitations
                      published_at observed_at effective_from effective_until source_revision approval_basis).freeze
        OPTIONAL = %w(subject_id occurs_from occurs_until review_proof eligibility end_exclusive).freeze
        Invalid = Class.new(ArgumentError)

        def initialize(organization_id:, as_of:, token_counter: nil, tokenizer: nil)
          raise Invalid, "positive organization required" unless organization_id.is_a?(Integer) && organization_id.positive?
          raise Invalid, "explicit Date required" unless as_of.instance_of?(Date)

          validate_tokenizer!(token_counter, tokenizer)

          @organization_id = organization_id
          @as_of = as_of
          @counter = token_counter
          @tokenizer = tokenizer
        end

        def build(records:, inventory:)
          raise Invalid, "records and inventory must be object arrays" unless [records, inventory].all? { |items| items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) } }

          excluded = []
          eligible = eligible_records(records, excluded)
          documents = deduplicate(eligible, excluded)
          report = {
            "schema_version" => VERSION, "organization_id" => @organization_id, "as_of" => @as_of.iso8601,
            "scope" => "public_filesystem_projection_not_complete_live_inventory",
            "complete" => false, "runtime_eligibility_recheck_required" => true,
            "token_measurement" => @counter ? { "status" => "exact", **@tokenizer } : { "status" => "unknown", "reason" => "no_tokenizer_supplied" },
            "release_id" => digest(documents), "documents" => documents, "excluded" => excluded,
            "duplicate_revisions_removed" => duplicate_count(eligible, documents, excluded),
            "totals" => metrics(documents),
            "domains" => domain_metrics(records, inventory, documents, excluded),
            "largest_complete_projected_document" => largest_document(documents)
          }
          freeze_tree(canonical(report))
        end

        # Same serialization measured as prompt input. Metadata and limitations
        # travel with every body; a consumer must not retrieve bare prose alone.
        def prompt_for(documents)
          JSON.generate(canonical(documents))
        end

        private

        def validate_tokenizer!(counter, tokenizer)
          if counter && (!tokenizer.is_a?(Hash) || %w(model tokenizer version).any? { |key| tokenizer[key].to_s.empty? })
            raise Invalid, "exact counter requires model, tokenizer and version"
          end
          raise Invalid, "tokenizer without counter" if tokenizer && !counter
        end

        def eligible_records(records, excluded)
          records.filter_map do |record|
            reason = exclusion(record)
            if reason
              rejected = { "document_id" => record["document_id"], "domain" => record["domain"], "reason" => reason }
              rejected["missing_fields"] = REQUIRED - record.keys if reason == "missing_required_fields"
              excluded << rejected
              next
            end
            normalized = canonical(record.slice(*(REQUIRED + OPTIONAL)))
            normalized.merge("revision" => digest(normalized), "content_hash" => Digest::SHA256.hexdigest(record.fetch("body")))
          end
        end

        def deduplicate(eligible, excluded)
          eligible.group_by { |row| row.fetch("document_id") }.sort.flat_map do |id, versions|
            if versions.map { |row| row.fetch("revision") }.uniq.size > 1
              excluded << { "document_id" => id, "domain" => versions.first["domain"], "reason" => "conflicting_document_revisions" }
              []
            else
              [versions.first]
            end
          end
        end

        def duplicate_count(eligible, documents, excluded)
          conflicted = excluded.select { |row| row["reason"] == "conflicting_document_revisions" }.map { |row| row["document_id"] }
          eligible.size - documents.size - eligible.count { |row| conflicted.include?(row["document_id"]) }
        end

        def domain_metrics(records, inventory, documents, excluded)
          domains = (inventory.map { |row| row.fetch("domain") } + records.map { |row| row.fetch("domain") }).uniq.sort
          domains.to_h do |domain| # rubocop:disable Rails/IndexWith -- standalone Ruby value object
            [domain, { "metrics" => metrics(documents.select { |row| row["domain"] == domain }),
                       "inventory" => inventory.select { |row| row["domain"] == domain },
                       "excluded_count" => excluded.count { |row| row["domain"] == domain } }]
          end
        end

        def exclusion(row)
          shape_exclusion(row) || authority_exclusion(row) || identity_exclusion(row) || time_exclusion(row)
        rescue ArgumentError, TypeError, URI::InvalidURIError
          "invalid_source_metadata"
        end

        def shape_exclusion(row)
          return "missing_required_fields" unless row.is_a?(Hash) && (REQUIRED - row.keys).empty?

          "unexpected_fields" unless (row.keys - REQUIRED - OPTIONAL).empty?
        end

        def authority_exclusion(row)
          return "not_public" unless row["public"] == true
          return "organization_mismatch" unless row["organization_id"] == @organization_id
          return "revoked" if row["review_status"] == "revoked"
          return "unreviewed" unless row["review_status"] == "reviewed"

          row["eligibility"] if row["eligibility"] && row["eligibility"] != "ready"
        end

        def identity_exclusion(row)
          keys = %w(document_id domain source_id title language body authority_kind source_locator source_revision approval_basis)
          return "missing_identity_or_prose" if keys.any? { |key| !row[key].is_a?(String) || row[key].strip.empty? }
          return "missing_source_qualifiers" unless row["coverage"].is_a?(Hash) && row["limitations"].is_a?(Array)

          source_url_exclusion(row)
        end

        def source_url_exclusion(row)
          uri = URI.parse(row["source_url"].to_s)
          "unsafe_source_url" unless uri.scheme == "https" && uri.host && !uri.userinfo && !uri.fragment.to_s.match?(/[\r\n]/)
        end

        def time_exclusion(row)
          review_exclusion(row) || effective_exclusion(row) || source_clock_exclusion(row)
        end

        def review_exclusion(row)
          reviewed = Date.iso8601(row.fetch("reviewed_at"))
          return "future_review" if reviewed > @as_of

          expiry = row["review_expires_at"] && Date.iso8601(row["review_expires_at"])
          "review_expired" if expiry && @as_of >= expiry
        end

        def effective_exclusion(row)
          start = row["effective_from"] && Date.iso8601(row["effective_from"])
          finish = row["effective_until"] && Date.iso8601(row["effective_until"])
          return "not_yet_effective" if start && start > @as_of

          "expired" if finish && (row["end_exclusive"] == false ? @as_of > finish : @as_of >= finish)
        end

        def source_clock_exclusion(row)
          %w(published_at observed_at occurs_from occurs_until).each { |key| Date.iso8601(row[key]) if row[key] }
          "future_source_clock" if %w(published_at observed_at).any? { |key| row[key] && Date.iso8601(row[key]) > @as_of }
        end

        def metrics(documents)
          bodies = documents.map { |row| row.fetch("body") }
          body = bodies.join("\n\n")
          prompt = prompt_for(documents)
          counts = { "documents" => documents.size, "body_bytes" => body.bytesize, "body_words" => body.split.size,
                     "deduplicated_prose_words" => bodies.uniq.join("\n\n").split.size,
                     "prompt_bytes" => prompt.bytesize, "prompt_overhead_bytes" => prompt.bytesize - body.bytesize,
                     "body_tokens" => nil, "prompt_tokens" => nil, "prompt_overhead_tokens" => nil }
          if @counter
            counts["body_tokens"] = count(body)
            counts["prompt_tokens"] = count(prompt)
            counts["prompt_overhead_tokens"] = counts["prompt_tokens"] - counts["body_tokens"]
          end
          counts
        end

        def largest_document(documents)
          row = documents.max_by { |item| prompt_for([item]).bytesize }
          return nil unless row

          { "document_id" => row.fetch("document_id"), "metrics" => metrics([row]),
            "scope" => "complete_projected_record_not_complete_publisher_document" }
        end

        def count(text)
          value = @counter.call(text)
          raise Invalid, "token counter must return a nonnegative Integer" unless value.is_a?(Integer) && value >= 0

          value
        end

        def canonical(value)
          case value
          when Hash then value.sort.to_h.transform_values { |item| canonical(item) }
          when Array then value.map { |item| canonical(item) }
          when String then value.dup
          else value
          end
        end

        def digest(value) = Digest::SHA256.hexdigest(JSON.generate(canonical(value)))

        def freeze_tree(value)
          case value
          when Hash then value.each do |key, item|
            freeze_tree(key)
            freeze_tree(item)
          end
          when Array then value.each { |item| freeze_tree(item) }
          end
          value.freeze
        end
      end
    end
  end
end
