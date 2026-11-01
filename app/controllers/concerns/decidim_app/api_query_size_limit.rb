# frozen_string_literal: true

module DecidimApp
  # graphql-ruby has no query-string size limit; depth, complexity, aliases and
  # recursion are already bounded by Decidim::Api::Schema. Cap the document
  # itself so a huge query is refused before it is parsed. The standard
  # introspection query is ~1.5 KB, so this leaves wide headroom.
  module ApiQuerySizeLimit
    MAX_QUERY_BYTES = 20_000

    def create
      return super if params[:query].to_s.bytesize <= MAX_QUERY_BYTES

      render json: { errors: [{ message: "Query is too large" }] }, status: :payload_too_large
    end
  end
end
