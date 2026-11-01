# frozen_string_literal: true

require "test_helper"
# Decidim's layout resolves default URL options via Decidim::UrlOptionResolver,
# which references Capybara.server_port in the test environment. Plain
# integration tests don't load Capybara (only system tests do), so require it
# here to satisfy that constant lookup while rendering the Decidim layout.
require "capybara"

module Decidim
  module Bih
    # End-to-end HTTP coverage for the anonymous "Bice riseno" intake surface
    # mounted at /biceriseno. Decidim derives the current organization from the
    # request host, so every request runs against the org's host. The real
    # ReportIntake executes; the AI classifier and Sistem 48 forwarder are
    # now run from the queued ReportProcessingJob rather than the request path.
    class ReportsIntakeTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        clear_enqueued_jobs
        clear_performed_jobs

        @organization = create_organization
        host! @organization.host
      end

      teardown do
        clear_enqueued_jobs
        clear_performed_jobs
      end

      test "GET new renders the intake form" do
        get "/biceriseno/prijave/new"

        assert_response :success
        assert_select "form[action=?]", "/biceriseno/prijave"
        assert_select "textarea[name=?]", "report[description]"
        assert_select "textarea#report_description[required][aria-describedby*=?]", "report_description_hint"
        assert_select "label[for=?]", "report_description"
        assert_select "label[for=?]", "report_address"
        assert_select "label[for=?]", "report_photo"
        assert_select "label[for=?]", "report_reporter_email"
        assert_select "label[for=?]", "report_reporter_phone"
        assert_select "#report_description_hint.help-text"
        assert_select "#report_address_hint.help-text"
        assert_select "#report_photo_hint.help-text"
        assert_select "#report_contact_hint.help-text"
        assert_select "#bih-report-location-map"
        assert_select "#bih-report-location-map[role=?][tabindex=?][aria-label=?][aria-describedby*=?]",
                      "group",
                      "0",
                      I18n.t("decidim.bih.reports.new.location.map_toggle"),
                      "bih-report-location-status"
        assert_select "#bih-report-geolocate"
        assert_select "#bih-report-location-status[role=?][aria-live=?]", "status", "polite"
        assert_select "input[type=file][name=?][accept=?]", "report[photo]", "image/png,image/jpeg,image/webp"
        assert_select "script[src=?]", "/leaflet/leaflet.js"
        assert_select "script[src^='/mi/bih-report-location-map.js']", 1
        assert_not_includes response.body, "navigator.geolocation.getCurrentPosition"
        assert_not_includes response.body, "L.map(mapEl)"
        assert_select "input[type=hidden][name=?]", "report[latitude]"
        assert_select "input[type=hidden][name=?]", "report[longitude]"
        assert_select "input[type=number][name=?]", "report[latitude]", false
        assert_select "input[type=number][name=?]", "report[longitude]", false
        assert_select "input[name=?][autocomplete=off]", "report[website]"
      end

      test "GET biceriseno root renders the usable intake form" do
        get "/biceriseno"

        assert_response :success
        assert_select "form[action=?]", "/biceriseno/prijave"
        assert_select "textarea[name=?]", "report[description]"
        assert_select "#bih-report-location-map"
        assert_select "input[name=?][autocomplete=off]", "report[website]"
      end

      test "POST create with valid params creates a report, enqueues processing and redirects to status" do
        assert_difference -> { Decidim::Bih::Report.count }, 1 do
          assert_enqueued_with(job: Decidim::Bih::ReportProcessingJob, queue: "reports") do
            post "/biceriseno/prijave", params: {
              report: {
                description: "Velika rupa na putu kod skole",
                address: "Ulica Karadjordjeva 1",
                latitude: "44.756",
                longitude: "19.216",
                anonymous: "1"
              }
            }
          end
        end

        report = Decidim::Bih::Report.last
        assert_equal @organization, report.organization
        assert report.anonymous?
        assert_equal "primljeno", report.status
        assert_match Decidim::Bih::Report::STATUS_TOKEN_FORMAT, report.status_token
        assert_nil report.category
        assert_in_delta 44.756, report.latitude.to_f, 0.0001
        assert_in_delta 19.216, report.longitude.to_f, 0.0001
        assert_redirected_to "/biceriseno/prijave/#{report.reference}/status/#{report.status_token}"

        follow_redirect!
        assert_response :success
        assert_select "body", /#{Regexp.escape(report.reference)}/
      end

      test "POST create treats signed-in users from another organization as anonymous" do
        other_organization = create_organization
        outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)

        sign_in outsider

        assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.count } do
          assert_difference -> { Decidim::Bih::Report.count }, 1 do
            assert_enqueued_with(job: Decidim::Bih::ReportProcessingJob, queue: "reports") do
              post "/biceriseno/prijave", params: {
                report: {
                  description: "Prijava sa sesijom iz druge organizacije",
                  address: "Trg kralja Petra I",
                  latitude: "44.756",
                  longitude: "19.216"
                }
              }
            end
          end
        end

        report = Decidim::Bih::Report.last
        assert_equal @organization, report.organization
        assert_nil report.decidim_user_id
        assert_not_equal outsider.id, report.decidim_user_id
        assert_redirected_to "/biceriseno/prijave/#{report.reference}/status/#{report.status_token}"
      end

      test "POST create shows the duplicate interstitial and does NOT create when a likely dup exists" do
        existing = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu kod skole",
          latitude: 44.756,
          longitude: 19.216,
          status: "primljeno"
        )

        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/prijave", params: {
              report: {
                description: "Ista rupa, druga osoba prijavljuje",
                latitude: "44.7561",
                longitude: "19.2161"
              }
            }
          end
        end

        assert_response :ok
        # The interstitial surfaces the existing report's reference + a tracker link.
        assert_includes response.body, existing.reference
        assert_select "#bih-duplicate-actions-help"
        assert_select "button[aria-describedby=?]", "bih-duplicate-actions-help"
        assert_select "input#report_duplicate_photo", count: 0
        assert_select "a[href=?]", "/biceriseno/prijave/#{existing.reference}"
        # PII-safe: the EXISTING report's description is never exposed.
        assert_not_includes response.body, "Rupa na putu kod skole"
        # The "submit anyway" path carries the citizen's own data forward (their
        # own resubmission, not the existing report) + a confirmed flag.
        assert_select "input[type=hidden][name=?][value=?]", "report[confirmed_new]", "1"
        assert_select "input[type=hidden][name=?][value=?]", "report[description]", "Ista rupa, druga osoba prijavljuje"
      end

      test "duplicate photo survives validation errors and a confirmed submission exactly once" do
        Report.create!(organization: @organization, description: "Existing", latitude: 44.756, longitude: 19.216)
        attributes = { description: "Different problem", latitude: "44.7561", longitude: "19.2161" }
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/chat_photo.jpg"), "image/jpeg")
        post "/biceriseno/prijave", params: { report: attributes.merge(photo: upload) }
        assert_response :ok
        assert_includes response.headers["Cache-Control"], "no-store"
        token = css_select('input[name="report[photo_draft_token]"]').first["value"]
        assert token.present?
        assert_select "input[type=file]", count: 0

        post "/biceriseno/prijave", params: { report: attributes.merge(description: "", confirmed_new: "1", photo_draft_token: token) }
        assert_response :unprocessable_entity
        assert_select 'input[name="report[photo_draft_token]"][value=?]', token
        assert_difference "Report.count", 1 do
          post "/biceriseno/prijave", params: { report: attributes.merge(confirmed_new: "1", photo_draft_token: token) }
        end
        assert_response :redirect
        destination = response.location
        assert Report.order(:id).last.photo.attached?
        assert_no_difference "Report.count" do
          post "/biceriseno/prijave", params: { report: attributes.merge(confirmed_new: "1", photo_draft_token: token, remove_saved_photo: "1") }
        end
        assert_equal destination, response.location
      end

      test "citizen can remove the saved photo without letting another session remove it" do
        Report.create!(organization: @organization, description: "Existing", latitude: 44.756, longitude: 19.216)
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/chat_photo.jpg"), "image/jpeg")
        post "/biceriseno/prijave", params: { report: { description: "Different", latitude: "44.7561", longitude: "19.2161", photo: upload } }
        token = css_select('input[name="report[photo_draft_token]"]').first["value"]
        assert_select 'input[type=checkbox][name="report[remove_saved_photo]"]'
        saved = ReportPhotoDraft.order(:id).last
        attributes = { description: "Different", confirmed_new: "1", photo_draft_token: token, remove_saved_photo: "1" }
        other = open_session
        other.host! @organization.host
        assert_no_difference ["Report.count", "ReportPhotoDraft.count"] do
          other.post "/biceriseno/prijave", params: { report: attributes }
        end
        assert_equal 422, other.response.status
        assert_difference "Report.count", 1 do
          post "/biceriseno/prijave", params: { report: attributes }
        end
        assert_response :redirect
        assert_not Report.order(:id).last.photo.attached?
        assert_not ReportPhotoDraft.exists?(saved.id)
      end

      test "corroborating discards only the owning session's temporary photo" do
        existing = Report.create!(organization: @organization, description: "Existing", latitude: 44.756, longitude: 19.216)
        upload = Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/chat_photo.jpg"), "image/jpeg")
        post "/biceriseno/prijave", params: { report: { description: "Another", latitude: "44.7561", longitude: "19.2161", photo: upload } }
        token = css_select('input[name="report[photo_draft_token]"]').first["value"]
        saved = ReportPhotoDraft.order(:id).last
        other = open_session
        other.host! @organization.host
        assert_no_difference "ReportPhotoDraft.count" do
          other.post "/biceriseno/prijave/#{existing.reference}/potvrdi", params: { photo_draft_token: token }
        end
        assert_no_difference "Report.count" do
          other.post "/biceriseno/prijave", params: { report: { description: "Another", confirmed_new: "1", photo_draft_token: token } }
        end
        assert_equal 422, other.response.status
        post "/biceriseno/prijave/#{existing.reference}/potvrdi", params: { photo_draft_token: token }
        assert_response :redirect
        assert_not ReportPhotoDraft.exists?(saved.id)
      end

      test "invalid photo token cannot silently submit a photo-less report" do
        assert_no_difference "Report.count" do
          post "/biceriseno/prijave", params: { report: { description: "Different", confirmed_new: "1", photo_draft_token: "invalid" } }
        end
        assert_response :unprocessable_entity
        assert_includes response.body, I18n.t("decidim.bih.photo_draft.unavailable")
        assert_select "input[type=file][name=?]", "report[photo]"
      end

      test "POST corroborate increments the existing report count and creates NO new report" do
        existing = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          latitude: 44.756,
          longitude: 19.216,
          status: "primljeno"
        )

        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            assert_difference -> { existing.reload.corroboration_count }, 1 do
              post "/biceriseno/prijave/#{existing.reference}/potvrdi"
            end
          end
        end

        assert_redirected_to "/biceriseno/prijave/#{existing.reference}"
        follow_redirect!
        assert_response :success
      end

      test "POST corroborate for an unknown reference redirects without error" do
        assert_no_difference -> { Decidim::Bih::Report.count } do
          post "/biceriseno/prijave/BR-2026-9999/potvrdi"
        end

        assert_redirected_to "/biceriseno/prijave/new"
      end

      test "POST corroborate never crosses organizations" do
        existing = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          status: "primljeno"
        )

        other = create_organization
        host! other.host

        assert_no_difference -> { existing.reload.corroboration_count } do
          post "/biceriseno/prijave/#{existing.reference}/potvrdi"
        end

        assert_redirected_to "/biceriseno/prijave/new"
      end

      test "POST create with confirmed_new bypasses dup detection and creates the report" do
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu kod skole",
          latitude: 44.756,
          longitude: 19.216,
          status: "primljeno"
        )

        assert_difference -> { Decidim::Bih::Report.count }, 1 do
          assert_enqueued_with(job: Decidim::Bih::ReportProcessingJob, queue: "reports") do
            post "/biceriseno/prijave", params: {
              report: {
                description: "Ovo je druga, drugacija rupa",
                latitude: "44.7561",
                longitude: "19.2161",
                confirmed_new: "1"
              }
            }
          end
        end

        report = Decidim::Bih::Report.last
        assert_redirected_to "/biceriseno/prijave/#{report.reference}/status/#{report.status_token}"
      end

      test "POST create with blank description re-renders new without creating a report" do
        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/prijave", params: { report: { description: "" } }
          end
        end

        assert_response :unprocessable_entity
        assert_select "textarea[name=?]", "report[description]"
        assert_select "[role=alert]"
        assert_select "textarea#report_description[aria-invalid=true][aria-describedby*=report_description_error]"
        assert_select "#report_description_error.form-error"
      end

      test "POST create rejects out-of-range coordinates" do
        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/prijave", params: {
              report: {
                description: "Problem sa lokacijom",
                latitude: "91",
                longitude: "19.216"
              }
            }
          end
        end

        assert_response :unprocessable_entity
        assert_select "#bih-report-location-map"
        assert_select "#bih-report-location-map[aria-describedby*=?]", "report_location_error"
        assert_select "#report_location_error.form-error"
      end

      test "POST create drops honeypot submissions without creating a report" do
        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/prijave", params: {
              report: {
                description: "Spam prijava",
                website: "https://spam.example"
              }
            }
          end
        end

        assert_response :success
        assert_empty response.body
      end

      test "POST create rejects a non-image upload (anonymous endpoint hardening)" do
        evil = Rack::Test::UploadedFile.new(
          StringIO.new("<svg onload=alert(1)></svg>"), "image/svg+xml", original_filename: "evil.svg"
        )

        assert_no_enqueued_jobs(only: Decidim::Bih::ReportProcessingJob) do
          assert_no_difference -> { Decidim::Bih::Report.count } do
            post "/biceriseno/prijave", params: { report: { description: "Sa lošom slikom", photo: evil } }
          end
        end

        assert_response :unprocessable_entity
      end

      test "GET show for a known reference returns the status page" do
        report = Decidim::Bih::ReportIntake.new.call(
          organization: @organization,
          description: "Nema rasvjete u ulici"
        )

        get "/biceriseno/prijave/#{report.reference}"

        assert_response :success
        assert_select "body", /#{Regexp.escape(report.reference)}/
      end

      test "GET show does not expose reporter contact data or raw description" do
        report = Decidim::Bih::ReportIntake.new.call(
          organization: @organization,
          description: "Moja adresa je Ulica privatna 12 i broj 066111222",
          reporter_email: "reporter@example.org",
          reporter_phone: "+38766111222"
        )

        get "/biceriseno/prijave/#{report.reference}"

        assert_response :success
        assert_includes response.body, report.reference
        assert_no_match(/reporter@example\.org/i, response.body)
        assert_no_match(/38766111222|066111222|Ulica privatna 12/i, response.body)
        assert_no_match(/Moja adresa/i, response.body)
      end

      test "GET show for an unknown reference is handled with a friendly redirect" do
        get "/biceriseno/prijave/BR-2026-9999"

        assert_redirected_to "/biceriseno/prijave/new"
        follow_redirect!
        assert_response :success
      end

      test "GET show never leaks reports across organizations" do
        report = Decidim::Bih::ReportIntake.new.call(
          organization: @organization,
          description: "Curi voda na cesti"
        )

        other = create_organization
        host! other.host
        get "/biceriseno/prijave/#{report.reference}"

        assert_redirected_to "/biceriseno/prijave/new"
      end
    end
  end
end
