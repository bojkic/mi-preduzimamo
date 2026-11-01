# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Idempotently prepares a draft Decidim participatory process for naming all
    # imported Komšiluci. It creates one taxonomy item and one official initial
    # proposal per LocalArea. The delivered GeoJSON name is therefore the first
    # candidate, while citizens can submit alternatives through Decidim.
    #
    # The process and component remain UNPUBLISHED. Exact dates, prize value,
    # eligibility wording and tie handling must be approved before an operator
    # publishes them from Decidim admin.
    class KomsilukNamingCampaignSetup
      CAMPAIGN = KomsilukNamingCampaign
      ROOT_NAME = "Komšiluci — kampanja imenovanja"
      FILTER_NAME = "Komšiluk"
      PROCESS_TITLE = "Imenujmo komšiluke zajedno!"
      NOMINATION_STEP = "Predlaganje naziva"
      VOTING_STEP = "Glasanje"
      RESULTS_STEP = "Rezultati"

      def self.call(organization:, nomination_start: Date.current, nomination_end: 27.days.from_now.to_date,
                    voting_end: 41.days.from_now.to_date)
        new(organization:, nomination_start:, nomination_end:, voting_end:).call
      end

      def initialize(organization:, nomination_start:, nomination_end:, voting_end:)
        @organization = organization
        @nomination_start = nomination_start.to_date
        @nomination_end = nomination_end.to_date
        @voting_end = voting_end.to_date
      end

      def call
        validate_inputs!

        ActiveRecord::Base.transaction do
          process = ensure_process
          steps = ensure_steps(process)
          root_taxonomy = ensure_root_taxonomy
          area_taxonomies = ensure_area_taxonomies(root_taxonomy)
          taxonomy_filter = ensure_taxonomy_filter(root_taxonomy, area_taxonomies.values)
          component = ensure_component(process, steps, taxonomy_filter)
          ensure_proposal_states(component)
          initial_proposals = ensure_initial_proposals(component, area_taxonomies)
          persist_campaign_settings(component:, root_taxonomy:, taxonomy_filter:)

          {
            process:,
            component:,
            root_taxonomy:,
            taxonomy_filter:,
            areas: areas.size,
            initial_proposals: initial_proposals.size
          }
        end
      end

      private

      attr_reader :organization, :nomination_start, :nomination_end, :voting_end

      def validate_inputs!
        raise ArgumentError, "At least one imported Komšiluk is required" if areas.empty?
        raise ArgumentError, "Nomination end must follow nomination start" if nomination_end < nomination_start
        raise ArgumentError, "Voting end must follow nomination end" if voting_end <= nomination_end
      end

      def areas
        @areas ||= Decidim::Bih::LocalArea
                   .komsiluci
                   .where(decidim_organization_id: organization.id)
                   .to_a
                   .sort_by { |area| area.slug.delete_prefix("komsiluk-").to_i }
      end

      def ensure_process
        process = Decidim::ParticipatoryProcess.find_or_initialize_by(
          organization:,
          slug: CAMPAIGN::PROCESS_SLUG
        )
        raise "Campaign process is already published; update it through an approved campaign operation" if process.published?

        process.update!(
          title: translatable(PROCESS_TITLE),
          subtitle: translatable("Predloži i izaberi naziv svog komšiluka"),
          short_description: translatable(short_description),
          description: translatable(description),
          start_date: nomination_start,
          end_date: voting_end,
          promoted: false,
          private_space: false
        )
        process
      end

      def ensure_steps(process)
        definitions = {
          nominations: [0, NOMINATION_STEP, nomination_start, nomination_end, true],
          voting: [1, VOTING_STEP, nomination_end + 1.day, voting_end, false],
          results: [2, RESULTS_STEP, voting_end + 1.day, nil, false]
        }

        process.steps.update_all(active: false, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        definitions.transform_values do |position, title, start_date, end_date, active|
          step = process.steps.find_or_initialize_by(position:)
          step.update!(
            title: translatable(title),
            start_date:,
            end_date:,
            active:
          )
          step
        end
      end

      def ensure_root_taxonomy
        stored_id = settings[CAMPAIGN::ROOT_TAXONOMY_ID_KEY].to_i
        stored = organization.taxonomies.roots.find_by(id: stored_id) if stored_id.positive?
        return stored if stored

        organization.taxonomies.roots.find_by("name ->> 'sr' = ?", ROOT_NAME) ||
          Decidim::Taxonomy.create!(organization:, name: translatable(ROOT_NAME))
      end

      def ensure_area_taxonomies(root_taxonomy)
        areas.each_with_index.to_h do |area, index|
          stored_id = settings[CAMPAIGN.taxonomy_key(area)].to_i
          taxonomy = root_taxonomy.children.find_by(id: stored_id) if stored_id.positive?
          taxonomy ||= Decidim::Taxonomy.create!(
            organization:,
            parent: root_taxonomy,
            name: taxonomy_name(area),
            weight: index
          )

          taxonomy.update!(name: taxonomy_name(area), weight: index) unless taxonomy.name == taxonomy_name(area) && taxonomy.weight == index
          Decidim::Bih::Setting.put(
            organization,
            CAMPAIGN::SETTINGS_NAMESPACE,
            CAMPAIGN.taxonomy_key(area),
            taxonomy.id
          )
          [area, taxonomy]
        end
      end

      def ensure_taxonomy_filter(root_taxonomy, taxonomies)
        stored_id = settings[CAMPAIGN::TAXONOMY_FILTER_ID_KEY].to_i
        filter = root_taxonomy.taxonomy_filters.find_by(id: stored_id) if stored_id.positive?
        filter ||= root_taxonomy.taxonomy_filters.find_by("internal_name ->> 'sr' = ?", FILTER_NAME)
        filter ||= Decidim::TaxonomyFilter.create!(
          root_taxonomy:,
          name: translatable(FILTER_NAME),
          internal_name: translatable(FILTER_NAME),
          participatory_space_manifests: ["participatory_processes"]
        )

        taxonomies.each do |taxonomy|
          Decidim::TaxonomyFilterItem.find_or_create_by!(
            taxonomy_filter: filter,
            taxonomy_item: taxonomy
          )
        end
        filter
      end

      def ensure_component(process, steps, taxonomy_filter)
        component = process.components.find_by(manifest_name: "proposals")
        raise "Campaign proposal component is already published; update it through an approved campaign operation" if component&.published?

        attrs = {
          name: translatable("Prijedlozi naziva"),
          settings: global_component_settings(taxonomy_filter),
          step_settings: component_step_settings(steps),
          permissions: component_permissions
        }

        if component
          component.update!(attrs)
        else
          component = Decidim::Component.create!(
            participatory_space: process,
            manifest_name: "proposals",
            published_at: nil,
            **attrs
          )
        end
        component
      end

      def ensure_proposal_states(component)
        return if Decidim::Proposals::ProposalState.exists?(component:)

        Decidim::Proposals.create_default_states!(component, admin_user, with_traceability: false)
      end

      def ensure_initial_proposals(component, area_taxonomies)
        area_taxonomies.map do |area, taxonomy|
          stored_id = settings[CAMPAIGN.initial_proposal_key(area)].to_i
          proposal = Decidim::Proposals::Proposal.where(component:).find_by(id: stored_id) if stored_id.positive?
          proposal ||= initial_proposal_for(component, taxonomy)
          proposal ||= create_initial_proposal(component, area, taxonomy)

          proposal.taxonomies << taxonomy unless proposal.taxonomy_ids.include?(taxonomy.id)

          Decidim::Bih::Setting.put(
            organization,
            CAMPAIGN::SETTINGS_NAMESPACE,
            CAMPAIGN.initial_proposal_key(area),
            proposal.id
          )
          proposal
        end
      end

      def initial_proposal_for(component, taxonomy)
        Decidim::Proposals::Proposal
          .where(component:)
          .with_official_origin
          .joins(:taxonomies)
          .find_by(decidim_taxonomies: { id: taxonomy.id })
      end

      def create_initial_proposal(component, area, taxonomy)
        proposal = Decidim::Proposals::Proposal.new(
          component:,
          title: translatable(area.name.fetch("sr", area.translated_name)),
          body: translatable(initial_proposal_body),
          published_at: Time.current
        )
        proposal.add_coauthor(organization)
        proposal.taxonomies << taxonomy
        proposal.save!
        proposal
      end

      def persist_campaign_settings(component:, root_taxonomy:, taxonomy_filter:)
        {
          CAMPAIGN::COMPONENT_ID_KEY => component.id,
          CAMPAIGN::ROOT_TAXONOMY_ID_KEY => root_taxonomy.id,
          CAMPAIGN::TAXONOMY_FILTER_ID_KEY => taxonomy_filter.id
        }.each do |key, value|
          Decidim::Bih::Setting.put(organization, CAMPAIGN::SETTINGS_NAMESPACE, key, value)
        end
      end

      def global_component_settings(taxonomy_filter)
        {
          taxonomy_filters: [taxonomy_filter.id],
          vote_limit: 1,
          minimum_votes_per_user: 0,
          proposal_limit: 1,
          proposal_length: 300,
          proposal_edit_time: "limited",
          edit_time: [30, "minutes"],
          threshold_per_proposal: 0,
          can_accumulate_votes_beyond_threshold: true,
          proposal_answering_enabled: true,
          default_sort_order: "random",
          official_proposals_enabled: true,
          comments_enabled: true,
          comments_max_length: 500,
          geocoding_enabled: false,
          attachments_allowed: false,
          resources_permissions_enabled: true,
          collaborative_drafts_enabled: false,
          participatory_texts_enabled: false,
          amendments_enabled: false,
          announcement: translatable(component_announcement),
          new_proposal_help_text: translatable(new_proposal_help),
          new_proposal_body_template: translatable("Objasni zašto naziv pripada ovom komšiluku i šta povezuje njegove stanovnike."),
          proposal_wizard_step_1_help_text: translatable("Upiši samo jedan jasan naziv. Ne navodi privatne adrese ili podatke drugih ljudi."),
          proposal_wizard_step_2_help_text: translatable("Provjeri naziv i obrazloženje prije objave. Nakon objave prijedlog ulazi u moderaciju kampanje.")
        }
      end

      def component_step_settings(steps)
        {
          steps.fetch(:nominations).id.to_s => {
            creation_enabled: true,
            votes_enabled: false,
            votes_blocked: true,
            votes_hidden: true,
            likes_enabled: false,
            likes_blocked: true,
            comments_blocked: false,
            default_sort_order: "recent"
          },
          steps.fetch(:voting).id.to_s => {
            creation_enabled: false,
            votes_enabled: true,
            votes_blocked: false,
            votes_hidden: true,
            likes_enabled: false,
            likes_blocked: true,
            comments_blocked: false,
            default_sort_order: "random"
          },
          steps.fetch(:results).id.to_s => {
            creation_enabled: false,
            votes_enabled: false,
            votes_blocked: true,
            votes_hidden: false,
            likes_enabled: false,
            likes_blocked: true,
            comments_blocked: true,
            default_sort_order: "most_voted"
          }
        }
      end

      def component_permissions
        %w(create vote).index_with do
          { "authorization_handlers" => { "sms" => {} } }
        end
      end

      def settings
        @settings ||= CAMPAIGN.settings_for(organization)
      end

      def admin_user
        @admin_user ||= Decidim::User.where(organization:, admin: true).order(:id).first ||
                        Decidim::User.where(organization:).order(:id).first ||
                        raise("An organization user is required to create proposal states")
      end

      def taxonomy_name(area)
        number = area.slug.delete_prefix("komsiluk-")
        translatable("Komšiluk #{number} — #{area.name.fetch("sr", area.slug)}")
      end

      def translatable(text)
        {
          "sr" => text,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(text),
          "bs" => text,
          "hr" => text
        }
      end

      def short_description
        "Svaki komšiluk bira svoje ime. Predloži naziv, razgovaraj sa komšijama i glasaj jednom za svog favorita."
      end

      def description
        "Karta sadrži 92 komšiluka i početni prijedlog naziva za svaki od njih. " \
          "Građanin prvo bira svoj komšiluk i potvrđuje telefon, zatim može poslati " \
          "jedan prijedlog i dati jedan glas samo u tom komšiluku. Glasovi su jednaki; " \
          "Goodwill bodovi ne utiču na rezultat. Tačne nagrade, rokovi i pravilo za " \
          "neriješen rezultat biće objavljeni prije javnog početka kampanje."
      end

      def component_announcement
        "Prvo odaberi svoj komšiluk na stranici Moj komšiluk i potvrdi telefon. " \
          "Početni naziv sa karte već je unesen kao prvi prijedlog. Svaka osoba može " \
          "predložiti jedan naziv i u fazi glasanja dati jedan promjenjiv glas."
      end

      def new_proposal_help
        "Prijedlog će automatski biti povezan s komšilukom iz tvog privatnog profila. " \
          "Naziv treba biti kratak, uključiv i vezan za lokalnu priču; govor mržnje, " \
          "lični podaci i komercijalno oglašavanje nisu dozvoljeni."
      end

      def initial_proposal_body
        "Početni prijedlog preuzet je iz dostavljene karte komšiluka. Može dobiti glas " \
          "kao i svaki građanski prijedlog, ali nema pojedinačnog autora niti prednost u rangiranju."
      end
    end
  end
end
