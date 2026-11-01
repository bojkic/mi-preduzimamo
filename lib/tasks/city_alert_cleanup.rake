# frozen_string_literal: true

namespace :mi do
  namespace :komsiluk do
    desc "Remove the \"(prijedlog)\" marker from komšiluk names, keeping the provisional fact in metadata (HOST=..., APPLY=1 to write)"
    task remove_name_marker: :environment do
      organization = Decidim::Organization.find_by!(host: ENV.fetch("HOST"))
      apply = ENV["APPLY"] == "1"
      result = DecidimApp::Bijeljina::KomsilukNameMarkerRemoval.new(organization:).call(apply:)
      puts JSON.generate(apply:, renamed: result.renamed.size, slugs: result.renamed, skipped: result.skipped)
      puts "dry run - re-run with APPLY=1 to write" unless apply
      puts "#{result.skipped.size} name(s) were nothing but the marker and were left as they are" if result.skipped.any?
    end
  end

  namespace :city_alerts do
    desc "Collapse unreviewed re-observation duplicates onto the newest row (HOST=..., APPLY=1 to write)"
    task collapse_reobservation_duplicates: :environment do
      organization = Decidim::Organization.find_by!(host: ENV.fetch("HOST"))
      apply = ENV["APPLY"] == "1"
      result = DecidimApp::Bijeljina::CityServiceReobservationCleanup.new(organization:).call(apply:)
      puts JSON.generate(apply:, groups: result.groups, kept: result.kept_ids, collapsed: result.collapsed_ids)
      puts "dry run - re-run with APPLY=1 to supersede them" unless apply
    end

    desc "Bring already-published board text into line with the corrected wording (HOST=..., APPLY=1 to write)"
    task backfill_board_text: :environment do
      organization = Decidim::Organization.find_by!(host: ENV.fetch("HOST"))
      apply = ENV["APPLY"] == "1"
      result = DecidimApp::Bijeljina::CityServiceBoardTextBackfill.new(organization:).call(apply:)
      puts JSON.generate(apply:, events: result.events_rewritten, posts: result.posts_rewritten, skipped: result.skipped)
      puts "dry run - re-run with APPLY=1 to write" unless apply
      puts "#{result.skipped.size} board post(s) were edited away from their notice and were left untouched" if result.skipped.any?
    end

    desc "Re-key rows onto the fact-derived content version (HOST=..., APPLY=1 to write)"
    task backfill_fact_versions: :environment do
      organization = Decidim::Organization.find_by!(host: ENV.fetch("HOST"))
      apply = ENV["APPLY"] == "1"
      result = DecidimApp::Bijeljina::CityServiceFactVersionBackfill.new(organization:).call(apply:)
      puts JSON.generate(apply:, rekeyed: result.rekeyed_ids, unchanged: result.skipped_ids.size, collisions: result.collisions)
      puts "dry run - re-run with APPLY=1 to write" unless apply
      abort "collisions remain; collapse duplicates first" if result.collisions.any?
    end
  end
end
