# frozen_string_literal: true

require "cgi"
require "date"
require_relative "volunteer_activity_fact"
require_relative "read/base"

module DecidimApp
  module Bijeljina
    module Milica
      # Projects domain-owned public records into bounded chatbot facts. Never
      # exposes memberships, applicants, contributions, private contacts or wallet
      # balances. An activity with no komšiluk covers the whole city (owner
      # decision of 2026-09-13): it answers a komšiluk question, but it is
      # labelled as city-wide and is never presented as a local match.
      class PlatformCatalogRead
        include Read::Base

        TOPICS = %w(volunteer community participation rewards facilities).freeze
        LIMIT = 8
        MAX_TEXT = 1_000
        SOURCE_LABEL = "MI PRE(D)UZIMAMO!"
        CITYWIDE_SCOPE = "citywide"
        # Rewards are read as a whole so a named one can be found anywhere in
        # the catalogue, then narrowed before anything is rendered. The public
        # catalogue has nine rewards; reading eight and printing eight was the
        # one combination that could neither answer a price nor list the shelf.
        REWARD_POOL = 50
        OPEN_LIMIT = 3
        REWARD_CHEAPEST = /(?:najjeftin|najpovoljn|najniz|najmanje\s+bodova|cheapest)/
        REWARD_COUNT = /(?<count>jedn\w*|dvij?e|dva|tri|cetiri|1|2|3|4)\s+(?:naj\w+|nagrad\w*)/
        # "Kako da doniram" / "broj računa": the giving half of the donation
        # subject, as opposed to the aggregate total or the project allocation.
        GIVING_QUESTION = /(?:donir|uplat|racun|donacij|pomognem|pomoci|prilog|donate)/
        REWARD_COUNT_WORDS = {
          "jedna" => 1, "jednu" => 1, "jedno" => 1, "1" => 1,
          "dvije" => 2, "dve" => 2, "dva" => 2, "2" => 2,
          "tri" => 3, "3" => 3, "cetiri" => 3, "4" => 3
        }.freeze

        class DateRange < Range
          attr_reader :range_kind

          def initialize(first, last, range_kind:)
            @range_kind = range_kind
            super(first, last)
          end
        end

        def initialize(organization:, area_matcher: nil)
          @organization = organization
          @area_matcher = area_matcher || CityServiceAreaMatcher.new(organization:)
        end

        # Keep authorization, typed area resolution and public catalogue dispatch visible at the read boundary.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def call(topic:, entities:, context:, locale:, location: nil)
          return result("not_authorized", topic:, warnings: ["public_reads_not_allowed"]) unless authorized?(context)
          return result("unavailable", topic:, warnings: ["unsupported_catalog_topic"]) unless TOPICS.include?(topic.to_s)

          entities = entities.transform_keys(&:to_s)
          resolution = @area_matcher.resolve(area_slug: entities["area_slug"], area_query: entities["area_query"], location:)
          if resolution.status != :ok
            return result(resolution.status == :ambiguous ? "ambiguous" : "empty", topic:,
                                                                                   candidates: resolution.areas.first(LIMIT).map do |area|
                                                                                     { "slug" => area.slug, "kind" => area.kind, "label" => area.translated_name }
                                                                                   end,
                                                                                   warnings: [resolution.warning])
          end
          date = requested_date(entities, context.now, topic:)
          I18n.with_locale(locale) do
            options = { entities:, now: context.now, date:, areas: resolution.areas, locale: }
            facts, warnings = case topic.to_s
                              when "volunteer" then volunteers(**options)
                              when "community" then community(**options)
                              when "participation" then participation(**options)
                              when "rewards" then rewards(**options)
                              else [[], ["facility_registry_not_reviewed"]]
                              end
            if topic.to_s == "community" && entities["view"] == "projects" && facts.empty?
              # The public project index exists even when no current project
              # row can be returned for this scope. Give Gemini the real route
              # without presenting a nonexistent project as a catalogue item.
              facts = [project_catalog_navigation]
              warnings << "no_current_project_row_in_read_scope"
            end
            result(facts.any? ? "ok" : "empty", topic:, facts:, checked_at: context.now,
                                                coverage: { "organization_id" => @organization.id, "requested_area_slugs" => resolution.areas.map(&:slug),
                                                            "requested_areas" => requested_areas(resolution.areas, locale),
                                                            "geographic_scope" => "per_fact", "access" => "public", "complete_inventory" => false },
                                                validity: requested_validity(date, context.now),
                                                warnings: [*warnings, "catalog_current_public_items_only"])
          end
        rescue ArgumentError => e
          raise unless %w(invalid_catalog_date unsupported_catalog_time).include?(e.message)

          result("ambiguous", topic:, warnings: [e.message])
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        private

        def requested_areas(areas, locale)
          areas.map do |area|
            { "slug" => area.slug, "kind" => area.kind, "label" => plain_text(area.translated_name, locale) }
          end
        end

        # Keep supported date forms and conflicting weekend evidence in one explicit parsing decision.
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def requested_date(entities, now, topic:)
          expression = fold(entities["time_expression"])
          if %w(uskoro soon).include?(expression)
            raise ArgumentError, "unsupported_catalog_time" unless topic.to_s == "volunteer"

            first = local_date(now)
            return date_range(first, first + 6, entities, range_kind: "next_seven_days")
          end
          expression = expression.delete_prefix("za ")
          this_weekend = ["vikend", "ovog vikenda", "ovaj vikend", "this weekend"].include?(expression)
          next_weekend = ["sljedeceg vikenda", "sledeceg vikenda", "sljedeci vikend", "sledeci vikend",
                          "narednog vikenda", "naredni vikend", "next weekend"].include?(expression)
          if this_weekend || next_weekend
            raise ArgumentError, "unsupported_catalog_time" unless %w(volunteer participation).include?(topic.to_s)

            day = local_date(now)
            saturday = day + (day.sunday? ? -1 : ((6 - day.wday) % 7))
            saturday += 7 if next_weekend
            return date_range(saturday, saturday.next_day, entities, range_kind: "weekend")
          end
          raise ArgumentError, "unsupported_catalog_time" if expression.match?(/\b(?:vikend\w*|weekend\w*)\b/)

          parsed = requested_day(entities, now:, expression:)
          return parsed.day if [:explicit, :today, :tomorrow].include?(parsed.kind)
          return if parsed.kind == :none

          raise ArgumentError, "unsupported_catalog_time"
        rescue Date::Error
          raise ArgumentError, "invalid_catalog_date"
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def date_range(first, last, entities, range_kind:)
          range = DateRange.new(first, last, range_kind:)
          raise ArgumentError, "unsupported_catalog_time" if entities["date"].present? && !range.cover?(Date.iso8601(entities["date"]))

          range
        end

        def requested_validity(date, now)
          result = { "observed_at" => now.iso8601, "precision" => "per_fact", "timezone" => TIME_ZONE }
          return result.merge("requested_date" => date&.iso8601) unless date.is_a?(Range)

          result.merge("requested_dates" => { "from" => date.begin.iso8601, "through" => date.end.iso8601 },
                       "range_kind" => date.is_a?(DateRange) ? date.range_kind : "weekend", "known_past_occurrences_excluded" => true)
        end

        def requested_date_bounds(date, now)
          day = local_date(now)
          return [[date.begin, day].max, date.end] if date.is_a?(Range)

          [date || day, date || day]
        end

        def requested_clock_bounds(date, now)
          first_date, last_date = requested_date_bounds(date, now)
          first = local_day_bounds(first_date).first
          first = [first, now].max if date.is_a?(Range)
          [first, local_day_bounds(last_date).last]
        end

        def volunteers(entities:, now:, date:, areas:, locale:)
          model = Decidim::Bih::VolunteerOpportunity
          table = model.table_name
          scope = model.publicly_visible.where(organization: @organization, cancelled_at: nil)
                       .where("#{table}.signup_deadline_at IS NULL OR #{table}.signup_deadline_at > ?", now)
          scope = volunteer_area_scope(scope, areas)
          scope = volunteer_time_filter(scope, now, date)
          scope = scope.where(category: entities["category"]) if entities["category"].present?
          records = scope.includes(:komsiluk).order(starts_at: :asc, id: :asc).limit(LIMIT).to_a
          going_counts = Decidim::Bih::VolunteerSignup.going.where(organization: @organization, opportunity: records)
                                                      .group(:decidim_bih_volunteer_opportunity_id).count
          facts = records.map do |row|
            public_fact = fact(row, kind: "volunteer_opportunity", title: row.title, description: row.description, path: public_path("volontiranje"), locale:,
                                    area: row.komsiluk, starts_at: row.starts_at, ends_at: row.ends_at).merge(
                                      "category" => row.category, "signup_deadline_at" => row.signup_deadline_at&.iso8601,
                                      "schedule" => { "day_keys" => row.day_keys, "month_keys" => row.month_keys, "time_slot_keys" => row.time_slot_keys },
                                      "opportunity_kind" => row.opportunity_kind,
                                      "title" => plain_text(row.title, locale),
                                      "location" => plain_text(row.location_label, locale), "requirements" => plain_text(row.requirements, locale),
                                      "availability" => volunteer_availability(row, going_counts.fetch(row.id, 0), now)
                                    )
            VolunteerActivityFact.call(fact: public_fact, record: row, locale:)
          end
          facts = label_citywide(VolunteerActivityFact.compact_series(facts:, records:, locale:), records, areas, locale)
          [facts, areas.any? { |area| area.kind == "mz" } ? ["mz_to_opportunity_crosswalk_not_reviewed"] : []]
        end

        # A row without a komšiluk covers the whole city, so it belongs in every
        # area-scoped answer. PostgreSQL sorts NULL last in an ascending order,
        # so those rows follow every local one and never bury a local match.
        def volunteer_area_scope(scope, areas)
          return scope unless areas.any?

          scope.where(komsiluk_id: areas.select { |area| area.kind == "komsiluk" }.map(&:id) + [nil]).order(komsiluk_id: :asc)
        end

        # Only an area-scoped question can mistake a city-wide row for a local
        # one, so only that answer carries the distinction.
        def label_citywide(facts, records, areas, locale)
          return facts unless areas.any?

          facts.zip(records).map { |public_fact, row| row.komsiluk ? public_fact : citywide_fact(public_fact, locale) }
        end

        def volunteer_availability(row, going, now)
          remaining = row.capacity ? [row.capacity - going, 0].max : nil
          { "capacity" => row.capacity, "going_count" => going, "remaining_places" => remaining,
            "status" => remaining&.zero? ? "waitlist" : "signup_open", "checked_at" => now.iso8601,
            "recheck_on_destination" => true }
        end

        def volunteer_time_filter(scope, now, date)
          table = scope.klass.arel_table
          starts = table[:starts_at]
          ends = table[:ends_at]
          return scope.where(ends.gt(now).or(ends.eq(nil).and(starts.eq(nil).or(starts.gteq(now))))) unless date

          first, last = requested_clock_bounds(date, now)
          from, through = requested_date_bounds(date, now)
          scheduled = starts.lt(last).and(ends.gt(first).or(ends.eq(nil).and(starts.gteq(first))))
          # Match each recurring weekday with its own month across boundaries.
          recurring_days = (from..through).map do |day|
            weekday = Arel::Nodes.build_quoted([day.strftime("%A").downcase].to_json)
            month = Arel::Nodes.build_quoted([day.strftime("%B").downcase].to_json)
            weekday_match = Arel::Nodes::InfixOperation.new("@>", table[:day_keys], weekday)
            weekday_match.and(Arel::Nodes::InfixOperation.new("@>", table[:month_keys], month))
          end
          recurring = recurring_days.reduce { |left, right| left.or(right) }
          return scope.where(scheduled) unless recurring

          scope.where(scheduled.or(starts.eq(nil).and(ends.eq(nil)).and(recurring)))
        end

        def community(entities:, now:, date:, areas:, locale:)
          query = fold([entities["query"], entities["category"]].compact.join(" "))
          options = { now:, date:, areas:, locale: }
          # The conversation model selects a data collection. Legacy callers
          # without a view retain their existing search behavior.
          case entities["view"]
          when "projects" then return projects(**options)
          when "material_needs" then return needs(**options)
          when "organizations" then return partners(**options)
          when "giving_guidance" then return partners(**options, giving: true)
          end
          return partners(**options, giving: GIVING_QUESTION.match?(query)) if query.match?(/\b(?:organiz\w*|udruzen\w*|partner\w*)\b/)
          return projects(**options) if query.match?(/\b(?:projek\w*|donacij\w*)\b/)
          return needs(**options) if query.match?(/\b(?:potreb\w*|oprem\w*|materijal\w*)\b/)

          groups = [projects(**options), partners(**options), needs(**options)]
          # Round-robin keeps a populated family from hiding the others.
          facts = (0...LIMIT).flat_map { |index| groups.filter_map { |rows, _| rows[index] } }.first(LIMIT)
          [facts, groups.flat_map(&:last).uniq]
        end

        def partners(date:, areas:, locale:, giving: false, **)
          scope = Decidim::Bih::PartnerProfile.publicly_visible.where(organization: @organization)
          scope = scope.where(local_area_id: areas.map(&:id)) if areas.any?
          rows = scope.includes(:local_area).order(:display_name, :id).limit(LIMIT).to_a
          rows = prefer_supporting_organization(rows) if giving
          facts = rows.map do |row|
            fact(row, kind: "partner_profile", title: row.display_name, description: row.public_description,
                      path: public_path("organizacija/#{row.id}"), locale:, area: row.local_area).merge("partner_kind" => row.kind)
          end
          [facts, date ? ["partner_profile_has_no_event_calendar"] : []]
        end

        # A GIVING question is the one place the foundation's own published
        # record — the record that carries its payment instructions — is what
        # the citizen asked for. It leads the answer there; it is never
        # reachable from a race, points or rewards question, which is how two
        # account numbers and an IBAN once came back as an explanation of the
        # neighbourhood race.
        def prefer_supporting_organization(rows)
          name = fold(Decidim::Bih.public_support_name)
          return rows if name.empty?

          own, others = rows.partition { |row| fold(row.display_name).include?(name) }
          own + others
        end

        def projects(now:, date:, areas:, locale:)
          return [[], ["project_geography_not_reviewed"]] if areas.any?

          budget_id = Decidim::Bih::Setting.namespace_for(@organization, "community_projects").fetch("budget_id", nil).to_i
          budget = Decidim::Budgets::Budget.find_by(id: budget_id) if budget_id.positive?
          return [[], []] unless community_storage_available?(budget)

          model = Decidim::Bih::PartnerProjectSubmission
          table = model.table_name
          scope = model.approved.where(organization: @organization).joins(:partner_profile, :project_donation_link, :project)
                       .merge(Decidim::Bih::PartnerProfile.publicly_visible.where(organization: @organization))
                       .merge(Decidim::Bih::ProjectDonationLink.active.where(organization: @organization))
                       .where(decidim_budgets_projects: { decidim_budgets_budget_id: budget.id, deleted_at: nil })
                       .where("#{table}.ends_on IS NULL OR #{table}.ends_on >= ?", date || local_date(now))
          scope = scope.where("#{table}.starts_on <= ?", date) if date
          facts = scope.includes(:project).order(reviewed_at: :desc, id: :desc).limit(LIMIT).map do |row|
            # Only the public native project, never the private submitted text.
            fact(row.project, kind: "community_project", title: row.project.title, description: row.project.description,
                              path: public_path("projekti/#{row.project.id}"), locale:, starts_at: row.starts_on, ends_at: row.ends_on,
                              date_precision: true)
          end
          [facts, ["project_geography_unknown"]]
        end

        def project_catalog_navigation
          { "id" => "platform:community:project_catalog", "kind" => "catalog_navigation",
            "text" => "Javni katalog projekata može se pregledati na stranici /biceriseno/projekti. Ovo čitanje nije vratilo konkretan trenutno prihvatljiv projekat; to ne znači da stranica ne postoji niti potvrđuje bilo čiju uplatu.",
            "destination" => public_path("projekti"), "source_id" => "platform:community",
            "coverage" => { "organization_id" => @organization.id, "scope" => "public_project_catalog_navigation" } }
        end

        def community_storage_available?(budget)
          return false unless budget && budget.deleted_at.nil?

          component = budget.component
          space = component&.participatory_space
          component&.published? && space&.organization == @organization && !space.published? &&
            (!space.respond_to?(:deleted_at) || space.deleted_at.nil?)
        end

        def needs(now:, date:, areas:, locale:)
          return [[], ["contribution_need_geography_not_reviewed"]] if areas.any?

          model = Decidim::Bih::ContributionNeed
          table = model.table_name
          scope = model.approved_open.where(organization: @organization).joins(:partner_profile)
                       .merge(Decidim::Bih::PartnerProfile.publicly_visible.where(organization: @organization))
                       .where("#{table}.needed_by IS NULL OR #{table}.needed_by >= ?", date || local_date(now))
          scope = scope.where("#{table}.published_at IS NOT NULL AND #{table}.published_at <= ?", now)
          facts = scope.order(needed_by: :asc, id: :asc).limit(LIMIT).map do |row|
            fact(row, kind: "contribution_need", title: row.title, description: row.description,
                      path: public_path("volontiranje"), locale:, ends_at: row.needed_by, date_precision: true).merge(
                        "need_type" => row.need_type, "quantity" => row.quantity.to_s("F"), "unit" => row.unit
                      )
          end
          [facts, ["contribution_need_geography_unknown"]]
        end

        def participation(entities:, now:, date:, areas:, locale:)
          return [[], ["participation_geography_not_reviewed"]] if areas.any?

          query = fold([entities["query"], entities["category"]].compact.join(" "))
          options = { now:, date:, locale: }
          facts = if query.match?(/\b(?:sastan\w*|susret\w*|meeting\w*)\b/)
                    public_meetings(**options)
                  elsif query.match?(/\b(?:prijedlo\w*|predlo\w*|proposal\w*)\b/)
                    public_proposals(**options)
                  else
                    groups = [public_processes(**options), public_meetings(**options), public_proposals(**options)]
                    (0...LIMIT).flat_map { |index| groups.filter_map { |rows| rows[index] } }.first(LIMIT)
                  end
          [facts, %w(participation_geography_unknown participation_eligibility_checked_on_destination)]
        end

        def public_process_scope(now, date)
          first, last = requested_date_bounds(date, now)
          scope = Decidim::ParticipatoryProcess.published.where(organization: @organization, private_space: false, deleted_at: nil)
                                               .where(published_at: ..now).where("end_date IS NULL OR end_date >= ?", first)
          date ? scope.where(start_date: ..last) : scope
        end

        def public_processes(now:, date:, locale:)
          public_process_scope(now, date).order(start_date: :asc, id: :asc).limit(LIMIT).map do |row|
            fact(row, kind: "participatory_process", title: row.title, description: row.short_description,
                      path: "/processes/#{CGI.escape(row.slug)}", locale:, starts_at: row.start_date, ends_at: row.end_date, date_precision: true).merge(
                        "public_rules" => { "target" => plain_text(translated(row.target, locale), locale),
                                            "participatory_scope" => plain_text(translated(row.participatory_scope, locale), locale),
                                            "starts_on" => row.start_date&.iso8601, "ends_on" => row.end_date&.iso8601 }
                      )
          end
        end

        def public_components(now, date, respect_space_dates: true)
          processes = if respect_space_dates
                        public_process_scope(now, date)
                      else
                        Decidim::ParticipatoryProcess.published.where(organization: @organization, private_space: false, deleted_at: nil)
                                                     .where(published_at: ..now)
                      end
          assemblies = Decidim::Assembly.published.where(organization: @organization, private_space: false, deleted_at: nil)
                                        .where(published_at: ..now)
          assemblies = assemblies.where("closing_date IS NULL OR closing_date >= ?", requested_date_bounds(date, now).first) if respect_space_dates
          Decidim::Component.published.where(participatory_space: processes).or(
            Decidim::Component.published.where(participatory_space: assemblies)
          ).where(decidim_components: { published_at: ..now })
        end

        def public_meetings(now:, date:, locale:)
          model = Decidim::Meetings::Meeting
          first, last = date ? requested_clock_bounds(date, now) : [now, nil]
          scope = model.visible_for(nil).not_hidden.not_withdrawn.where(component: public_components(now, date, respect_space_dates: false), deleted_at: nil)
                       .where("#{model.table_name}.published_at <= ?", now)
                       .where("#{model.table_name}.end_time > ?", first)
          scope = scope.where("#{model.table_name}.start_time < ?", last) if last
          scope.includes(:component).order(start_time: :asc, id: :asc).limit(LIMIT).map do |row|
            path = Decidim::EngineRouter.main_proxy(row.component).meeting_path(row)
            fact(row, kind: "public_meeting", title: row.title, description: row.description, path:, locale:,
                      starts_at: row.start_time, ends_at: row.end_time).merge(
                        "attendance_rules_checked_on_destination" => true,
                        "location" => plain_text(translated(row.location, locale), locale), "address" => plain_text(row.address, locale),
                        "registration_terms" => plain_text(translated(row.registration_terms, locale), locale)
                      )
          end
        end

        def public_proposals(now:, date:, locale:)
          model = Decidim::Proposals::Proposal
          scope = model.published.not_hidden.not_withdrawn.only_amendables.where(component: public_components(now, date), deleted_at: nil)
                       .where("#{model.table_name}.published_at <= ?", now)
          scope.includes(:component).order(published_at: :desc, id: :desc).limit(LIMIT).map do |row|
            path = Decidim::EngineRouter.main_proxy(row.component).proposal_path(row)
            fact(row, kind: "public_proposal", title: row.title, description: row.body, path:, locale:).merge(
              "published_at" => row.published_at.iso8601, "proposal_is_not_an_approved_service_fact" => true,
              "voting_rules_checked_on_destination" => true
            )
          end
        end

        # rubocop:disable Metrics/ParameterLists -- one named option per catalogue dimension, same shape as the other families
        def rewards(entities:, now:, date:, areas:, locale:, **)
          model = Decidim::Bih::Goodwill::Reward
          active = model.active.where(organization: @organization)
          rows = if active.exists?
                   reward_stock_filter(active, now).order(:cost, :id).limit(REWARD_POOL).to_a
                 else
                   config_rewards(now)
                 end
          selected, selection = select_rewards(rows, entities)
          facts = selected.map { |row| reward_fact(row, locale:) }
          warnings = ["reward_stock_rechecked_on_redemption"]
          warnings << "reward_catalog_not_complete_inventory" if selection == :open && selected.length < rows.length
          warnings << "reward_future_availability_not_guaranteed" if date && date > local_date(now)
          warnings << "reward_geography_not_applicable" if areas.any?
          [facts, warnings]
        end
        # rubocop:enable Metrics/ParameterLists

        # A rewards question is a question about a PRICE, and almost always
        # about one reward or about the cheapest few. The eight-item dump
        # answered neither, and it truncated the catalogue at eight of nine
        # while carrying no cost at all, so it could not even be read as a
        # catalogue. Returns [rows, :named | :cheapest | :open].
        def select_rewards(rows, entities)
          query = fold([entities["query"], entities["category"]].compact.join(" "))
          named = rows.select { |row| reward_named?(row, query) }
          return [named, :named] if named.any?
          # `rows` is already ordered by cost ascending.
          return [rows.first(requested_count(query)), :cheapest] if REWARD_CHEAPEST.match?(query)

          [rows.first(OPEN_LIMIT), :open]
        end

        def reward_named?(row, query)
          return false if query.empty?

          reward_terms(row).any? { |term| query.include?(term) }
        end

        # The reward's own key plus the distinctive words of its name. A short
        # token ("MI", "za") matches half the language, so only words of four
        # characters or more are allowed to identify a reward.
        def reward_terms(row)
          [fold(row.key)] + fold(row.name).split.select { |word| word.length >= 4 }
        end

        # "Koje su DVIJE najjeftinije nagrade" — the number the citizen asked
        # for, bounded by OPEN_LIMIT so no phrasing reopens the dump.
        def requested_count(query)
          match = REWARD_COUNT.match(query)
          return OPEN_LIMIT unless match

          REWARD_COUNT_WORDS.fetch(match[:count], OPEN_LIMIT)
        end

        # What a rewards question is actually asking is the price, so the point
        # cost belongs in the sentence a citizen reads — not only in a
        # structured field the catalogue page renders. A reward that does not
        # deduct points has a threshold, not a price, and says so.
        def reward_fact(row, locale:)
          record = row.respond_to?(:id) ? row : nil
          built = fact(record, kind: "reward", title: row.name, description: row.description,
                               path: public_path("zajednistvo?tab=nagrade"), locale:,
                               ends_at: row.expires_at, identity: row.key, geographic_scope: "not_applicable")
          built.merge(
            "text" => reward_text(built.fetch("text"), row, locale),
            "points_cost" => row.cost, "deducts_points" => row.deducts_points?,
            "availability" => "available_at_check", "redemption_requires_account" => true
          )
        end

        def reward_text(text, row, locale)
          cost = row.cost
          return text unless cost.is_a?(Integer) && cost.positive?

          key = row.deducts_points? ? "cost" : "threshold"
          # "Cijena u bodovima: 20." agrees with every number; "20 bodova"
          # does not, and this text is never regenerated per number.
          plain_text("#{text} #{I18n.t("decidim_app.milica.rewards.#{key}", cost:, locale:)}", locale)
        end

        def reward_stock_filter(scope, now)
          table = Decidim::Bih::Goodwill::Reward.table_name
          holds = Decidim::Bih::Goodwill::RewardFulfillment.table_name
          scope.where(auto_issue_at_threshold: [false, nil])
               .where("#{table}.expires_at IS NULL OR #{table}.expires_at > ?", now)
               .where("#{table}.stock IS NULL OR #{table}.stock > (SELECT COUNT(*) FROM #{holds} WHERE " \
                      "#{holds}.decidim_organization_id = #{table}.decidim_organization_id AND #{holds}.reward_key = #{table}.key " \
                      "AND #{holds}.status NOT IN ('canceled', 'reversed'))")
        end

        def config_rewards(now)
          rows = Decidim::Bih::Goodwill::RewardsCatalog.config_rewards
          holds = Decidim::Bih::Goodwill::RewardFulfillment.where(organization: @organization, reward_key: rows.map(&:key))
                                                           .where.not(status: %w(canceled reversed)).group(:reward_key).count
          available = rows.reject(&:auto_issue_at_threshold?).select do |row|
            (row.expires_at.nil? || row.expires_at > now) && (row.stock.nil? || row.stock > holds.fetch(row.key, 0))
          end
          available.sort_by { |row| [row.cost, row.key] }.first(REWARD_POOL)
        end

        # Named optional fields make each public model adapter state its evidence explicitly.
        # rubocop:disable Metrics/ParameterLists
        def fact(record, kind:, title:, description:, path:, locale:, area: nil, starts_at: nil, ends_at: nil,
                 identity: nil, date_precision: false, geographic_scope: "unknown")
          {
            "id" => "#{kind}:#{identity || record.id}", "kind" => kind,
            "title" => plain_text(title, locale),
            "text" => plain_text([translated(title, locale), translated(description, locale)].compact_blank.join(": "), locale),
            "source_id" => "platform:#{kind}", "source_label" => SOURCE_LABEL,
            "source_url" => "https://#{@organization.host}#{path}", "destination" => path,
            "updated_at" => record&.updated_at&.iso8601,
            "coverage" => fact_coverage(area, geographic_scope),
            "validity" => fact_validity(starts_at, ends_at, date_precision)
          }
        end
        # rubocop:enable Metrics/ParameterLists

        def fact_coverage(area, geographic_scope)
          { "organization_id" => @organization.id, "area_slugs" => area ? [area.slug] : [],
            "geographic_scope" => area ? area.kind : geographic_scope, "relation" => area ? "located_in" : "unknown" }
        end

        # The label is a trailing line of the fact itself, like the catalog's
        # other source-owned qualifiers, and the body yields the room for it so
        # the city-wide disclosure can never be the part that is truncated.
        def citywide_fact(public_fact, locale)
          label = I18n.t("decidim_app.milica.activity.citywide", locale:)
          body = public_fact.fetch("text")[0, [MAX_TEXT - label.length - 1, 0].max]
          public_fact.merge("coverage" => public_fact.fetch("coverage").merge("geographic_scope" => CITYWIDE_SCOPE, "relation" => "covers_city"),
                            "text" => [body, label].reject(&:empty?).join("\n")[0, MAX_TEXT])
        end

        def fact_validity(starts_at, ends_at, date_precision)
          precision = "unknown"
          precision = date_precision ? "date" : "datetime" if starts_at || ends_at
          { "starts_at" => starts_at&.iso8601, "ends_at" => ends_at&.iso8601, "precision" => precision }
        end

        def translated(value, locale)
          return value unless value.is_a?(Hash)

          value[locale.to_s].presence || value[locale.to_s.split("-").first].presence || value["sr"].presence || value.values.compact_blank.first
        end

        def plain_text(value, locale)
          text = CGI.unescapeHTML(value.to_s.gsub(/<[^>]*>/, " ")).gsub(/\s+/, " ").strip
          localize(text, locale:)[0, MAX_TEXT]
        end

        def public_path(suffix)
          Decidim::Bih.public_path(suffix)
        end

        # The shared read-port envelope with a per-topic platform source.
        def result(status, topic:, coverage: nil, **values)
          source = { "id" => "platform:#{topic}", "label" => SOURCE_LABEL }
          if coverage && coverage["access"] == "public"
            source["url"] = public_path("volontiranje") if topic.to_s == "volunteer"
            source["url"] = "/processes" if topic.to_s == "participation"
            # A narrowed rewards answer has to say where the rest of the shelf
            # is, or narrowing it turns a short list into a wrong one.
            source["url"] = public_path("zajednistvo?tab=nagrade") if topic.to_s == "rewards"
          end
          super(status, source:, coverage:, **values)
        end
      end
    end
  end
end
