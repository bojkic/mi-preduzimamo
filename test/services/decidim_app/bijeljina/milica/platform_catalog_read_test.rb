# frozen_string_literal: true

require "test_helper"
# Decidim's EngineRouter resolves test URL defaults through Capybara even for
# path helpers. Load it explicitly; no browser or server is started here.
require "capybara"
require "decidim/budgets/test/factories"
require "decidim/meetings/test/factories"
require "decidim/proposals/test/factories"

module DecidimApp
  module Bijeljina
    module Milica
      class PlatformCatalogReadTest < ActiveSupport::TestCase
        setup do
          travel_to Time.utc(2026, 9, 9, 12)
          @organization = create_organization
          @other = create_organization
          @reader = PlatformCatalogRead.new(organization: @organization)
        end

        teardown do
          travel_back
        end

        test "permission and tenant mismatch stop before catalog reads" do
          [context(capabilities: []), context(organization: @other)].each do |trusted|
            Decidim::Bih::VolunteerOpportunity.stub(:publicly_visible, -> { raise "Must not query" }) do
              result = read("volunteer", context: trusted)
              assert_equal "not_authorized", result[:status]
              assert_empty result[:facts]
            end
          end
        end

        test "volunteer filtering excludes past hidden cancelled foreign rows before limiting" do
          10.times { |index| opportunity(title: "Expired #{index}", starts_at: 2.days.ago, ends_at: 1.day.ago) }
          opportunity(title: "Hidden", active: false)
          opportunity(title: "Pending", review_status: "pending")
          opportunity(title: "Cancelled", cancelled_at: Time.current)
          opportunity(title: "Foreign", organization: @other)
          opportunity(title: "Deadline closed", signup_deadline_at: 1.minute.ago)
          visible = opportunity(title: "Visible", description: "Public description")
          result = read("volunteer")
          assert_equal "ok", result[:status]
          assert_equal(["volunteer_opportunity:#{visible.id}"], result[:facts].map { |fact| fact["id"] })
          assert_equal "#{Decidim::Bih.public_path("volontiranje")}#volunteer-opportunity-#{visible.id}", result[:facts].first["destination"]
        end

        test "volunteer public capacity and location expose no signup identity" do
          visible = opportunity(capacity: 1, meeting_point: "Public park entrance", requirements: "Bring gloves")
          going = FactoryBot.create(:user, organization: @organization)
          waitlisted = FactoryBot.create(:user, organization: @organization)
          Decidim::Bih::VolunteerSignup.create!(organization: @organization, opportunity: visible, user: going,
                                                status: "going", review_status: "automatic", review_source: "automatic")
          Decidim::Bih::VolunteerSignup.create!(organization: @organization, opportunity: visible, user: waitlisted,
                                                status: "waitlisted", review_status: "automatic", review_source: "automatic",
                                                queued_at: Time.current)
          fact = read("volunteer")[:facts].first
          assert_equal "Public park entrance", fact["location"]
          assert_equal "Bring gloves", fact["requirements"]
          assert_equal 1, fact.dig("availability", "going_count")
          assert_equal 0, fact.dig("availability", "remaining_places")
          assert_equal "waitlist", fact.dig("availability", "status")
          assert_not_includes fact.to_json, going.email
          assert_not_includes fact.to_json, waitlisted.email
        end

        test "unlimited volunteer capacity remains open without inventing a numeric limit" do
          visible = opportunity(capacity: nil)
          going = FactoryBot.create(:user, organization: @organization)
          Decidim::Bih::VolunteerSignup.create!(organization: @organization, opportunity: visible, user: going,
                                                status: "going", review_status: "automatic", review_source: "automatic")

          result = read("volunteer")
          assert_equal "ok", result[:status]
          fact = result[:facts].find { |item| item["id"] == "volunteer_opportunity:#{visible.id}" }
          assert_nil fact.dig("availability", "capacity")
          assert_nil fact.dig("availability", "remaining_places")
          assert_equal 1, fact.dig("availability", "going_count")
          assert_equal "signup_open", fact.dig("availability", "status")
          assert_equal true, fact.dig("availability", "recheck_on_destination")
          assert_not_includes fact.to_json, going.email
        end

        test "requested local day uses half open windows and recurring weekday plus month" do
          tomorrow = Time.zone.parse("2026-09-10 00:00:00 +0200")
          excluded = opportunity(title: "Ends at day boundary", starts_at: tomorrow - 1.hour, ends_at: tomorrow)
          included = opportunity(title: "Overnight", starts_at: tomorrow - 1.hour, ends_at: tomorrow + 1.hour)
          recurring = opportunity(title: "Thursday recurring", starts_at: nil, ends_at: nil, day_keys: ["thursday"], month_keys: ["september"])
          opportunity(title: "Friday recurring", starts_at: nil, ends_at: nil, day_keys: ["friday"], month_keys: ["september"])
          result = read("volunteer", entities: { "time_expression" => "sutra" })
          ids = result[:facts].map { |fact| fact["id"] }
          assert_includes ids, "volunteer_opportunity:#{included.id}"
          assert_includes ids, "volunteer_opportunity:#{recurring.id}"
          assert_not_includes ids, "volunteer_opportunity:#{excluded.id}"
          assert_equal 2, ids.size
        end

        test "weekend volunteer range filters both days and eligibility before limit" do
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          10.times { |index| opportunity(title: "Weekday #{index}", starts_at: zone.local(2026, 9, 10, 10), ends_at: zone.local(2026, 9, 10, 11)) }
          saturday = opportunity(title: "Saturday", starts_at: zone.local(2026, 9, 12, 10), ends_at: zone.local(2026, 9, 12, 11))
          sunday = opportunity(title: "Sunday", starts_at: zone.local(2026, 9, 13, 10), ends_at: zone.local(2026, 9, 13, 11))
          opportunity(title: "Ends before weekend", starts_at: zone.local(2026, 9, 11, 23), ends_at: zone.local(2026, 9, 12))
          opportunity(title: "Monday boundary", starts_at: zone.local(2026, 9, 14), ends_at: zone.local(2026, 9, 14, 1))
          opportunity(title: "Closed registration", starts_at: sunday.starts_at, ends_at: sunday.ends_at, signup_deadline_at: 1.minute.ago)
          opportunity(title: "Foreign weekend", organization: @other, starts_at: sunday.starts_at, ends_at: sunday.ends_at)
          result = read("volunteer", entities: { "time_expression" => "ovog vikenda" })
          assert_equal([saturday, sunday].map { |row| "volunteer_opportunity:#{row.id}" }, result[:facts].map { |fact| fact["id"] })
          assert_equal({ "from" => "2026-09-12", "through" => "2026-09-13" }, result[:validity]["requested_dates"])
          assert_equal "Europe/Sarajevo", result[:validity]["timezone"]
        end

        test "next weekend resolves following the current or upcoming weekend and reports exact dates" do
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          opportunity(starts_at: zone.local(2026, 9, 12, 10), ends_at: zone.local(2026, 9, 12, 11))
          selected = opportunity(starts_at: zone.local(2026, 9, 20, 10), ends_at: zone.local(2026, 9, 20, 11))
          ["sljedeceg vikenda", "следећег викенда", "next weekend"].each do |expression|
            result = read("volunteer", entities: { "time_expression" => expression })
            assert_equal ["volunteer_opportunity:#{selected.id}"], result[:facts].map { |fact| fact["id"] }, expression
            assert_equal({ "from" => "2026-09-19", "through" => "2026-09-20" }, result[:validity]["requested_dates"])
          end
        end

        test "local Sunday retains current weekend but excludes elapsed Saturday occurrences" do
          travel_to Time.utc(2026, 9, 12, 22, 30) # Sunday 00:30 in Sarajevo, Saturday in UTC.
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          opportunity(starts_at: zone.local(2026, 9, 12, 20), ends_at: zone.local(2026, 9, 12, 21))
          opportunity(starts_at: nil, ends_at: nil, day_keys: ["saturday"], month_keys: ["september"])
          recurring = opportunity(starts_at: nil, ends_at: nil, day_keys: ["sunday"], month_keys: ["september"])
          result = read("volunteer", entities: { "time_expression" => "this weekend" })
          assert_equal(["volunteer_opportunity:#{recurring.id}"], result[:facts].map { |fact| fact["id"] })
          assert_equal "2026-09-12", result[:validity].dig("requested_dates", "from")
          assert result[:validity]["known_past_occurrences_excluded"]
        end

        test "recurring weekend matches weekday and month together across a month boundary" do
          travel_to Time.utc(2026, 10, 28, 12)
          saturday = opportunity(starts_at: nil, ends_at: nil, day_keys: ["saturday"], month_keys: ["october"])
          sunday = opportunity(starts_at: nil, ends_at: nil, day_keys: ["sunday"], month_keys: ["november"])
          opportunity(starts_at: nil, ends_at: nil, day_keys: ["sunday"], month_keys: ["october"])
          opportunity(starts_at: nil, ends_at: nil, day_keys: ["saturday"], month_keys: ["november"])
          result = read("volunteer", entities: { "time_expression" => "ovog vikenda" })
          assert_equal [saturday, sunday].map { |row| "volunteer_opportunity:#{row.id}" }.sort, result[:facts].map { |fact| fact["id"] }.sort
          assert_equal "2026-11-01", result[:validity].dig("requested_dates", "through")
        end

        test "spring clock change preserves local Monday exclusion and late Sunday inclusion" do
          travel_to Time.utc(2026, 3, 27, 12)
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          sunday = opportunity(starts_at: zone.local(2026, 3, 29, 23, 30), ends_at: zone.local(2026, 3, 29, 23, 59))
          opportunity(starts_at: zone.local(2026, 3, 30), ends_at: zone.local(2026, 3, 30, 1))
          result = read("volunteer", entities: { "time_expression" => "ovog vikenda" })
          assert_equal(["volunteer_opportunity:#{sunday.id}"], result[:facts].map { |fact| fact["id"] })
          assert_equal({ "from" => "2026-03-28", "through" => "2026-03-29" }, result[:validity]["requested_dates"])
        end

        test "weekend meeting and process overlap uses full range before limiting" do
          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          process = FactoryBot.create(:participatory_process, organization: @organization, published_at: Time.current,
                                                              private_space: false, start_date: Date.new(2026, 9, 13), end_date: Date.new(2026, 9, 20))
          component = FactoryBot.create(:meeting_component, participatory_space: process, published_at: Time.current)
          10.times do
            FactoryBot.create(:meeting, component:, published_at: Time.current, private_meeting: false,
                                        start_time: zone.local(2026, 9, 10, 10), end_time: zone.local(2026, 9, 10, 11))
          end
          meeting = FactoryBot.create(:meeting, component:, published_at: Time.current, private_meeting: false,
                                                start_time: zone.local(2026, 9, 13, 10), end_time: zone.local(2026, 9, 13, 11))
          FactoryBot.create(:meeting, component:, published_at: Time.current, private_meeting: false,
                                      start_time: zone.local(2026, 9, 14), end_time: zone.local(2026, 9, 14, 1))
          result = read("participation", entities: { "query" => "sastanci", "time_expression" => "ovog vikenda" })
          assert_equal(["public_meeting:#{meeting.id}"], result[:facts].map { |fact| fact["id"] })
          result = read("participation", entities: { "time_expression" => "ovog vikenda" })
          assert_includes result[:facts].map { |fact| fact["id"] }, "participatory_process:#{process.id}"
          assert_empty read("participation", entities: { "query" => "sastanci", "time_expression" => "next weekend" })[:facts]
        end

        test "unsupported or contradictory weekend ranges request clarification" do
          assert_equal "ambiguous", read("volunteer", entities: { "time_expression" => "sljedeca dva vikenda" })[:status]
          assert_equal "ambiguous", read("volunteer", entities: { "time_expression" => "sljedeca dva vikenda", "date" => "2026-09-12" })[:status]
          assert_equal "ambiguous", read("volunteer", entities: { "time_expression" => "ovog vikenda", "date" => "2026-09-20" })[:status]
          assert_equal "ambiguous", read("community", entities: { "time_expression" => "ovog vikenda" })[:status]
        end

        test "bare authored locality remains ambiguous and named MZ does not select overlapping komsiluk" do
          mz = area(kind: "mz", slug: "mz-authored-grove", name: "MZ Izmišljeni gaj")
          komsiluk = area(kind: "komsiluk", slug: "authored-grove-board", name: "Izmišljeni gaj (prijedlog)", primary_mz_slug: mz.slug)
          opportunity(komsiluk:)
          aliases = PlaceAliasRegistry.new(areas: [mz, komsiluk], config: {
            "revision" => "authored-catalogue-v1", "inflections" => { "izmisljeni gaj" => ["Izmišljenom gaju"] }
          })
          @reader = PlatformCatalogRead.new(organization: @organization,
            area_matcher: CityServiceAreaMatcher.new(organization: @organization, alias_registry: aliases))
          assert_equal "ambiguous", read("volunteer", entities: { "area_query" => "Izmišljenom gaju" })[:status]
          exact = read("volunteer", entities: { "area_slug" => komsiluk.slug })
          assert_equal 1, exact[:facts].size
          mz_result = read("volunteer", entities: { "area_slug" => mz.slug })
          assert_empty mz_result[:facts]
          assert_includes mz_result[:warnings], "mz_to_opportunity_crosswalk_not_reviewed"
        end

        test "public partner reads exclude private fields revoked and foreign profiles" do
          visible = profile(display_name: "Public association", public_description: "Public mission", private_contact_email: "private@example.invalid")
          profile(display_name: "Suspended", verification_status: "suspended")
          profile(display_name: "Foreign", organization: @other)
          result = read("community", entities: { "query" => "organizacije" })
          assert_equal(["partner_profile:#{visible.id}"], result[:facts].map { |fact| fact["id"] })
          assert_not_includes result.to_json, "private@example.invalid"
          assert_equal "unknown", result[:facts].first.dig("coverage", "geographic_scope")
          visible.update!(verification_status: "suspended")
          assert_empty read("community", entities: { "query" => "organizacije" })[:facts]
        end

        test "contribution needs require publication approval open state date and visible owner" do
          owner = profile
          visible = need(owner, title: "Needed equipment")
          need(owner, title: "Draft", published_at: nil)
          need(owner, title: "Future publication", published_at: 1.day.from_now)
          need(owner, title: "Rejected", review_status: "rejected")
          need(owner, title: "Fulfilled", fulfillment_status: "fulfilled")
          need(owner, title: "Expired", needed_by: Date.yesterday)
          result = read("community", entities: { "query" => "oprema" })
          assert_equal(["contribution_need:#{visible.id}"], result[:facts].map { |fact| fact["id"] })
          owner.update!(verification_status: "suspended")
          assert_empty read("community", entities: { "query" => "oprema" })[:facts]
        end

        test "community projects use approved public native text and configured hidden storage only" do
          process = FactoryBot.create(:participatory_process, organization: @organization, published_at: nil)
          component = FactoryBot.create(:budgets_component, participatory_space: process, published_at: Time.current)
          budget = FactoryBot.create(:budget, component:)
          Decidim::Bih::Setting.put(@organization, "community_projects", "budget_id", budget.id)
          project = FactoryBot.create(:project, budget:, title: { "sr" => "Public project" }, description: { "sr" => "Public approved text" })
          submission = Decidim::Bih::PartnerProjectSubmission.new(organization: @organization, partner_profile: profile,
                                                                  project:, title: "Private draft text", description: "Internal detail",
                                                                  budget_amount: 100, review_status: "approved")
          submission.save!(validate: false)
          link = Decidim::Bih::ProjectDonationLink.create!(organization: @organization, project:, campaign_key: "catalog-#{project.id}")
          result = read("community", entities: { "query" => "projekti" })
          assert_equal 1, result[:facts].size
          assert_includes result[:facts].first["text"], "Public project"
          assert_not_includes result.to_json, "Private draft text"
          assert_not_includes result.to_json, "Internal detail"
          link.update!(active: false)
          assert_empty read("community", entities: { "query" => "projekti" })[:facts]
          link.update!(active: true)
          process.update!(published_at: Time.current)
          assert_empty read("community", entities: { "query" => "projekti" })[:facts]
        end

        test "participation excludes unpublished private expired foreign and future publication processes" do
          visible = FactoryBot.create(:participatory_process, organization: @organization, published_at: Time.current,
                                                              private_space: false, start_date: Date.current, end_date: Date.tomorrow)
          [{ published_at: nil }, { private_space: true }, { end_date: Date.yesterday, start_date: 2.days.ago.to_date },
           { organization: @other }, { published_at: 1.day.from_now }].each do |attrs|
            FactoryBot.create(:participatory_process, organization: @organization, published_at: Time.current, private_space: false,
                                                      start_date: Date.current, end_date: Date.tomorrow, **attrs)
          end
          result = read("participation")
          assert_equal(["participatory_process:#{visible.id}"], result[:facts].map { |fact| fact["id"] })
        end

        test "public meetings and proposals preserve component and parent visibility" do
          process = FactoryBot.create(:participatory_process, organization: @organization, published_at: Time.current,
                                                              private_space: false, start_date: Date.current, end_date: Date.tomorrow)
          meetings = FactoryBot.create(:meeting_component, participatory_space: process, published_at: Time.current)
          proposals = FactoryBot.create(:proposal_component, participatory_space: process, published_at: Time.current)
          meeting = FactoryBot.create(:meeting, component: meetings, published_at: Time.current,
                                                private_meeting: false, start_time: 1.hour.from_now, end_time: 2.hours.from_now,
                                                address: "Public hall, Bijeljina", location: { "sr" => "Main room" })
          proposal = FactoryBot.create(:proposal, component: proposals, published_at: Time.current, withdrawn_at: nil)
          meeting_fact = read("participation", entities: { "query" => "sastanci" })[:facts].first
          assert_equal "Public hall, Bijeljina", meeting_fact["address"]
          assert_equal "/processes/#{process.slug}/f/#{meetings.id}/meetings/#{meeting.id}", meeting_fact["destination"]
          proposal_fact = read("participation", entities: { "query" => "prijedlozi" })[:facts].first
          assert_equal "/processes/#{process.slug}/f/#{proposals.id}/proposals/#{proposal.id}", proposal_fact["destination"]
          assert_equal(["public_meeting:#{meeting.id}"], read("participation", entities: { "query" => "sastanci" })[:facts].map { |fact| fact["id"] })
          assert_equal(["public_proposal:#{proposal.id}"], read("participation", entities: { "query" => "prijedlozi" })[:facts].map { |fact| fact["id"] })
          proposal.update!(withdrawn_at: Time.current)
          assert_empty read("participation", entities: { "query" => "prijedlozi" })[:facts]
          process.update!(start_date: 2.days.ago.to_date, end_date: 1.day.ago.to_date)
          assert_equal(["public_meeting:#{meeting.id}"], read("participation", entities: { "query" => "sastanci" })[:facts].map { |fact| fact["id"] })
          process.update!(private_space: true)
          assert_empty read("participation", entities: { "query" => "sastanci" })[:facts]
          process.update!(private_space: false)
          meetings.update!(published_at: nil)
          assert_empty read("participation", entities: { "query" => "sastanci" })[:facts]
        end

        test "rewards exclude threshold exhausted expired inactive and foreign items before limit" do
          10.times { |index| reward(key: "empty-#{index}", stock: 0, cost: 1) }
          reward(key: "threshold", auto_issue_at_threshold: true)
          reward(key: "expired", expires_at: Time.current)
          reward(key: "inactive", active: false)
          reward(key: "foreign", organization: @other)
          visible = reward(key: "available", title: { "sr" => "Available reward" })
          result = read("rewards")
          assert_equal(["reward:#{visible.key}"], result[:facts].map { |fact| fact["id"] })
          assert_equal true, result[:facts].first["redemption_requires_account"]
        end

        # Task 7: a rewards answer that does not say the price answers nothing.
        # The cost is in the sentence a citizen reads, not only in a field.
        test "a reward states its point cost in its own text" do
          reward(key: "majica", title: { "sr" => "MI! majica" }, description: { "sr" => "Majica zajednice." }, cost: 250)
          fact = read("rewards")[:facts].find { |row| row["id"] == "reward:majica" }

          assert_equal 250, fact["points_cost"]
          assert_includes fact["text"], "MI! majica"
          assert_includes fact["text"], I18n.t("decidim_app.milica.rewards.cost", cost: 250, locale: :sr)
        end

        test "a reward that does not deduct points states a threshold not a price" do
          reward(key: "priznanje", title: { "sr" => "Godišnje priznanje" }, cost: 400, deducts_points: false)
          fact = read("rewards")[:facts].find { |row| row["id"] == "reward:priznanje" }

          assert_equal false, fact["deducts_points"]
          assert_includes fact["text"], I18n.t("decidim_app.milica.rewards.threshold", cost: 400, locale: :sr)
          assert_not_includes fact["text"], I18n.t("decidim_app.milica.rewards.cost", cost: 400, locale: :sr)
        end

        test "held reward stock is excluded and cancellation releases stock" do
          record = reward(key: "held", stock: 1)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          transaction = Decidim::Bih::Goodwill::Ledger.new.award(user, 100, reason: "proposal")
          hold = Decidim::Bih::Goodwill::RewardFulfillment.create!(organization: @organization, user:, ledger_transaction: transaction,
                                                                   reward_key: record.key, cost: record.cost, status: "requested")
          assert_empty read("rewards")[:facts]
          hold.update!(status: "canceled")
          assert_equal(["reward:held"], read("rewards")[:facts].map { |fact| fact["id"] })
        end

        test "unknown area never widens to citywide and missing facility data stays explicit" do
          opportunity
          assert_empty read("volunteer", entities: { "area_query" => "Unknown district" })[:facts]
          facilities = read("facilities")
          assert_empty facilities[:facts]
          assert_includes facilities[:warnings], "facility_registry_not_reviewed"
          assert_equal "ambiguous", read("volunteer", entities: { "date" => "2026-02-30" })[:status]
          assert_includes read("volunteer", entities: { "time_expression" => "next millennium" })[:warnings], "unsupported_catalog_time"
        end

        test "a komsiluk question answers with city-wide opportunities after the local ones" do
          komsiluk = area(kind: "komsiluk", slug: "komsiluk-dvorovi", name: "Dvorovi")
          citywide = opportunity(title: "Gradska akcija", starts_at: 1.hour.from_now, ends_at: 2.hours.from_now)
          local = opportunity(title: "Komsijska akcija", komsiluk:, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 1.hour)

          result = read("volunteer", entities: { "area_slug" => komsiluk.slug })

          assert_equal(["volunteer_opportunity:#{local.id}", "volunteer_opportunity:#{citywide.id}"], result[:facts].map { |fact| fact["id"] })
          assert_equal "Za cijelu Bijeljinu", citywide_label
          assert_includes result[:facts].last["text"], citywide_label
          assert_equal "citywide", result[:facts].last.dig("coverage", "geographic_scope")
          assert_equal "covers_city", result[:facts].last.dig("coverage", "relation")
          assert_empty result[:facts].last.dig("coverage", "area_slugs")
          assert_not_includes result[:facts].first["text"], citywide_label
          assert_equal(["komsiluk-dvorovi"], result[:facts].first.dig("coverage", "area_slugs"))
          assert_equal "located_in", result[:facts].first.dig("coverage", "relation")
        end

        test "a city-wide question is unchanged and a cancelled city-wide row stays out of both answers" do
          komsiluk = area(kind: "komsiluk", slug: "komsiluk-dvorovi", name: "Dvorovi")
          visible = opportunity(title: "Gradska akcija")
          opportunity(title: "Otkazana", cancelled_at: Time.current)
          opportunity(title: "Skrivena", active: false)

          result = read("volunteer")

          assert_equal(["volunteer_opportunity:#{visible.id}"], result[:facts].map { |fact| fact["id"] })
          assert_equal "unknown", result[:facts].first.dig("coverage", "geographic_scope")
          assert_equal "unknown", result[:facts].first.dig("coverage", "relation")
          assert_not_includes result[:facts].first["text"], citywide_label
          scoped = read("volunteer", entities: { "area_slug" => komsiluk.slug })
          assert_equal(["volunteer_opportunity:#{visible.id}"], scoped[:facts].map { |fact| fact["id"] })
        end

        test "an MZ question answers with city-wide opportunities and keeps the crosswalk warning" do
          mz = area(kind: "mz", slug: "mz-authored-grove", name: "MZ Izmišljeni gaj")
          elsewhere = area(kind: "komsiluk", slug: "komsiluk-drugi", name: "Drugi")
          citywide = opportunity(title: "Gradska akcija")
          opportunity(title: "Tudja komsijska", komsiluk: elsewhere)

          result = read("volunteer", entities: { "area_slug" => mz.slug })

          assert_equal(["volunteer_opportunity:#{citywide.id}"], result[:facts].map { |fact| fact["id"] })
          assert_includes result[:facts].first["text"], citywide_label
          assert_includes result[:warnings], "mz_to_opportunity_crosswalk_not_reviewed"
        end

        private

        def citywide_label
          I18n.t("decidim_app.milica.activity.citywide", locale: "sr")
        end

        def read(topic, entities: {}, context: self.context)
          @reader.call(topic:, entities:, context:, locale: "sr")
        end

        def context(organization: @organization, capabilities: ["public_reads"])
          Decidim::Bih::Concierge::Dialogue::Contracts::TrustedContext.new(
            organization_id: organization.id, conversation_key: "c" * 64, capabilities:, now: Time.current
          )
        end

        def opportunity(**attributes)
          Decidim::Bih::VolunteerOpportunity.create!(organization: @organization, title: "Volunteering", active: true, review_status: "approved",
                                                     starts_at: 1.day.from_now, ends_at: 1.day.from_now + 1.hour, **attributes)
        end

        def profile(**attributes)
          Decidim::Bih::PartnerProfile.create!(organization: @organization, display_name: "Public owner", slug: "owner-#{SecureRandom.hex(4)}",
                                               kind: "association", verification_status: "verified", verified_at: Time.current, **attributes)
        end

        def need(owner, **attributes)
          # Historical moderation fixtures intentionally avoid author workflow;
          # the reader must enforce public lifecycle independently of callbacks.
          row = Decidim::Bih::ContributionNeed.new(organization: owner.organization, partner_profile: owner, need_type: "equipment", title: "Public need",
                                                   description: "Public request", quantity: 1, unit: "kom", review_status: "approved", fulfillment_status: "open",
                                                   published_at: 1.hour.ago, needed_by: Date.tomorrow, **attributes)
          row.save!(validate: false)
          row
        end

        def reward(**attributes)
          Decidim::Bih::Goodwill::Reward.create!(organization: @organization, key: "reward-#{SecureRandom.hex(4)}", title: { "sr" => "Reward" }, cost: 100, active: true,
                                                 **attributes)
        end

        def area(kind:, slug:, name:, **attributes)
          Decidim::Bih::LocalArea.create!(organization: @organization, kind:, slug:, name: { "sr" => name }, **attributes)
        end
      end
    end
  end
end
