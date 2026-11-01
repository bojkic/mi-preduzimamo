# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Aggregate, PII-free campaign read model. It intentionally reports proposal
    # ids/titles and per-area counts, never participant names, user ids, phone
    # hashes, addresses, coordinates or membership lists.
    class KomsilukNamingCampaignMetrics
      CAMPAIGN = KomsilukNamingCampaign
      PERSONAL_PRIZE_MINIMUM_VOTERS = 10
      EMPTY_IDS = Set.new.freeze

      def self.call(organization:)
        new(organization:).call
      end

      def initialize(organization:)
        @organization = organization
      end

      def call
        raise "Komšiluk naming campaign component is not configured" unless component

        rows = areas.map { |area| row_for(area) }
        best_participation = rows.map { |row| row[:verified_active_participants] }.max.to_i

        {
          process_slug: CAMPAIGN::PROCESS_SLUG,
          generated_at: Time.current.iso8601,
          primary_kpi: "unique SMS-verified participants with a valid proposal or final vote",
          totals: totals(rows),
          community_prize_leaders: best_participation.positive? ? rows.filter_map { |row| row[:area_slug] if row[:verified_active_participants] == best_participation } : [],
          personal_prize_shortlist: personal_prize_shortlist(rows),
          areas: rows
        }
      end

      private

      attr_reader :organization

      def component
        @component ||= CAMPAIGN.component_for(organization)
      end

      def areas
        @areas ||= Decidim::Bih::LocalArea
                   .komsiluci
                   .where(decidim_organization_id: organization.id)
                   .to_a
                   .sort_by { |area| area.slug.delete_prefix("komsiluk-").to_i }
      end

      def row_for(area)
        taxonomy_id = CAMPAIGN.taxonomy_id_for_area(area)
        area_proposals = proposals_by_taxonomy.fetch(taxonomy_id, [])
        voter_ids = area_proposals.flat_map { |proposal| voter_ids_by_proposal.fetch(proposal.id, EMPTY_IDS).to_a }.to_set
        proposer_ids = area_proposals.flat_map { |proposal| proposer_ids_by_proposal.fetch(proposal.id, EMPTY_IDS).to_a }.to_set
        assigned_ids = assigned_user_ids_by_area.fetch(area.id, Set.new)
        eligible_ids = assigned_ids & sms_verified_user_ids
        valid_voter_ids = voter_ids & eligible_ids
        valid_proposer_ids = proposer_ids & eligible_ids
        verified_active_ids = valid_voter_ids | valid_proposer_ids
        top_proposals = top_proposals_for(area_proposals, eligible_ids)

        {
          area_slug: area.slug,
          area_name: area.name["sr"] || area.slug,
          assigned_members: assigned_ids.size,
          sms_verified_members: eligible_ids.size,
          citizen_proposals: area_proposals.count { |proposal| proposer_ids_by_proposal.fetch(proposal.id, EMPTY_IDS).intersect?(eligible_ids) },
          final_votes: area_proposals.sum { |proposal| (voter_ids_by_proposal.fetch(proposal.id, EMPTY_IDS) & eligible_ids).size },
          unique_voters: valid_voter_ids.size,
          verified_active_participants: verified_active_ids.size,
          top_proposals:
        }
      end

      def valid_proposals
        @valid_proposals ||= Decidim::Proposals::Proposal
                             .where(component:)
                             .published
                             .not_hidden
                             .not_withdrawn
                             .includes(:taxonomies)
                             .reject(&:rejected?)
      end

      def proposals_by_taxonomy
        @proposals_by_taxonomy ||= valid_proposals.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |proposal, grouped|
          taxonomy_id = CAMPAIGN.taxonomy_id_for_resource(proposal)
          grouped[taxonomy_id] << proposal if taxonomy_id
        end
      end

      def voter_ids_by_proposal
        @voter_ids_by_proposal ||= Decidim::Proposals::ProposalVote
                                   .final
                                   .where(decidim_proposal_id: valid_proposals.map(&:id))
                                   .pluck(:decidim_proposal_id, :decidim_author_id)
                                   .each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |(proposal_id, user_id), grouped|
          grouped[proposal_id] << user_id
        end
      end

      def proposer_ids_by_proposal
        @proposer_ids_by_proposal ||= Decidim::Coauthorship
                                      .where(
                                        coauthorable_type: "Decidim::Proposals::Proposal",
                                        coauthorable_id: valid_proposals.map(&:id),
                                        decidim_author_type: "Decidim::UserBaseEntity"
                                      )
                                      .pluck(:coauthorable_id, :decidim_author_id)
                                      .each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |(proposal_id, user_id), grouped|
          grouped[proposal_id] << user_id
        end
      end

      def sms_verified_user_ids
        @sms_verified_user_ids ||= Decidim::Authorization
                                   .joins(:user)
                                   .where(
                                     name: "sms",
                                     decidim_users: { decidim_organization_id: organization.id }
                                   )
                                   .where.not(granted_at: nil)
                                   .pluck(:decidim_user_id)
                                   .to_set
      end

      def assigned_user_ids_by_area
        @assigned_user_ids_by_area ||= Decidim::Bih::CitizenProfile
                                       .where(organization:)
                                       .where.not(komsiluk_id: nil)
                                       .where.not(decidim_user_id: nil)
                                       .pluck(:komsiluk_id, :decidim_user_id)
                                       .each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |(area_id, user_id), grouped|
          grouped[area_id] << user_id
        end
      end

      def top_proposals_for(proposals, eligible_ids)
        ranked = proposals.map do |proposal|
          {
            proposal_id: proposal.id,
            title: proposal.title["sr"] || proposal.title.values.compact.first,
            votes: (voter_ids_by_proposal.fetch(proposal.id, EMPTY_IDS) & eligible_ids).size,
            citizen_authored: proposer_ids_by_proposal.fetch(proposal.id, EMPTY_IDS).intersect?(eligible_ids)
          }
        end
        ranked.sort_by! { |candidate| [-candidate[:votes], candidate[:proposal_id]] }

        top_votes = ranked.first&.fetch(:votes, nil)
        return [] unless top_votes

        ranked.take_while { |candidate| candidate[:votes] == top_votes }
      end

      def totals(rows)
        {
          areas: rows.size,
          areas_with_activity: rows.count { |row| row[:verified_active_participants].positive? },
          assigned_members: rows.sum { |row| row[:assigned_members] },
          sms_verified_members: rows.sum { |row| row[:sms_verified_members] },
          citizen_proposals: rows.sum { |row| row[:citizen_proposals] },
          final_votes: rows.sum { |row| row[:final_votes] },
          verified_active_participants: rows.sum { |row| row[:verified_active_participants] }
        }
      end

      # Raw vote totals across differently sized Komšiluci are not comparable.
      # The shortlist therefore uses each local winner's share of that area's
      # final votes and requires a minimum local electorate. It remains a
      # shortlist: LFBN must apply the published tie/jury rule before awarding.
      def personal_prize_shortlist(rows)
        candidates = rows.filter_map do |row|
          next if row[:unique_voters] < PERSONAL_PRIZE_MINIMUM_VOTERS

          row[:top_proposals].filter_map do |proposal|
            next unless proposal[:citizen_authored]

            proposal.merge(
              area_slug: row[:area_slug],
              vote_share: (proposal[:votes].to_f / row[:unique_voters]).round(4)
            )
          end
        end.flatten

        best_share = candidates.map { |candidate| candidate[:vote_share] }.max
        return [] unless best_share

        candidates.select { |candidate| candidate[:vote_share] == best_share }
      end
    end
  end
end
