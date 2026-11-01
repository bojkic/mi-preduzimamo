# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Shared lookup and eligibility rules for the Bijeljina Komšiluk naming
    # campaign. Decidim owns proposals, taxonomies and votes; this class only
    # connects those records to the private CitizenProfile assignment.
    #
    # The mapping is stored in the organization-scoped Setting table. It contains
    # only public reference-data ids (area slug -> taxonomy id), never a citizen
    # address, coordinate, phone number or membership list.
    class KomsilukNamingCampaign
      PROCESS_SLUG = "imenujmo-komsiluke"
      SETTINGS_NAMESPACE = "komsiluk_naming_campaign"
      COMPONENT_ID_KEY = "component_id"
      ROOT_TAXONOMY_ID_KEY = "root_taxonomy_id"
      TAXONOMY_FILTER_ID_KEY = "taxonomy_filter_id"
      AREA_TAXONOMY_PREFIX = "area_taxonomy."
      INITIAL_PROPOSAL_PREFIX = "initial_proposal."

      class << self
        def component?(component)
          component&.manifest_name == "proposals" &&
            component.participatory_space_type == "Decidim::ParticipatoryProcess" &&
            component.participatory_space&.slug == PROCESS_SLUG
        end

        def component_for(organization)
          configured_id = settings_for(organization)[COMPONENT_ID_KEY].to_i
          configured = Decidim::Component.find_by(id: configured_id) if configured_id.positive?
          return configured if configured&.organization == organization && component?(configured)

          process = Decidim::ParticipatoryProcess.find_by(organization:, slug: PROCESS_SLUG)
          process&.components&.find_by(manifest_name: "proposals")
        end

        def process_for(organization)
          Decidim::ParticipatoryProcess.find_by(organization:, slug: PROCESS_SLUG)
        end

        def root_taxonomy_id_for(organization)
          value = settings_for(organization)[ROOT_TAXONOMY_ID_KEY].to_i
          value if value.positive?
        end

        def settings_for(organization)
          Decidim::Bih::Setting.namespace_for(organization, SETTINGS_NAMESPACE)
        end

        def taxonomy_key(area_or_slug)
          slug = area_or_slug.respond_to?(:slug) ? area_or_slug.slug : area_or_slug.to_s
          "#{AREA_TAXONOMY_PREFIX}#{slug}"
        end

        def initial_proposal_key(area_or_slug)
          slug = area_or_slug.respond_to?(:slug) ? area_or_slug.slug : area_or_slug.to_s
          "#{INITIAL_PROPOSAL_PREFIX}#{slug}"
        end

        def taxonomy_mapping(organization)
          settings_for(organization).each_with_object({}) do |(key, value), mapping|
            next unless key.start_with?(AREA_TAXONOMY_PREFIX)

            taxonomy_id = value.to_i
            next unless taxonomy_id.positive?

            mapping[key.delete_prefix(AREA_TAXONOMY_PREFIX)] = taxonomy_id
          end
        end

        def taxonomy_id_for_area(area)
          value = settings_for(area.organization)[taxonomy_key(area)].to_i
          value if value.positive?
        end

        def taxonomy_id_for_user(user)
          profile = profile_for(user)
          return unless profile&.assigned? && profile.komsiluk

          taxonomy_id_for_area(profile.komsiluk)
        end

        def taxonomy_id_for_resource(resource)
          return unless resource.respond_to?(:taxonomy_ids) && resource.respond_to?(:organization)

          mapped_ids = taxonomy_mapping(resource.organization).values
          (resource.taxonomy_ids.map(&:to_i) & mapped_ids).first
        end

        def area_for_taxonomy(organization, taxonomy_id)
          area_slug = taxonomy_mapping(organization).key(taxonomy_id.to_i)
          return unless area_slug

          Decidim::Bih::LocalArea.komsiluci.find_by(
            decidim_organization_id: organization.id,
            slug: area_slug
          )
        end

        def profile_for(user)
          return unless user&.organization

          Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: user.organization.id,
            decidim_user_id: user.id
          )
        end

        # Taxonomies in which the participant already has a proposal or a
        # currently active vote. This derives the campaign lock from Decidim's
        # own durable participation records, avoiding a second location table.
        # A removed vote no longer locks the participant, while a submitted
        # proposal continues to do so even if it is later withdrawn.
        def participant_taxonomy_ids(user, component)
          return Set.new unless user && component?(component)

          campaign_taxonomy_ids = taxonomy_mapping(component.organization).values.to_set
          proposal_scope = Decidim::Proposals::Proposal.where(component:)

          authored_ids = proposal_scope.from_author(user).reorder(nil).select(:id)
          voted_ids = Decidim::Proposals::ProposalVote
                      .where(author: user, decidim_proposal_id: proposal_scope.select(:id))
                      .select(:decidim_proposal_id)

          taxonomy_ids = Decidim::Taxonomization
                         .where(
                           taxonomizable_type: "Decidim::Proposals::Proposal",
                           taxonomizable_id: authored_ids
                         )
                         .pluck(:taxonomy_id)
          taxonomy_ids.concat(
            Decidim::Taxonomization
              .where(
                taxonomizable_type: "Decidim::Proposals::Proposal",
                taxonomizable_id: voted_ids
              )
              .pluck(:taxonomy_id)
          )

          taxonomy_ids.to_set(&:to_i) & campaign_taxonomy_ids
        end

        def allowed_taxonomy_for?(user, component:, taxonomy_id:)
          expected_id = taxonomy_id_for_user(user)
          return false unless expected_id && expected_id == taxonomy_id.to_i

          prior_ids = participant_taxonomy_ids(user, component)
          prior_ids.empty? || prior_ids == Set[expected_id]
        end
      end
    end
  end
end
