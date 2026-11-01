# frozen_string_literal: true

module DecidimApp
  module Bijeljina
    # Idempotent demo-content seeder for Lokalna fondacija Bijeljina.
    #
    # The platform ships its participation spaces empty (see GrantCycleSetup and
    # CivicDebatesSetup, which lay down structure but no content), so the
    # Proposals/Debates module pages look barren and the homepage
    # `last_activity` feed renders nothing. This service populates those modules
    # with realistic, on-brand Bijeljina content so the platform looks alive and
    # the activity feed has genuine records to order.
    #
    # It seeds, into the already-existing+published grant cycle ("Ti se pitaš!",
    # slug ti-se-pitas-2026) and civic-debates space ("Mi odlučujemo!", slug
    # mi-odlucujemo):
    #
    #   * ~6 citizen Proposals (varied bodies, real votes, created_at spread over
    #     the last few weeks; a couple answered "accepted"/"evaluating"),
    #   * ~4 Debates (civic discussion topics).
    #
    # Budget/Project seeding was REMOVED on the client's instruction (2026-08-31):
    # this seeder used to also create a "Budžet za sve nas!" participatory budget
    # totalling 600.000 KM across five invented projects (including "Novi vrtić u
    # Ledincima", a neighbourhood that isn't in Bijeljina) and publish it. Those
    # figures were illustrative placeholders, not a real municipal budget, and got
    # mistaken for one on the live homepage. Rather than replace one invented total
    # with a smaller invented total, budget seeding is gone outright — see git
    # history (this file, before 2026-08-31) if a real reviewed figure is ever
    # wanted here again.
    #
    # Idempotency: every record is found-or-created on a stable per-component
    # key (proposal/debate by its `sr` title). A re-run never duplicates. Votes
    # are seeded only up to the target count, so re-running tops up but never
    # doubles.
    #
    # All metrics are REAL Decidim records: proposal vote counts come from actual
    # Decidim::Proposals::ProposalVote rows cast by seeded confirmed users, not
    # faked counters.
    #
    #   DecidimApp::Bijeljina::DemoSeed.call(organization: Decidim::Organization.first)
    class DemoSeed
      GRANT_CYCLE_SLUG = "ti-se-pitas-2026"
      DEBATES_SLUG = "mi-odlucujemo"

      # A pool of confirmed citizen accounts used as proposal voters. Sized to
      # cover the largest per-proposal vote target so every seeded vote count is
      # a genuine ProposalVote row. Found-or-created by email so re-runs reuse them.
      VOTER_COUNT = 45

      # ~6 citizen proposals. `state` is one of the default proposal-state tokens
      # (:accepted, :evaluating) or nil for an open/unanswered proposal. `votes`
      # is the target number of real votes; `age_days` spreads created_at.
      PROPOSALS = [
        {
          title: "Biciklistička staza od centra do obale Drine",
          body: "Predlažemo izgradnju sigurne biciklističke staze koja bi povezala " \
                "centar Bijeljine sa obalom Drine. Staza bi građanima omogućila " \
                "rekreaciju i zdraviji način prevoza, a smanjila bi gužve u saobraćaju. " \
                "Trasa bi pratila postojeće ulice uz minimalne troškove.",
          votes: 41,
          age_days: 26,
          state: :accepted
        },
        {
          title: "Uređenje obale Drine",
          body: "Obala Drine je jedan od najljepših dijelova naše opštine, ali je " \
                "zapuštena. Predlažemo uređenje šetališta, postavljanje klupa, " \
                "rasvjete i kanti za otpad, te sadnju drveća. Tako bismo dobili " \
                "prostor za odmor porodica i razvoj turizma.",
          votes: 37,
          age_days: 23,
          state: :evaluating
        },
        {
          title: "Novi vrtić za najmlađe",
          body: "Predškolskim ustanovama u gradu nedostaje kapacitet, pa dio " \
                "roditelja djecu vozi u druge dijelove Bijeljine. Predlažemo " \
                "izgradnju novog vrtića koji bi rasteretio postojeće ustanove.",
          votes: 29,
          age_days: 19,
          state: nil
        },
        {
          title: "Sanacija Gradskog parka",
          body: "Gradski park je srce Bijeljine, ali su staze oštećene, a mobilijar " \
                "dotrajao. Predlažemo sanaciju staza, obnovu klupa i dječjeg " \
                "igrališta te novu hortikulturu. Park treba ponovo da postane mjesto " \
                "okupljanja svih generacija.",
          votes: 22,
          age_days: 14,
          state: nil
        },
        {
          title: "Više kanti za otpad u Semberiji",
          body: "U mnogim naseljima Semberije nedostaje kanti za otpad, što dovodi " \
                "do nepropisnog odlaganja smeća. Predlažemo postavljanje novih kanti " \
                "i korpi na frekventnim lokacijama kako bismo zadržali čistoću naših " \
                "ulica i javnih površina.",
          votes: 15,
          age_days: 9,
          state: nil
        },
        {
          title: "Osvjetljenje oko Vodotornja",
          body: "Vodotoranj je prepoznatljiv simbol Bijeljine, ali okolni prostor " \
                "noću ostaje u mraku. Predlažemo postavljanje ambijentalne rasvjete " \
                "koja bi istakla ovaj spomenik i učinila okolne staze sigurnijim za " \
                "šetnju u večernjim satima.",
          votes: 11,
          age_days: 5,
          state: nil
        }
      ].freeze

      # ~4 civic debate topics.
      DEBATES = [
        {
          title: "Kako da uredimo Gradski park?",
          description: "Gradski park je mjesto okupljanja svih generacija. Kako " \
                       "biste ga vi uredili? Više zelenila, novo igralište, prostor " \
                       "za kulturne događaje ili nešto sasvim drugo? Podijelite " \
                       "svoje ideje i prijedloge.",
          age_days: 21
        },
        {
          title: "Treba li Bijeljini biciklistička mreža?",
          description: "Sve više građana koristi bicikl, ali nedostaje sigurnih " \
                       "staza. Da li nam je potrebna povezana biciklistička mreža " \
                       "kroz grad i prema okolnim naseljima? Koje bi trase bile " \
                       "najvažnije?",
          age_days: 16
        },
        {
          title: "Kako riješiti problem parkinga u centru?",
          description: "Pronalazak parking mjesta u centru Bijeljine postaje sve " \
                       "teži. Da li su rješenje nove parking površine, naplata, " \
                       "podsticanje javnog prevoza ili kombinacija mjera? " \
                       "Razgovarajmo o mogućim rješenjima.",
          age_days: 10
        },
        {
          title: "Kako oživjeti obalu Drine?",
          description: "Obala Drine ima ogroman potencijal za rekreaciju i turizam. " \
                       "Šta bi vas privuklo da češće dolazite na obalu? Šetalište, " \
                       "kafići, sportski tereni, plaža? Recite nam kako vidite obalu " \
                       "Drine u budućnosti.",
          age_days: 4
        }
      ].freeze

      def self.call(organization:)
        new(organization:).call
      end

      def initialize(organization:)
        @organization = organization
      end

      # Returns a summary Hash of what now exists (handy in a runner/console).
      def call
        @voters = ensure_voters

        proposals = seed_proposals
        debates = seed_debates

        {
          proposals: proposals.size,
          debates: debates.size
        }
      end

      private

      attr_reader :organization, :voters

      # --- shared lookups -----------------------------------------------------

      # The org admin that authors official content and creates traceability-bound
      # records. Falls back to any user if no admin (keeps the seeder usable in a
      # bare dev DB), but production always has the bootstrap admin.
      def admin_user
        @admin_user ||=
          Decidim::User.where(organization:, admin: true).order(:created_at).first ||
          Decidim::User.where(organization:).order(:created_at).first
      end

      def grant_cycle
        @grant_cycle ||= Decidim::ParticipatoryProcess.find_by!(
          organization:, slug: GRANT_CYCLE_SLUG
        )
      end

      def debates_space
        @debates_space ||= Decidim::ParticipatoryProcess.find_by!(
          organization:, slug: DEBATES_SLUG
        )
      end

      def component(space, manifest_name)
        space.components.find_by!(manifest_name:)
      end

      # A stable pool of confirmed citizen accounts, found-or-created by email.
      def ensure_voters
        (1..VOTER_COUNT).map do |i|
          email = "demo.gradjanin#{i}@fondacijabijeljina.com"
          user = Decidim::User.find_by(organization:, email:)
          next user if user

          Decidim::User.create!(
            organization:,
            email:,
            name: "Građanin #{i}",
            nickname: "gradjanin#{i}",
            password: SecureRandom.hex(16),
            confirmed_at: Time.current,
            tos_agreement: true,
            accepted_tos_version: organization.tos_version || Time.current,
            locale: "sr"
          )
        end
      end

      # --- proposals ----------------------------------------------------------

      def seed_proposals
        proposals_component = component(grant_cycle, "proposals")
        ensure_proposal_states(proposals_component)

        PROPOSALS.map do |attrs|
          proposal = find_or_create_proposal(proposals_component, attrs)
          seed_votes(proposal, attrs[:votes])
          proposal
        end
      end

      def ensure_proposal_states(proposals_component)
        return if Decidim::Proposals::ProposalState.where(component: proposals_component).any?

        Decidim::Proposals.create_default_states!(proposals_component, admin_user, with_traceability: false)
      end

      def find_or_create_proposal(proposals_component, attrs)
        existing = Decidim::Proposals::Proposal
                   .where(component: proposals_component)
                   .find { |p| p.title["sr"] == attrs[:title] }
        return existing if existing

        created_at = attrs[:age_days].days.ago

        proposal = Decidim::Proposals::Proposal.new(
          component: proposals_component,
          title: translatable(attrs[:title]),
          body: translatable(attrs[:body]),
          published_at: created_at,
          created_at:,
          updated_at: created_at
        )
        # Official authorship (the organization) — always valid and renders
        # publicly without needing a per-proposal citizen account.
        proposal.add_coauthor(organization)

        if attrs[:state]
          proposal.assign_state(attrs[:state])
          proposal.answered_at = created_at + 2.days
          proposal.state_published_at = created_at + 2.days
        end

        proposal.save!
        proposal
      end

      # Seeds REAL ProposalVote rows up to `target`, never above. Re-runs top up
      # but never duplicate (uniqueness is per author+proposal). Accepted/open
      # proposals only — Decidim rejects votes on rejected proposals.
      def seed_votes(proposal, target)
        target = target.to_i
        return if target <= 0 || proposal.votes.count >= target

        voters.first(target).each do |voter|
          break if proposal.votes.count >= target
          next if proposal.votes.exists?(author: voter)

          Decidim::Proposals::ProposalVote.create!(proposal:, author: voter)
        end
      end

      # --- debates ------------------------------------------------------------

      def seed_debates
        debates_component = component(debates_space, "debates")

        DEBATES.map do |attrs|
          existing = Decidim::Debates::Debate
                     .where(component: debates_component)
                     .find { |d| d.title["sr"] == attrs[:title] }
          next existing if existing

          created_at = attrs[:age_days].days.ago

          # Debates have no publish flag — they are public the moment they are
          # created (unless deleted/hidden), so created_at alone drives the feed.
          Decidim::Debates::Debate.create!(
            component: debates_component,
            author: organization,
            title: translatable(attrs[:title]),
            description: translatable(attrs[:description]),
            comments_layout: "single_column",
            created_at:,
            updated_at: created_at
          )
        end
      end

      # --- i18n ---------------------------------------------------------------

      # Builds the 4-locale Hash every translatable Decidim field expects.
      # Serbian Latin is authored once; sr-Cyrl is generated losslessly via the
      # decidim-bih transliterator, and bs/hr (≈95% identical) copy the Latin.
      def translatable(serbian_string)
        {
          "sr" => serbian_string,
          "sr-Cyrl" => Decidim::Bih::Transliterator.call(serbian_string),
          "bs" => serbian_string,
          "hr" => serbian_string
        }
      end
    end
  end
end
