# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    module Admin
      # Round 8 — Admin report triage: filterable index, status update, retry.
      # Follows Round 6 CSRF convention: missing token → 422, no state change.
      class ReportsControllerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @report = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Rupa na putu",
            address: "Vidovdanska 1"
          )
        end

        # --- index ---

        test "admin sees the reports index" do
          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_includes response.body, @report.reference
          assert_includes response.body, "/admin/bih/reports/#{@report.reference}"
          assert_includes response.body, "admin-reports-workflow-tabs"
          assert_includes response.body, I18n.t("decidim.bih.admin.reports.index.tabs.queue")
          assert_select "#admin-reports-workflow-tabs a[href*='tab=attention']", count: 0
          assert_includes response.body, I18n.t("decidim.bih.admin.reports.index.tabs.insights")
          assert_not_includes response.body, "admin-reports-sla"
          assert_not_includes response.body, "admin-reports-handoffs"
          assert_not_includes response.body, "admin-reports-heatmap"
          assert_not_includes response.body, "bundle exec rake decidim_bih:reports:stale_digest"

          # rubocop:disable Rails/DynamicFindBy
          list_panel = Capybara.string(response.body).find_by_id("admin-reports-list")
          # rubocop:enable Rails/DynamicFindBy
          assert_empty list_panel.all("form"), "report queue must link to review pages instead of exposing mutation forms"
          assert_empty list_panel.all("input[name='duplicate_reference']")
          assert_empty list_panel.all("textarea[name='internal_note']")
          assert_empty list_panel.all("button[type='submit']")
        end

        test "index renders organization-scoped aggregate sla buckets without private report data" do
          old_received = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private SLA received description",
            address: "Private SLA received address",
            created_at: 3.days.ago,
            updated_at: 3.days.ago
          )
          stale_city = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private SLA stale description",
            address: "Private SLA stale address",
            status: "u_obradi", review_state: "validated",
            forwarded_at: 45.days.ago,
            created_at: 45.days.ago,
            updated_at: 45.days.ago
          )
          failed = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private SLA failed description",
            address: "Private SLA failed address"
          )
          failed.record_forwarding_failure!(StandardError.new("timeout"), code: "net_timeout")
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private SLA review description",
            address: "Private SLA review address",
            needs_review: true
          )
          other = Decidim::Bih::Report.create!(
            organization: create_organization,
            description: "Other private SLA description",
            address: "Other private SLA address",
            needs_review: true,
            created_at: 45.days.ago,
            updated_at: 45.days.ago
          )
          other.record_forwarding_failure!(StandardError.new("other timeout"), code: "other_timeout")

          sign_in @admin
          get "/admin/bih/reports", params: { tab: "insights" }

          assert_response :success
          assert_not_includes response.body, "admin-reports-list"
          # Capybara::Node::Simple#find_by_id is not an ActiveRecord dynamic finder.
          # rubocop:disable Rails/DynamicFindBy
          panel = Capybara.string(response.body).find_by_id("admin-reports-sla")
          # rubocop:enable Rails/DynamicFindBy
          {
            "forwarding_failed" => failed,
            "received_over_sla" => old_received,
            "stale_city_followup" => stale_city
          }.each do |key, _report|
            label = I18n.t("decidim.bih.admin.reports.index.sla.buckets.#{key}")
            row = panel.all("tbody tr", visible: :all).find { |candidate| candidate.text(:all).include?(label) }

            assert row, "expected SLA row for #{key}"
            assert_equal "1", row.all("td", visible: :all)[1].text(:all).strip, "expected #{key} count to be scoped to this organization"
          end
          assert_not_includes response.body, "Private SLA"
          assert_not_includes response.body, "Other private SLA"
          assert_not_includes response.body, other.reference if other.reference != @report.reference
        end

        test "old attention bookmark uses the same pii-minimized report queue" do
          old_received = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private queue received description",
            address: "Private queue received address",
            internal_note: "Private queue received note",
            created_at: 3.days.ago,
            updated_at: 3.days.ago
          )
          failed = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Private queue failed description",
            address: "Private queue failed address",
            internal_note: "Private queue failed note",
            needs_review: true,
            created_at: 1.day.ago,
            updated_at: 1.day.ago
          )
          failed.record_forwarding_failure!(StandardError.new("Private queue timeout"), code: "private_queue")
          other = Decidim::Bih::Report.create!(
            organization: create_organization,
            description: "Other private queue description",
            reference: "BR-#{Time.current.year}-9999",
            address: "Other private queue address",
            needs_review: true,
            created_at: 45.days.ago,
            updated_at: 45.days.ago
          )

          sign_in @admin
          get "/admin/bih/reports", params: { tab: "attention" }

          assert_response :success
          assert_not_includes response.body, "admin-reports-escalation"
          # rubocop:disable Rails/DynamicFindBy
          panel = Capybara.string(response.body).find_by_id("admin-reports-list")
          # rubocop:enable Rails/DynamicFindBy

          assert_includes panel.text, failed.reference
          assert_includes panel.text, old_received.reference
          assert_equal 1, panel.all("tbody tr").count { |row| row.has_text?(failed.reference) },
                       "a report in several buckets should appear only once in the escalation queue"
          assert_includes panel.text, I18n.t("decidim.bih.admin.reports.index.failed")
          assert_includes panel.text, I18n.t("decidim.bih.review_workspace.open")
          assert_not_includes panel.text, "Private queue"
          assert_not_includes panel.text, "private_queue"
          assert_not_includes panel.text, other.reference if other.reference != failed.reference
        end

        test "insights tab renders aggregate handoffs and heatmap away from the queue" do
          sign_in @admin
          get "/admin/bih/reports", params: { tab: "insights" }

          assert_response :success
          assert_not_includes response.body, "admin-reports-list"
          assert_includes response.body, "admin-reports-handoffs"
          assert_includes response.body, "admin-reports-heatmap"
          assert_includes response.body, "/admin/bih/analytics/export/report_triage.csv"
          assert_includes response.body, I18n.t("decidim.bih.admin.reports.index.handoffs.operator_details")
          assert_includes response.body, "bundle exec rake decidim_bih:reports:stale_digest"
        end

        test "admin sees report detail with operator-safe event history" do
          @report.record_event!(
            "status_changed",
            actor: @admin,
            metadata: {
              from_status: "primljeno",
              to_status: "proslijedjeno",
              internal_note: "NE SMIJE SE PRIKAZATI",
              reporter_email: "gradjanin@example.test"
            }
          )

          sign_in @admin
          get "/admin/bih/reports/#{@report.reference}"

          assert_response :success
          assert_includes response.body, @report.reference
          assert_includes response.body, "admin-report-events"
          assert_includes response.body, "Status promijenjen"
          assert_includes response.body, "Proslijeđeno"
          assert_not_includes response.body, "NE SMIJE SE PRIKAZATI"
          assert_not_includes response.body, "gradjanin@example.test"
          assert_select "#report-private-evidence", text: /#{Regexp.escape(@report.description)}/
          assert_select "#report-private-evidence", text: /#{Regexp.escape(@report.address)}/
        end

        test "case-agent lease events read as staff wording and hide the job id" do
          @report.record_event!("case_agent_lease", source: "background", actor_role: "system",
                                                    metadata: { proposal_id: 4321, lease: "resumed", job_id: "job-0f9e-not-for-staff", prompt_version: "case-agent-v2" })

          sign_in @admin
          get "/admin/bih/reports/#{@report.reference}"

          assert_response :success
          events = "decidim.bih.admin.reports.events"
          assert_select "#admin-report-events" do
            assert_select "strong", text: I18n.t("#{events}.types.case_agent_lease", locale: :sr)
            assert_select "li", text: /#{Regexp.escape(I18n.t("#{events}.metadata.lease", locale: :sr))}:\s*#{Regexp.escape(I18n.t("#{events}.leases.resumed", locale: :sr))}/
            assert_select "li", text: /#{Regexp.escape(I18n.t("#{events}.metadata.proposal_id", locale: :sr))}:\s*4321/
          end
          assert_not_includes response.body, "job-0f9e-not-for-staff"
          assert_select "#admin-report-events li", text: /Job id/, count: 0
        end

        test "non-admin is denied access to report detail" do
          sign_in @citizen
          get "/admin/bih/reports/#{@report.reference}"

          assert_response :redirect
        end

        test "detail for missing reference redirects to index" do
          sign_in @admin
          get "/admin/bih/reports/BR-1900-0000"

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports"
        end

        test "admin sees showing N of M count" do
          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_includes response.body, "1"
        end

        test "non-admin is denied access to reports index" do
          sign_in @citizen
          get "/admin/bih/reports"

          assert_response :redirect
        end

        test "status filter restricts visible reports" do
          resolved = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Riješen problem",
            address: "Ulica 2",
            status: "rijeseno"
          )

          sign_in @admin
          get "/admin/bih/reports", params: { status: "rijeseno" }

          assert_response :success
          assert_includes response.body, resolved.reference
          assert_not_includes response.body, @report.reference
        end

        test "invalid status filter is ignored (shows all)" do
          sign_in @admin
          get "/admin/bih/reports", params: { status: "bad_status" }

          assert_response :success
          assert_includes response.body, @report.reference
        end

        test "index shows forwarding failure badge when report has failed" do
          @report.record_forwarding_failure!(StandardError.new("timeout"), code: "net_timeout")

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_includes response.body, "Neuspjelo"
          assert_includes response.body, "(1)"
        end

        test "retired classifier filter no longer hides new reports" do
          flagged = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Neraspoznata prijava",
            address: "Ulica 3",
            needs_review: true
          )

          sign_in @admin
          get "/admin/bih/reports", params: { needs_review: "1" }

          assert_response :success
          assert_includes response.body, flagged.reference
          assert_includes response.body, @report.reference
        end

        test "index shows missing category independently of the historic classifier flag" do
          @report.update!(needs_review: true)

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_select "[data-category-missing]"
          assert_select "input[name=needs_review]", count: 0
        end

        test "mz filter restricts visible reports and renders mz names" do
          create_mz!("mz-centar", "Centar")
          create_mz!("mz-janja", "Janja")
          @report.update!(mz_slug: "mz-centar")
          janja = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Problem u Janji",
            address: "Janja 1",
            mz_slug: "mz-janja"
          )

          sign_in @admin
          get "/admin/bih/reports", params: { mz_slug: "mz-centar" }

          assert_response :success
          assert_includes response.body, @report.reference
          assert_includes response.body, "Centar"
          assert_not_includes response.body, janja.reference
        end

        test "invalid mz filter is ignored" do
          sign_in @admin
          get "/admin/bih/reports", params: { mz_slug: "not-a-real-mz" }

          assert_response :success
          assert_includes response.body, @report.reference
        end

        test "age filter restricts visible reports" do
          old_report = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Stara prijava",
            address: "Ulica 4",
            created_at: 45.days.ago,
            updated_at: 45.days.ago
          )

          sign_in @admin
          get "/admin/bih/reports", params: { age: "older_than_30" }

          assert_response :success
          assert_includes response.body, old_report.reference
          assert_not_includes response.body, @report.reference
        end

        test "invalid age filter is ignored" do
          sign_in @admin
          get "/admin/bih/reports", params: { age: "older_than_forever" }

          assert_response :success
          assert_includes response.body, @report.reference
        end

        test "attention filter restricts visible reports to the selected sla bucket" do
          stale_city = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Stale city follow-up",
            address: "Ulica 4",
            status: "u_obradi", review_state: "validated",
            forwarded_at: 45.days.ago,
            created_at: 45.days.ago,
            updated_at: 45.days.ago
          )
          old_received = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Old received",
            address: "Ulica 5",
            created_at: 3.days.ago,
            updated_at: 3.days.ago
          )

          sign_in @admin
          get "/admin/bih/reports", params: { attention: "stale_city_followup" }

          assert_response :success
          assert_includes response.body, stale_city.reference
          assert_not_includes response.body, old_received.reference
          assert_not_includes response.body, @report.reference
          assert_not_includes response.body, "admin-reports-escalation"
          assert_not_includes response.body, "admin-reports-heatmap"

          get "/admin/bih/reports", params: { tab: "attention", attention: "stale_city_followup" }

          assert_response :success
          # rubocop:disable Rails/DynamicFindBy
          queue_panel = Capybara.string(response.body).find_by_id("admin-reports-list")
          # rubocop:enable Rails/DynamicFindBy
          assert_includes queue_panel.text, stale_city.reference
          assert_not_includes queue_panel.text, old_received.reference

          get "/admin/bih/reports", params: { tab: "insights", attention: "stale_city_followup" }

          assert_response :success
          heatmap_links = Capybara.string(response.body).all("#admin-reports-heatmap a").map { |link| link[:href] }

          assert heatmap_links.any? { |href| href.include?("tab=insights") && href.include?("attention=stale_city_followup") && href.include?("heatmap_days=30") },
                 "expected heatmap window links to preserve the attention filter"
        end

        test "invalid attention filter is ignored" do
          sign_in @admin
          get "/admin/bih/reports", params: { attention: "private_everything" }

          assert_response :success
          assert_includes response.body, @report.reference
        end

        test "admin cannot see another organization's reports" do
          other = create_organization
          # Use a distinct description to ensure absence check below is meaningful
          other_report = Decidim::Bih::Report.create!(
            organization: other,
            description: "DISTINCT_OTHER_ORG_DESCRIPTION",
            address: "Tuđa ulica"
          )

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          # Body should not include the other org's description (reference may
          # collide if both orgs start at BR-YYYY-0001 in the same year).
          assert_not_includes response.body, "DISTINCT_OTHER_ORG_DESCRIPTION"
          assert_not_includes response.body, other_report.reference if other_report.reference != @report.reference
        end

        test "reports are ordered failures-first" do
          first = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "OK prijava",
            address: "Ulica 2"
          )
          @report.record_forwarding_failure!(StandardError.new("timeout"), code: "net_timeout")

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          body = response.body
          assert body.index(@report.reference) < body.index(first.reference),
                 "failed report should appear before non-failed report"
        end

        test "index renders status history with minimized forwarding failure details" do
          @report.update!(status: "proslijedjeno")
          @report.update!(status: "u_obradi")
          @report.record_forwarding_failure!(StandardError.new("raw failure text"), code: "net_error")

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_includes response.body, "Proslijeđeno"
          assert_includes response.body, "U obradi"
          # rubocop:disable Rails/DynamicFindBy
          list_panel = Capybara.string(response.body).find_by_id("admin-reports-list")
          # rubocop:enable Rails/DynamicFindBy
          assert_not_includes list_panel.text, "net_error"
          assert_not_includes list_panel.text, "StandardError"
          assert_not_includes list_panel.text, "raw failure text"

          get "/admin/bih/reports/#{@report.reference}"

          assert_response :success
          assert_includes response.body, "net_error"
          assert_includes response.body, "StandardError"
          assert_includes response.body, "raw failure text"
        end

        # --- update_status ---

        test "admin review records an attributed decision without inventing city progress" do
          sign_in @admin
          decide("review", category: "putevi", severity: "normalan")
          assert_response :redirect
          assert_equal "primljeno", @report.reload.status
          assert_equal "validated", @report.review_state
          assert_equal @admin, @report.reviewed_by
          event = @report.events.where(event_type: "case_decision_applied").sole
          assert_equal @admin, event.actor
          assert_equal "review", event.metadata["action"]
        end

        test "admin rejects report with a reason" do
          sign_in @admin
          decide("reject", reason: "Nije u nadležnosti")
          assert_response :redirect
          assert_equal "odbijeno", @report.reload.status
          assert_equal "Nije u nadležnosti", @report.status_note
          audit = Decidim::Bih::OperatorAuditEvent.where(event_type: "case_decision_applied").last
          assert_equal @admin, audit.user
          assert_equal "reject", audit.metadata["action"]
          assert_not_includes audit.metadata.to_s, "Nije u nadležnosti"
        end

        test "terminal decision requires evidence reason and confirmation" do
          sign_in @admin
          decide("resolve", { reason: "Potvrđeno sa službom", resolution_evidence: "Zapisnik" }, confirmed: false)
          assert_equal "primljeno", @report.reload.status
          decide("resolve", resolution_evidence: "Zapisnik")
          assert_equal "primljeno", @report.reload.status
        end

        test "rejection without reason is refused" do
          sign_in @admin
          decide("reject", reason: "")
          assert_response :redirect
          assert_equal "primljeno", @report.reload.status
          assert_empty @report.events.where(event_type: "case_decision_applied")
        end

        test "invalid status value is rejected" do
          sign_in @admin
          patch "/admin/bih/reports/#{@report.reference}/status",
                params: { status: "izmisljeno" }

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_equal "primljeno", @report.reload.status
        end

        test "admin cannot update another organization's report status" do
          other = create_organization
          other_report = Decidim::Bih::Report.create!(
            organization: other,
            description: "Tuđa prijava",
            address: "Tuđa ulica"
          )

          sign_in @admin
          patch "/admin/bih/reports/#{other_report.reference}/status",
                params: { status: "rijeseno" }

          assert_response :redirect
          assert_equal "primljeno", other_report.reload.status
        end

        # R3 (scoped-finder concern): updating the status of a non-existent
        # reference must redirect to the index via the finder, not 500.
        test "update_status of a non-existent reference redirects to index, not 500" do
          sign_in @admin
          patch "/admin/bih/reports/BR-1900-0000/status",
                params: { status: "rijeseno" }

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports"
        end

        # R3: retrying a non-existent reference likewise redirects, never 500.
        test "retry_forwarding of a non-existent reference redirects to index, not 500" do
          sign_in @admin
          assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
            post "/admin/bih/reports/BR-1900-0000/retry-forwarding"
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports"
        end

        test "status update rejects missing CSRF token when forgery protection is enabled" do
          sign_in @admin
          with_forgery_protection do
            patch "/admin/bih/reports/#{@report.reference}/status",
                  params: { status: "rijeseno" }
          end

          assert_response :unprocessable_entity
          assert_equal "primljeno", @report.reload.status
          assert_equal 0, @report.events.where(event_type: "status_changed").count
        end

        # --- update_internal_note ---

        test "admin saves an internal note" do
          sign_in @admin
          assert_difference("Decidim::Bih::ReportEvent.where(event_type: 'internal_note_changed').count", 1) do
            decide("note", body: "Provjeriti sa komunalnim timom")
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_includes @report.reload.internal_note, "Provjeriti sa komunalnim timom"
          assert_includes @report.internal_note, @admin.name
          event = @report.events.where(event_type: "internal_note_changed").last
          assert_equal true, event.metadata["current_note_present"]
          assert_not event.metadata.to_s.include?("Provjeriti sa komunalnim timom")
        end

        test "internal note is visible on admin detail but not index or public report page" do
          @report.update!(internal_note: "Samo za operatere")

          sign_in @admin
          get "/admin/bih/reports"

          assert_response :success
          assert_not_includes response.body, "Samo za operatere"

          get "/admin/bih/reports/#{@report.reference}"

          assert_response :success
          assert_includes response.body, "Samo za operatere"

          get "/biceriseno/prijave/#{@report.reference}"

          assert_response :success
          assert_not_includes response.body, "Samo za operatere"
        end

        test "internal note update rejects missing CSRF token when forgery protection is enabled" do
          sign_in @admin
          with_forgery_protection do
            patch "/admin/bih/reports/#{@report.reference}/internal-note",
                  params: { internal_note: "Ne smije se snimiti" }
          end

          assert_response :unprocessable_entity
          assert_nil @report.reload.internal_note
          assert_equal 0, @report.events.where(event_type: "internal_note_changed").count
        end

        # --- duplicate marker ---

        test "admin marks and clears a duplicate report" do
          canonical = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Glavna prijava",
            address: "Ulica 5"
          )

          sign_in @admin
          assert_difference("Decidim::Bih::ReportEvent.where(event_type: 'duplicate_marked').count", 1) do
            decide("duplicate", duplicate_reference: canonical.reference)
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_equal canonical.id, @report.reload.duplicate_of_report_id
          assert_equal canonical.reference, @report.events.where(event_type: "duplicate_marked").last.metadata["duplicate_of_reference"]

          assert_difference("Decidim::Bih::ReportEvent.where(event_type: 'case_decision_applied').count", 1) do
            decide("reopen", reason: "Utvrđeno je da je zaseban problem")
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_nil @report.reload.duplicate_of_report_id
          assert_equal "reopen", @report.events.where(event_type: "case_decision_applied").last.metadata["action"]
          assert_equal "primljeno", @report.status
        end

        test "admin cannot mark a report as duplicate of itself" do
          sign_in @admin
          decide("duplicate", duplicate_reference: @report.reference)

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_nil @report.reload.duplicate_of_report_id
        end

        test "admin cannot mark duplicate to another organization report" do
          other = create_organization
          other_report = Decidim::Bih::Report.create!(
            organization: other,
            description: "Tuđa glavna prijava",
            address: "Tuđa ulica",
            reference: "BR-#{Time.current.year}-9999"
          )

          sign_in @admin
          decide("duplicate", duplicate_reference: other_report.reference)

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_nil @report.reload.duplicate_of_report_id
        end

        test "admin cannot mark a report as duplicate of an existing duplicate" do
          canonical = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Glavna prijava",
            address: "Ulica 5"
          )
          duplicate_target = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Već duplikat",
            address: "Ulica 6",
            duplicate_of: canonical
          )

          sign_in @admin
          decide("duplicate", duplicate_reference: duplicate_target.reference)

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_nil @report.reload.duplicate_of_report_id
        end

        test "duplicate marker rejects missing CSRF token when forgery protection is enabled" do
          canonical = Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Glavna prijava",
            address: "Ulica 5"
          )

          sign_in @admin
          with_forgery_protection do
            decide("duplicate", duplicate_reference: canonical.reference)
          end

          assert_response :unprocessable_entity
          assert_nil @report.reload.duplicate_of_report_id
        end

        # --- retry_forwarding ---

        test "failed forwarding requires a new preview and preserves failure evidence" do
          @report.record_forwarding_failure!(StandardError.new("timeout"), code: "timeout")
          sign_in @admin
          assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
            post "/admin/bih/reports/#{@report.reference}/retry-forwarding"
          end
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert @report.reload.forwarding_failed_at
          assert_equal "timeout", @report.forwarding_error_code
        end

        test "received report forwarding opens the preview instead of sending immediately" do
          sign_in @admin
          assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
            post "/admin/bih/reports/#{@report.reference}/retry-forwarding"
          end
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
          assert_nil @report.reload.forwarded_at
        end

        test "retry is refused for an already-proslijedjeno report with no failure" do
          @report.update!(status: "proslijedjeno", forwarded_at: Time.current)

          sign_in @admin
          assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
            post "/admin/bih/reports/#{@report.reference}/retry-forwarding"
          end

          assert_response :redirect
          assert_redirected_to "/admin/bih/reports/#{@report.reference}?return_to=%2Fadmin%2Fbih%2Freports%3Fview%3Dreview"
        end

        test "retry rejects missing CSRF token when forgery protection is enabled" do
          @report.record_forwarding_failure!(StandardError.new("timeout"), code: "timeout")
          original_failed_at = @report.forwarding_failed_at

          sign_in @admin
          with_forgery_protection do
            assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
              post "/admin/bih/reports/#{@report.reference}/retry-forwarding"
            end
          end

          assert_response :unprocessable_entity
          assert_equal original_failed_at.to_i, @report.reload.forwarding_failed_at.to_i
        end

        test "admin cannot retry another organization's report via a cross-org reference" do
          other = create_organization
          other_report = Decidim::Bih::Report.create!(
            organization: other,
            description: "Tuđa prijava",
            address: "Ulica",
            reference: "BR-#{Time.current.year}-9999"
          )
          other_report.record_forwarding_failure!(StandardError.new("timeout"), code: "timeout")

          sign_in @admin
          # Using the other org's reference: controller scopes to current_organization,
          # so find_by returns nil and the job is not enqueued.
          assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
            post "/admin/bih/reports/#{other_report.reference}/retry-forwarding"
          end

          assert_response :redirect
          # The other org's report is still failed (nothing touched it).
          assert other_report.reload.forwarding_failed_at?
        end

        private

        def decide(action, values = {}, confirmed: true, **fields)
          post "/admin/bih/reports/#{@report.reference}/decision", params: {
            decision_action: action, decision: values.merge(fields),
            input_version: ReportReviewVersion.digest(@report.reload), confirm_decision: confirmed ? "1" : "0"
          }
        end

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end

        def create_mz!(slug, name)
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: slug,
            name: { "sr" => name, "en" => name }
          )
        end
      end
    end
  end
end
