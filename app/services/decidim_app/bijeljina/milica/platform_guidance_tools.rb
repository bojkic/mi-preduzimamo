# frozen_string_literal: true

require_relative "foundation_read"

module DecidimApp
  module Bijeljina
    module Milica
      # Explicit public policy projection. These are source facts, not routed
      # answers: no PublicInformation/Responder invocation or account records.
      class PlatformGuidanceTools
        SUBJECTS = %w(feedback points voting reports account privacy notifications installation platform proposals neighborhood messaging launch race).freeze
        READ_SUBJECTS = (SUBJECTS + %w(overview)).freeze
        POLICY = {
          "feedback" => {
            "voluntary" => true, "choices" => ["Korisno", "Nije korisno"],
            "rating_subject" => "one Milica reply", "identity_scope" => "reply_id and browser session digest; not account linked",
            "can_change" => true, "change_method" => "choose the other rating button for the same reply in the same session",
            "not_automatic_training" => true, "publicly_visible" => false,
            "review_access" => "authorized platform improvement review",
            "transcript_capture" => { "trigger" => "explicit feedback click", "fields" => %w(citizen_message bot_reply_text),
                                      "question_max_characters" => 1000, "reply_max_characters" => 4000,
                                      "credential_pattern_detection" => "If credential-like text is detected, the transcript is omitted; this is not a personal-name detector or anonymizer.",
                                      "personal_names_automatically_removed" => false,
                                      "all_personal_text_absent_guaranteed" => false,
                                      "citizen_explanation" => "Ocjena može sačuvati pitanje i odgovor za privatni pregled. Nije povezana s nalogom, ali ime ili drugi lični podatak u tekstu može ostati sačuvan. Nemoj unositi privatne podatke." },
            "source_refs" => ["engine:app/controllers/decidim/bih/concierge/web_chat_controller.rb",
                              "engine:app/models/decidim/bih/concierge_feedback.rb", "engine:lib/decidim/bih/privacy_audit_contracts.rb"]
          },
          "points" => {
            "recognition_not_voting_power" => true, "personal_balance_included" => false,
            "redemption" => { "where" => "Open rewards_catalog, choose an eligible reward and explicitly confirm redemption on the site while signed in.",
                              "requirements" => "Server checks sufficient points, availability, expiry, stock and reward-specific conditions.",
                              "chat_redeems_reward" => false, "personal_eligibility_included" => false,
                              "automatic_rewards" => "Some rewards are issued automatically at their threshold and cannot be manually redeemed." },
            "volunteer_hours_require_operator_confirmation" => true,
            "hour_approval_authority" => "A platform operator/admin separately authorized to review hour logs approves the hours; attendance authority alone is insufficient",
            "public_notice_proves_personal_receipt" => false,
            "volunteer_signup_awards_points" => false,
            "attendance_confirmation" => "An organizer or operator authorized for attendance records who attended, manually or with the operator QR. Attendance confirmation does not approve hours",
            "attendance_automatically_approves_reported_hours" => false,
            "volunteer_hours_sequence" => ["Citizen records actual hours", "Authorized hours reviewer approves work",
                                           "Base points once per approved Sarajevo calendar day; organization hourly bonus remains separate"],
            "report_points_policy" => "Registered attributed anonymous and identified reports use the same scale on every enabled channel; ordinary " \
                                      "reports, duplicate/corroboration and rejected reports have different outcomes. Unattributed reports receive no " \
                                      "personal points. Daily report limits still apply.",
            "public_recognition" => "Enabled by default, with an account opt-out. Opt-out hides individual public recognition without changing wallet or " \
                                    "race. Administrators and active BIH operators are excluded from individual public recognition, but may contribute to " \
                                    "the race.",
            "corrections" => "Source review can correct recognized contribution and wallet; a recovery that would make the wallet negative " \
                             "requires administrator review. History records the reason; citizens may dispute a specific entry through Contact.",
            "referral_eligibility" => "Verified phone plus selected neighbourhood is sufficient; no additional post is required. Eligible referrals above " \
                                      "the monthly paid cap carry forward in order.",
            "proposal_limit" => "One personal proposal award per Sarajevo calendar month; additional submissions remain allowed. Race proposal caps are separate.",
            "report_vs_proposal_rejection" => "Rejected reports earn no points. A public citizen proposal not selected for implementation is not the same as hidden " \
                                              "or deleted prohibited content.",
            "source_refs" => ["engine:app/services/decidim/bih/goodwill/earning_rules.rb", "engine:app/controllers/decidim/bih/rewards_controller.rb",
                              "engine:app/commands/decidim/bih/goodwill/redeem_reward.rb", "engine:config/routes.rb",
                              "engine:app/services/decidim/bih/confirm_volunteer_attendance.rb",
                              "engine:app/controllers/decidim/bih/admin/volunteering_controller.rb",
                              "engine:app/controllers/decidim/bih/admin/goodwill_controller.rb", "engine:app/services/decidim/bih/verify_volunteer_log.rb"]
          },
          "voting" => {
            "points_required" => false, "points_change_vote_weight" => false, "donations_change_vote_weight" => false,
            "points_change_proposal_rank_or_content_visibility" => false, "participation_requirements" => "defined by the individual voting process",
            "source_refs" => ["engine:config/locales/decidim_bih_dialogue.yml"]
          },
          "reports" => {
            "preview_is_submission" => false, "explicit_confirmation_required" => true, "receipt_required_for_success_claim" => true,
            "description_location_photo" => "channel and authenticated permissions apply; collect only necessary information",
            "anonymous_contact" => "Anonymous means contact is withheld from the city; it does not erase a trusted account link or reduce points. " \
                                   "Reporter names are not public on report cards. Typed contact details cannot select an account author.",
            "channel_attribution" => "An authenticated provider sender with a unique currently granted phone match, or a verified active channel " \
                                     "connection to an eligible account, may attribute a confirmed report. This alone does not authorize private account " \
                                     "reads or bypass the independent report switches and exact preview confirmation.",
            "public_fields" => %w(reference category problem_address map_point status date),
            "private_fields" => %w(description photo contact), "private_field_access" => "authorized operators and responsible service",
            "public_map_point" => "exact submitted problem location; not blurred; may identify a home",
            "statuses" => { "Primljeno" => "received by platform; does not establish forwarding to city service",
                            "Čekamo dopunu" => "staff requested more information from the citizen; not a city submission",
                            "U pregledu" => "staff review, including review of newly supplied information; not city processing",
                            "Pregledano" => "validated by staff but not yet sent to services",
                            "Plansko / dugoročno" => "retained for a collective planned submission; not already sent",
                            "Duplikat — povezana prijava" => "linked to the main report; follow that report for progress",
                            "Poslato službi" => "forwarding accepted after operator review", "Riješeno" => "resolved status; no promised repair deadline" },
            "resolution_deadline_guaranteed" => false,
            "chat_preparation" => {
              "available_workflow" => "prepare_report can collect or correct a problem description and supplied address/place; it does not submit a report.",
              "required_details" => %w(problem_description problem_location),
              "location" => "A typed problem address is allowed; device location requires explicit consent and is not mandatory.",
              "submission_boundary" => "A chat preview and confirmation are available only when the separate report submission workflow is enabled for this channel. Otherwise finish using report_form.",
              "success" => "Only an actual submission receipt establishes a submitted report; neither chat prose, a prepared draft nor an offered link does.",
              "web_form_alternative" => "Open report_form to review and submit using the existing form."
            },
            "recovery" => {
              "scope" => "Biće riješeno! platform reports, not city administrative cases or proof of forwarding to Sistem 48",
              "without_reference" => "Browse public_reports without signing in; use category/status filters and compare the public address and date on report cards.",
              "public_index_filters" => %w(category status), "public_search_field" => "report reference only; not address, description or reporter name",
              "public_index_order" => "newest first, with pagination", "public_match_proves_ownership" => false,
              "my_reports" => "Sign in with the account used to submit, then open my_reports; only reports linked to that account appear.",
              "my_reports_requires_sign_in" => true, "sign_in_links_previously_signed_out_reports" => false,
              "reference_recovery" => "report_recovery requires the report reference and opens public status only; it does not recover the private status link.",
              "private_status_access" => "Use a previously saved private status link, or an owned report opened from my_reports; never paste private links or tokens into chat.",
              "new_report_required_to_find_existing" => false, "specific_report_found_by_this_guidance" => false,
              "city_administrative_case" => "Platform report references do not establish city case status. For a case filed directly with the city, use the responsible city office and its own case reference."
            },
            "source_refs" => ["app:app/services/decidim_app/bijeljina/milica/report_conversation.rb", "app:app/services/decidim_app/bijeljina/milica/chat_report_intake.rb",
                              "app:app/services/decidim_app/bijeljina/milica/workflow_proposals.rb", "app:app/services/decidim_app/bijeljina/web_concierge.rb",
                              "engine:app/services/decidim/bih/concierge/dialogue/procedures/report_problem.rb",
                              "engine:app/controllers/decidim/bih/reports_controller.rb", "engine:app/views/decidim/bih/reports/index.html.erb",
                              "engine:config/routes.rb", "engine:app/models/decidim/bih/report.rb", "engine:app/views/decidim/bih/reports/new.html.erb",
                              "engine:config/locales/sr.yml", "engine:config/locales/decidim_bih_dialogue.yml"]
          },
          "account" => {
            "public_transport_information_requires_account" => false, "chat_creates_account" => false,
            "private_information_requires_current_authorization" => true,
            "without_smartphone" => "Citizens may open the platform on a computer and themselves enter a code from their own SMS-capable phone. No " \
                                    "account-opening assistance service is offered; verification is not bypassed.",
            "address_processing" => "Registration neighbourhood lookup does not retain the typed home address. Postal verification separately processes a " \
                                    "mailing address temporarily. Submitted problem addresses and exact map points are public report data.",
            "passwords_and_verification_codes_in_chat" => "never request",
            "missing_verification_message" => { "actions_on_pending_page" => %w(check_number wait_one_minute request_resend),
                                                "code_entry" => "verification page code field, never chat",
                                                "resend_invalidates_previous_link_and_code" => true,
                                                "guidance_sends_message_or_authenticates" => false },
            "source_refs" => ["app:app/services/decidim_app/bijeljina/milica/registration_port.rb", "engine:app/services/decidim/bih/concierge/dialogue/contracts.rb",
                              "engine:app/controllers/decidim/bih/phone_verification_controller.rb",
                              "engine:app/controllers/concerns/decidim/bih/phone_verification_actions.rb", "engine:config/locales/decidim_bih_dialogue.yml"]
          },
          "notifications" => {
            "browser_permission_required_for_push" => true, "valid_device_subscription_required" => true,
            "delivery_guaranteed" => false, "settings_are_not_device_receipt" => true,
            "topics" => { "report_updates" => "Novosti o mojim prijavama", "community_news" => "Novosti i poruke zajednice",
                          "platform_news" => "Novosti platforme", "neighborhood_info" => "Obavještenja iz komšiluka i servisne informacije" },
            "topic_choice_is_all_channel_subscription" => false,
            "source_refs" => ["engine:app/controllers/decidim/bih/web_push_subscriptions_controller.rb",
                              "engine:app/services/decidim/bih/web_push.rb", "engine:app/services/decidim/bih/topic_preferences.rb"]
          },
          "installation" => {
            "iphone" => "Open site in Safari; Share; Add to Home Screen. Then open the installed app. Installation and opening alone do not grant notification permission. Use the notification enable action, accept the browser permission prompt, and register this device subscription; denied permission must be changed in device/browser settings.",
            "android" => "Use the browser install/add-to-home-screen action when available.",
            "installation_is_notification_permission" => false,
            "push_requirements" => "Browser notification permission AND a valid subscription on this device are required. Topic preferences do not substitute for either. Delivery is not guaranteed.",
            "source_refs" => ["engine:public/mi/mi-install.js"]
          },
          "neighborhood" => {
            "mz_and_komsiluk_are_distinct" => true, "public_area_geography_requires_membership" => false,
            "private_board_visibility" => "requires the existing authenticated membership/access policy",
            "posting_requires_authorization" => true, "neighborhood_picker_requires_authentication" => true,
            "opening_picker_changes_assignment" => false, "guide_requires_authentication" => false,
            "guide_scope" => "The public guide is a capability index, not step-by-step account-area-change instructions. Use the authenticated neighborhood_picker to change the selected area; opening it alone changes nothing.",
            "posting" => {
              "read_requirements" => "Sign in with an account in this organization and have an assigned komšiluk; the board is not a public MZ directory.",
              "write_requirements" => "Posting additionally requires granted phone verification; being signed in alone does not prove posting permission.",
              "steps" => "Open neighborhood_board or neighborhood_post_form, choose a category, enter a title and body, then submit the form yourself.",
              "form_location" => "The new-post form is on the board page; there is no separate new-post page.",
              "chat_action" => "neighborhood_action can hand off to the board. Chat does not publish the post, select an audience or bypass permissions.",
              "audience" => "The ordinary board shows visible posts in the citizen's assigned komšiluk, not all neighborhoods or a public member list.",
              "already_signed_in" => "Use the existing board/form directly; registration is not required again. The server still checks phone verification and neighborhood assignment."
            },
            "source_refs" => ["app:app/services/decidim_app/bijeljina/milica/read_port.rb",
                              "engine:app/controllers/decidim/bih/komsiluk_controller.rb", "engine:app/controllers/decidim/bih/onboarding_controller.rb",
                              "engine:app/controllers/decidim/bih/komsiluk_board_controller.rb", "engine:app/controllers/concerns/decidim/bih/requires_komsiluk_membership.rb",
                              "engine:app/views/decidim/bih/komsiluk_board/index.html.erb", "engine:app/views/decidim/bih/onboarding/guide.html.erb", "engine:config/routes.rb",
                              "app:app/services/decidim_app/bijeljina/milica/workflow_proposals.rb",
                              "engine:app/services/decidim/bih/concierge/dialogue/procedures/komsiluk.rb"]
          },
          "messaging" => {
            "ordinary_chat_sends_external_sms_email_viber" => false, "in_chat_reply_is_external_send" => false,
            "verification_delivery" => "only the protected verification workflow requests delivery; chat prose is not a receipt",
            "source_refs" => ["engine:config/locales/decidim_bih_dialogue.yml"]
          }
        }.freeze

        OVERVIEW_SUMMARIES = {
          "feedback" => { "rating" => "Voluntary Korisno/Nije korisno on one reply; can be changed in the same session.",
                          "privacy_boundary" => "A click may save question/reply text for private review, including personal text; no automatic training or public display." },
          "points" => { "earning_boundary" => "Volunteer sign-up and attendance alone do not award points; approved hours do. Points do not weight votes.",
                        "personal_balance_included" => false },
          "voting" => { "rule" => "Points and donations do not weight votes; each process defines participation rules." },
          "reports" => { "submission_boundary" => "A draft or preview is not submitted. Only explicit confirmation and a receipt establish submission.",
                         "location_boundary" => "The submitted exact map point is public; remembered chat location must never become a report point without a citizen-confirmed preview.",
                         "private_fields" => %w(description photo contact) },
          "account" => { "authorization_boundary" => "Private account information requires current authorization; never request passwords or verification codes in chat." },
          "privacy" => { "policy" => "Read the published privacy policy for legal basis, retention, recipients and rights; do not infer guarantees." },
          "notifications" => { "delivery_boundary" => "A topic choice is not a device subscription or proof of delivery; permission and a valid device subscription are required." },
          "installation" => { "boundary" => "Installing the app does not grant push permission or register a device subscription." },
          "platform" => { "identity" => "MI PRE(D)UZIMAMO! is operated by Lokalna fondacija Bijeljina; foundation support is not municipal-service authority.",
                          "coverage_complete" => false },
          "proposals" => { "boundary" => "Use the existing proposal form and its authorization checks; chat does not submit a proposal." },
          "neighborhood" => { "boundary" => "The public guide and area geography are available without membership; board access and posting follow account, area and phone-verification rules." },
          "messaging" => { "boundary" => "Ordinary chat guidance sends no SMS, email or Viber message; verification delivery is a separate protected workflow." },
          "launch" => { "boundary" => "Read launch for current reward threshold, expiry and attendance details; this summary has no personal invitation status." },
          "race" => { "boundary" => "Read race for current rules and timestamped cached standings; this summary has no personal points or live standings." }
        }.freeze

        def initialize(organization:)
          @organization = organization
        end

        def call(subject:, context:)
          unless context.organization_id == @organization.id && context.allows?("public_reads")
            raise PublicToolEvidence::Dialogue::Contracts::Invalid,
                  "Public guidance scope required"
          end
          raise PublicToolEvidence::Dialogue::Contracts::Invalid, "Unknown public guidance" unless READ_SUBJECTS.include?(subject)

          facts = if subject == "overview"
                    overview
                  else
                    POLICY.fetch(subject, {}).merge(dynamic_facts(subject, now: context.now) || {}).merge(public_links(subject))
                  end
          facts.merge!(foundation_identity(context:)) if subject == "platform"
          url = public_url(subject)
          fact = { "id" => "platform:#{subject}", "source_id" => "platform:#{subject}", "text" => "Public platform policy: #{subject}",
                   "policy" => facts, "source_url" => url, "warning_codes" => ["public_policy_not_personal_account_status"] }.compact
          { status: "ok", facts: [fact], warnings: ["public_policy_not_personal_account_status"] }
        end

        private

        # A bounded public capability index for the universal prefetch. The
        # detail reader remains authoritative for exact amounts, processes,
        # limits, current source status and personal/account questions.
        # This method deliberately does not query foundation, race or reward
        # sources on every citizen turn.
        def overview
          # Keep every public guidance subject discoverable. Links are generated
          # by the existing route helpers so paths stay in sync with the app.
          subjects = (READ_SUBJECTS - ["overview"]).to_h do |subject|
            entry = OVERVIEW_SUMMARIES.fetch(subject).deep_dup.merge("detail_subject" => subject)
            routes = public_links(subject).fetch("public_routes")
            entry = entry.merge("public_routes" => routes) unless routes.empty?
            [subject, entry]
          end
          { "subjects" => subjects,
            "detail_reader" => "This overview supports only its stated summary claims. Read the named guidance subject for exact policy, current amounts, source references or process steps. Read public domain tools for transport, service notices, procedures, schedules and other civic facts.",
            "scope" => "Public capability and safety summary only; no personal state, action receipt, live source inventory or absent-source claim. A current eligible read is required for a specific factual answer.",
            "lookup_outcomes" => "Ambiguous means unresolved selection; unsupported, unavailable, unreviewed or stale does not prove absence. Only an eligible empty result supports no matches within its declared scope; partial results never prove global absence." }
        end

        def foundation_identity(context:)
          result = FoundationRead.new(organization: @organization).read_facet(facet: "identity", context:, locale: "sr")
          identity = result[:status] == "ok" ? Array(result[:facts]).first : nil
          { "foundation_reference_status" => result[:status], "foundation_role" => identity&.fetch("text"),
            "foundation_role_source_url" => identity&.fetch("source_url"), "foundation_role_reviewed_on" => identity&.fetch("reviewed_on"),
            "role_scope" => "Foundation community support and MI platform funding are separate facts; neither establishes municipal-service authority or a currently open grant." }.compact
        end

        def dynamic_facts(subject, now:)
          case subject
          when "launch"
            launch_facts
          when "race"
            config = Decidim::Bih::Race::Config.new(organization: @organization)
            { "window_from" => config.window_from.iso8601, "window_to_exclusive" => config.window_to.iso8601,
              "timezone" => Decidim::Bih::Race::Config::TIME_ZONE, "weights" => config.weights, "per_person_caps" => config.caps,
              "report_policy" => { "eligible_ordinary_points" => config.weights.fetch(:report),
                                   "duplicate_points" => 0, "rejected_points" => 0, "corroboration_points" => 0,
                                   "requirements" => %w(trusted_registered_author verified_phone race_membership competition_window report_cap),
                                   "anonymous_contact_uses_same_eligibility" => true, "anonymous_contact_changes_points" => false },
              "changes_vote_weight" => false, "standings" => cached_standings(now:),
              "source_refs" => ["engine:app/services/decidim/bih/race/config.rb", "engine:app/services/decidim/bih/race/standings.rb",
                                "engine:app/services/decidim/bih/race/scorer.rb", "engine:app/services/decidim/bih/race/review.rb",
                                "engine:app/models/decidim/bih/race/standing.rb"] }
          when "points"
            points_facts
          when "platform"
            { "name" => "MI PRE(D)UZIMAMO!", "operator" => Decidim::Bih.public_support_name, "email" => Decidim::Bih.public_support_email,
              "operator_website" => Decidim::Bih.public_support_website, "address" => Decidim::Bih.public_support_address,
              "platform_home" => absolute_public_url("/"),
              "route_purposes" => "platform_home is the MI platform to share/join; project_catalog is the public MI project browser even if no current project row is returned; rewards_catalog is for points, not projects; operator_website is the foundation website, not the project catalogue or MI account.",
              "inviting_neighbors" => "Share #{absolute_public_url("/")}; neighbors register/choose their own area. Sharing sends nothing and creates no account/membership. Personal referral links/status require an authorized own-account read.",
              "funding_statement" => configured(:public_funding_statement, locale: "sr"),
              "data_scope" => { "reviewed_domains" => %w(service_directory procedures waste_schedule parking budget gazette local_areas service_notices),
                                "integrations" => { "Gemini" => "language assistance when enabled", "Infobip" => "Viber and SMS verification transport",
                                                    "Odoo" => "cached public donation data", "Sistem 48" => "report workflow",
                                                    "geocoder" => "address and local-area lookup" },
                                "coverage_complete" => false, "freshness" => "per-source review and check time; unavailable or expired evidence is qualified",
                                "limits" => %w(incomplete_procedure_inventory partial_waste_street_crosswalk reviewed_service_notices_only),
                                "operational_source_health_included" => false },
              "source_refs" => ["engine:lib/decidim/bih.rb", "app:config/initializers/decidim_bih_bijeljina_defaults.rb",
                                "app:app/services/decidim_app/bijeljina/bot_data_status.rb"] }.compact
          when "privacy"
            { "name" => "MI PRE(D)UZIMAMO!", "operator" => Decidim::Bih.public_support_name, "contact_email" => Decidim::Bih.public_support_email,
              "details" => "Use the published privacy policy for legal basis, retention, recipients and access/correction/deletion rights; no inferred guarantees.",
              "source_refs" => ["engine:config/locales/decidim_bih_dialogue.yml"] }.compact
          when "proposals"
            { "submission_path" => configured(:proposal_path), "chat_submission" => false, "existing_form_authorization_applies" => true,
              "source_refs" => ["engine:lib/decidim/bih.rb"] }.compact
          end
        end

        def launch_facts
          reward = Decidim::Bih::Goodwill::LaunchInvitation.reward_for(@organization)
          { "available_reward" => reward.present? && !reward.expired?, "threshold_points" => reward&.cost, "issuance_expires_at" => reward&.expires_at&.iso8601,
            "points_deducted" => reward&.deducts_points?, "issued_automatically_when_eligible" => reward&.auto_issue_at_threshold?,
            "attendance_confirmation_window_hours" => Decidim::Bih::Goodwill::LaunchInvitation::CONFIRMATION_WINDOW / 1.hour,
            "personal_invitation_included" => false, "existing_invitation_validity_is_not_issuance_deadline" => true,
            "source_refs" => ["engine:app/services/decidim/bih/goodwill/launch_invitation.rb"] }
        end

        def points_facts
          rules = Decidim::Bih::Goodwill::EarningRules.new(organization: @organization)
          { "schedule" => rules.public_schedule,
            "daily_caps" => rules.public_schedule.keys.select { |key| rules.cap_period_for(key) == :day }.index_with { |key| rules.cap_for(key) }.compact,
            "monthly_caps" => rules.public_schedule.keys.select { |key| rules.cap_period_for(key) == :month }.index_with { |key| rules.cap_for(key) }.compact,
            "report_duplicate_points" => Decidim::Bih::Goodwill::ReportEntitlement::DUPLICATE_POINTS,
            "report_rejected_points" => 0, "report_unattributed_points" => 0,
            "referral_delay_hours" => Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY / 1.hour,
            "referral_paid_monthly_cap" => Decidim::Bih::Goodwill::Referrals::MONTHLY_CAP }
        end

        def cached_standings(now:)
          unless Decidim::Bih::Race::Visibility.visible?(@organization)
            return { "available" => false, "scores_visible" => false,
                     "answer_requirement" => "Race scores were hidden by the administrator. Do not quote old scores or ranks. " \
                                             "Winner/project information remains available." }
          end

          standings = Decidim::Bih::Race::Standings.new(@organization)
          eligible = standings.rows.select { |row| public_standing?(row, now:) }
          { "available" => eligible.any?, "scores_visible" => true,
            "closed" => Decidim::Bih::Race::Config.new(organization: @organization).finished?(now),
            "source_kind" => "cached_public_standings", "refreshed_by_this_read" => false, "live" => false,
            "answer_requirement" => "Describe these as cached standings and include computed_at; do not present them as live.",
            "final" => standings.final?, "computed_at" => eligible.map(&:computed_at).max&.iso8601,
            "top_rows" => eligible.first(3).map { |row| public_standing(row) },
            "zone_leaders" => public_zone_leaders(eligible), "complete_inventory" => false, "personal_contributions_included" => false }
        end

        def public_zone_leaders(rows)
          Decidim::Bih::LocalArea::ZONES.filter_map do |zone|
            leader = rows.select { |row| row.zona == zone }.min_by(&:rank_in_zone)
            public_standing(leader) if leader
          end
        end

        def public_standing?(row, now:)
          row.computed_at && row.computed_at <= now && row.komsiluk&.decidim_organization_id == @organization.id && row.rank_overall.positive?
        end

        def public_standing(row)
          { "area_label" => row.display_name, "zone" => row.zona, "rank_overall" => row.rank_overall,
            "rank_in_zone" => row.rank_in_zone, "score" => row.score, "computed_at" => row.computed_at.iso8601 }
        end

        def public_links(subject)
          paths = case subject
                  when "platform" then { "platform_home" => "/", "share_platform" => "/",
                                         "project_catalog" => Decidim::Bih::Engine.routes.url_helpers.community_projects_path }
                  when "account" then { "sign_in" => "/users/sign_in", "verification" => Decidim::Bih.public_path("verifikacija/telefon") }
                  when "reports" then { "public_reports" => Decidim::Bih::Engine.routes.url_helpers.reports_path,
                                        "my_reports" => Decidim::Bih::Engine.routes.url_helpers.reports_path(view: "mine"),
                                        "report_recovery" => Decidim::Bih::Engine.routes.url_helpers.recover_report_path,
                                        "report_form" => Decidim::Bih::Engine.routes.url_helpers.new_report_path }
                  when "notifications" then { "notification_settings" => "/notifications_settings" }
                  when "neighborhood" then { "neighborhood_picker" => Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path,
                                             "neighborhood_board" => Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path,
                                             "neighborhood_post_form" => Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path(anchor: "komsiluk-post-form"),
                                             "platform_guide" => Decidim::Bih::Engine.routes.url_helpers.onboarding_guide_path }
                  when "points" then { "volunteering" => Decidim::Bih.public_path("volontiranje"),
                                       "rewards_catalog" => Decidim::Bih::Engine.routes.url_helpers.community_hub_path(tab: "nagrade", anchor: "nagrade") }
                  else {}
                  end
          { "public_routes" => paths.transform_values { |path| absolute_public_url(path) }.compact }
        end

        def configured(name, **)
          value = Decidim::Bih.public_send(name)
          value.respond_to?(:call) ? value.call(**) : value
        end

        def public_url(subject)
          paths = { "account" => "/users/sign_in", "privacy" => "/pages/privacy-policy", "launch" => "/pozivnica", "race" => "/trka" }
          path = subject == "proposals" ? configured(:proposal_path) : paths.fetch(subject, "/")
          absolute_public_url(path)
        end

        def absolute_public_url(path)
          host = @organization.host.to_s
          return unless host.match?(/\A[a-z0-9][a-z0-9.-]*(?::\d+)?\z/i)

          "https://#{host}#{path}" if path.is_a?(String) && path.start_with?("/") && !path.start_with?("//")
        end
      end
    end
  end
end
