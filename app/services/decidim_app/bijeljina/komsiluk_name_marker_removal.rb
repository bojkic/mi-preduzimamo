# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Removes the "(prijedlog)" marker from komšiluk names.
    #
    # It was added so a citizen would know the name is not final. In practice it
    # read as part of the name — "Komšiluk 55 · Dazdarevo (prijedlog)" — and
    # appeared beside every alert, post and leaderboard row, which is more
    # confusing than the uncertainty it was trying to convey.
    #
    # Every komsiluk name is provisional at this point, so the marker records
    # nothing a list of komsiluci would not already tell you. The naming
    # campaign will set the real names later.
    class KomsilukNameMarkerRemoval
      Result = Struct.new(:renamed, :skipped, keyword_init: true)

      def initialize(organization:)
        @organization = organization
      end

      def call(apply: false)
        renamed = []
        skipped = []

        areas.each do |area|
          stripped = stripped_name(area)
          next if stripped == area.name

          if stripped.values.any?(&:blank?)
            skipped << area.slug
            next
          end

          renamed << area.slug
          next unless apply

          area.update!(name: stripped)
        end

        Result.new(renamed: renamed.sort, skipped: skipped.sort)
      end

      private

      attr_reader :organization

      def areas
        Decidim::Bih::LocalArea.where(decidim_organization_id: organization.id).order(:slug)
      end

      # One definition of what the marker is: PlaceAliasRegistry already had to
      # strip it for Milica, and it knows every spelling the operators used
      # (Latin and Cyrillic, parenthesised or bare).
      def stripped_name(area)
        area.name.to_h.transform_values { |value| PlaceAliasRegistry.display_name(value) }
      end
    end
  end
end
