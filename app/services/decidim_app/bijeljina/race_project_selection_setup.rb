# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # One native Decidim process, with a proposal/ballot component per winner.
    # No sample proposals, dates, messages or votes are manufactured.
    class RaceProjectSelectionSetup
      PROJECT = RaceProjectSelection

      def initialize(organization:, actor:, reason:)
        @organization = organization
        @actor = actor
        @reason = reason
      end

      def call(publish: false)
        Decidim::Bih::Race::Review.authorize!(organization, actor)
        raise ArgumentError, "reason required" if reason.blank?
        raise ArgumentError, "SMS authorization must be available" unless organization.available_authorizations.include?("sms")

        PROJECT.budget_scope(organization) # Validate configured copy before any writes.
        organization.with_lock do
          edition = final_edition!

          existing = PROJECT.process(organization)
          return result(existing) if existing

          process = create_process
          steps = create_steps(process)
          mapping = create_proposal_components(process, steps)
          archive = create_archive(process, edition)
          process.update!(description: translations(description(process, mapping, archive)),
                          short_description: translations("<p>Predlaganje i diskusija su otvoreni. Odaberi svoj komšiluk:</p>#{proposal_links(process, mapping)}"))

          { "process_id" => process.id, "component_areas" => mapping.transform_values(&:id),
            "archive_component_id" => archive.id }.each do |key, value|
            Decidim::Bih::Setting.put(organization, PROJECT::NAMESPACE, key, value)
          end
          Decidim::ContentBlocksCreator.new(process).create_default!

          publish_process(process) if publish

          Decidim::Bih::OperatorAuditEvent.record!(
            organization:, actor:, event_type: "race_project_selection_created", resource: process,
            metadata: { reason:, published: publish, race_final_digest: edition.final_digest,
                        component_ids: mapping.keys, archive_component_id: archive.id }
          )
          result(process)
        end
      end

      private

      attr_reader :organization, :actor, :reason

      def final_edition!
        edition = Decidim::Bih::Race::Edition.for(organization)
        raise ArgumentError, "final race required" unless edition&.finalized_at && edition.final_digest.present?

        edition
      end

      def publish_process(process)
        process.components.each { |component| component.update!(published_at: Time.current) }
        process.update!(published_at: Time.current)
        Decidim::ContentBlocksCreator.new(process).create_components_blocks!
      end

      def create_process
        Decidim::ParticipatoryProcess.create!(
          organization:, slug: PROJECT::PROCESS_SLUG,
          title: translations("Odaberi projekat za svoj komšiluk"),
          subtitle: translations("Projekti za #{winner_names_html} — #{PROJECT.budget_scope(organization)}"),
          short_description: translations("Predloži projekat, razgovaraj i učestvuj u izboru za #{winner_names_html}."),
          description: translations("Predlaganje projekata i diskusija su otvoreni."),
          developer_group: translations(ERB::Util.html_escape(PROJECT.localized_name(organization.name))),
          local_area: translations(winner_names_html),
          target: translations("Građani, uključujući nove članove, mogu predlagati i razgovarati. Glasaju osobe s potvrđenim telefonom koje su u profilu izabrale odgovarajući komšiluk."),
          participatory_scope: translations("Izbor projekta #{PROJECT.budget_scope(organization)} za svaki pobjednički komšiluk."),
          participatory_structure: translations("Predlaganje i diskusija, provjera izvodljivosti, glasanje, rezultati i realizacija."),
          start_date: Time.current.in_time_zone("Europe/Sarajevo").to_date,
          end_date: nil, promoted: true, private_space: false
        )
      end

      def create_steps(process)
        ["Predlaganje i diskusija", "Provjera izvodljivosti", "Glasanje", "Rezultati i realizacija"].each_with_index.map do |title, index|
          process.steps.create!(position: index, title: translations(title),
                                description: translations(index.zero? ? "Predloži projekat i razgovaraj o idejama za svoj komšiluk." : "Početak faze biće objavljen ovdje."),
                                start_date: index.zero? ? process.start_date : nil, end_date: nil, active: index.zero?)
        end
      end

      def create_proposal_components(process, steps)
        standings = Decidim::Bih::Race::Standings.new(organization)
        %w(grad selo).each_with_index.to_h do |zone, index|
          winner = standings.leader(zone)
          raise ArgumentError, "both final winners required" unless winner

          component = Decidim::Component.create!(
            participatory_space: process, manifest_name: "proposals", name: winner.komsiluk.name,
            weight: (index + 1) * 10, settings: proposal_settings(winner.display_name),
            step_settings: step_settings(steps),
            permissions: %w(create vote comment vote_comment).index_with { { "authorization_handlers" => { "sms" => {} } } }
          )
          Decidim::Proposals.create_default_states!(component, actor, with_traceability: false)
          [component.id.to_s, winner.komsiluk]
        end
      end

      def proposal_settings(name)
        {
          vote_limit: 1, minimum_votes_per_user: 0, proposal_limit: 0, proposal_length: 5000,
          proposal_edit_time: "limited", edit_time: [24, "hours"], threshold_per_proposal: 0,
          can_accumulate_votes_beyond_threshold: true, proposal_answering_enabled: true,
          default_sort_order: "recent", official_proposals_enabled: true,
          comments_enabled: true, comments_max_length: 2000, geocoding_enabled: true,
          attachments_allowed: true, resources_permissions_enabled: true,
          collaborative_drafts_enabled: false, participatory_texts_enabled: false, amendments_enabled: false,
          announcement: translations("<p><strong>#{ERB::Util.html_escape(name)}: projekat #{PROJECT.budget_scope(organization)}.</strong></p>" \
                                     "<p>Prijedloge i komentare mogu objaviti građani s potvrđenim telefonom. " \
                                     "U fazi glasanja svaki član s potvrđenim telefonom koji je u profilu izabrao ovaj komšiluk, uključujući nove članove, " \
                                     "ima jedan glas, koji može promijeniti. Bodovi ne daju dodatne glasove.</p>"),
          new_proposal_help_text: translations("Predloži jasan i izvodljiv projekat (#{ERB::Util.html_escape(name)}), #{PROJECT.budget_scope(organization)}. " \
                                               "Opiši korist za komšiluk, javnu lokaciju, okvirne troškove i održavanje."),
          new_proposal_body_template: translations("Šta predlažem?\n\nGdje bi projekat bio realizovan?\n\nKome koristi?\n\nOkvirni trošak (#{PROJECT.budget_scope(organization)}):\n\nDozvole i održavanje:"),
          proposal_wizard_step_1_help_text: translations("Ne objavljuj privatne kontakte ili tuđe lične podatke. Dodaj javnu lokaciju i obrazloženje projekta."),
          proposal_wizard_step_2_help_text: translations("Provjeri da je izabran pravi komšiluk. Prijedlog je javan i otvoren za diskusiju; " \
                                                         "izvodljivost se provjerava prije konačnog glasanja.")
        }
      end

      def step_settings(steps)
        announcements = [
          "Predlaganje i diskusija su otvoreni. Glasanje slijedi nakon provjere izvodljivosti; datumi će biti objavljeni ovdje.",
          "Predlaganje je završeno. U toku je provjera izvodljivosti projekata; diskusija je otvorena.",
          "Glasanje je otvoreno. Izaberi jedan projekat za svoj komšiluk. Svoj glas možeš promijeniti dok traje glasanje.",
          "Glasanje je završeno. Pogledaj rezultate i prati informacije o realizaciji izabranog projekta."
        ]
        steps.each_with_index.to_h do |step, index|
          [step.id.to_s, {
            announcement: translations("<p>#{announcements.fetch(index)}</p>"),
            creation_enabled: index.zero?, votes_enabled: index == 2, votes_blocked: index != 2,
            votes_hidden: index < 3, likes_enabled: false, likes_blocked: true,
            comments_blocked: false, proposal_answering_enabled: true,
            publish_answers_immediately: true, default_sort_order: index == 2 ? "random" : "recent"
          }]
        end
      end

      def create_archive(process, edition)
        component = Decidim::Component.create!(
          participatory_space: process, manifest_name: "pages",
          name: translations("Arhiva: Trka komšiluka"), weight: 30
        )
        cutoff = Time.iso8601(edition.snapshot.fetch("cutoff")).in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. u %H:%M")
        date = edition.finalized_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y.")
        Decidim::Pages::Page.create!(component:, body: translations(
          "<h2>Trka komšiluka — konačni rezultati</h2>" \
          "<p>Potvrđeni pobjednici: <strong>#{winner_names_html}</strong>. " \
          "Svaki komšiluk bira projekat #{PROJECT.budget_scope(organization)}.</p>" \
          "<p>Bodovanje je završeno #{cutoff}. Konačni poredak potvrđen je #{date}, uz zadržavanje postojećeg obračuna. Nema žalbenog perioda.</p>" \
          "<p><a href=\"/trka\">Pogledaj sačuvani konačni poredak i pravila trke</a></p>" \
          "<p>Ovaj proces nastavlja se predlaganjem, diskusijom i izborom projekata. Trka je završena i nove aktivnosti ne mijenjaju njen rezultat.</p>"
        ))
        component
      end

      def proposal_links(process, mapping)
        process.components.where(id: mapping.keys).order(:weight).map do |component|
          router = Decidim::EngineRouter.main_proxy(component)
          name = ERB::Util.html_escape(component.name["sr"])
          "<h3>#{name}</h3><p><a href=\"#{router.new_proposal_path}\">Predloži projekat — #{name}</a> · " \
            "<a href=\"#{router.root_path}\">Prijedlozi, diskusija i glasanje — #{name}</a></p>"
        end.join
      end

      def description(process, mapping, archive)
        links = proposal_links(process, mapping)
        "<p><strong>Odaberi projekat za #{winner_names_html}.</strong> " \
          "Izbor se vodi #{PROJECT.budget_scope(organization)} za svaki pobjednički komšiluk.</p>" \
          "<p>Predlaganje i diskusija su otvoreni. Nakon provjere izvodljivosti slijedi glasanje. Rokovi će biti objavljeni u ovom procesu.</p>" \
          "#{links}<h3>Kako biramo</h3><p>Svaki komšiluk ima zasebne prijedloge i zasebno glasanje. " \
          "Prijedloge i komentare mogu objaviti građani s potvrđenim telefonom. Pravo glasa imaju članovi odgovarajućeg komšiluka " \
          "koji su taj komšiluk izabrali u profilu i potvrdili broj telefona, uključujući nove članove. Datum registracije i učešće u Trci nisu uslov. Jedna osoba ima jedan glas, koji može promijeniti. " \
          "Bodovi ne utiču na glasanje.</p><p>Tim zajednice provjerava troškove, potrebne saglasnosti i mogućnost realizacije prije glasanja.</p>" \
          "<h3>Arhiva</h3><p><a href=\"#{Decidim::EngineRouter.main_proxy(archive).root_path}\">Trka komšiluka — konačni rezultati i pravila</a></p>"
      end

      def winner_names_html
        PROJECT.winner_names(organization).map { |name| ERB::Util.html_escape(name) }.join(" i ")
      end

      def translations(text)
        fragment = Nokogiri::HTML::DocumentFragment.parse(text)
        fragment.traverse { |node| node.content = Decidim::Bih::Transliterator.call(node.content) if node.text? }
        { "sr" => text, "bs" => text, "hr" => text, "sr-Cyrl" => fragment.to_html, "en" => text }
      end

      def result(process)
        { process:, components: process.components.where(manifest_name: "proposals").order(:weight).to_a,
          archive: process.components.find_by(manifest_name: "pages") }
      end
    end
  end
end
