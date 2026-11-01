# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    class ReportTest < ActiveSupport::TestCase
      include ActionMailer::TestHelper

      setup do
        @organization = create_organization
      end

      test "auto-generates a sequential per-org reference" do
        first = Decidim::Bih::Report.create!(organization: @organization, description: "Rupa na putu")
        second = Decidim::Bih::Report.create!(organization: @organization, description: "Pokvarena rasvjeta")

        year = Time.current.year
        assert_equal "BR-#{year}-0001", first.reference
        assert_equal "BR-#{year}-0002", second.reference
      end

      test "auto-generates an unguessable status token" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Rupa na putu")

        assert_match Decidim::Bih::Report::STATUS_TOKEN_FORMAT, report.status_token
        assert_operator report.status_token.length, :>=, 32
        assert_equal "/biceriseno/prijave/#{report.reference}/status/#{report.status_token}",
                     report.tokenized_status_path
      end

      test "the per-year sequence is numeric and survives the 4-to-5 digit rollover" do
        year = Time.current.year
        Decidim::Bih::Report.create!(organization: @organization, description: "a", reference: "BR-#{year}-9999")
        Decidim::Bih::Report.create!(organization: @organization, description: "b", reference: "BR-#{year}-10000")

        next_report = Decidim::Bih::Report.create!(organization: @organization, description: "c")

        # Lexicographic MAX would wrongly pick "...-9999" and recompute 10000
        # forever, colliding; the sequence must be ordered numerically.
        assert_equal "BR-#{year}-10001", next_report.reference
      end

      test "reference uniqueness is validated per organization" do
        Decidim::Bih::Report.create!(organization: @organization, description: "Prva prijava", reference: "BR-2026-9999")
        dup = Decidim::Bih::Report.new(organization: @organization, description: "Duplikat", reference: "BR-2026-9999")

        assert_not dup.valid?
        assert_includes dup.errors.attribute_names, :reference
      end

      test "status token uniqueness is validated per organization" do
        token = "a" * 32
        Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Prva prijava",
          status_token: token
        )
        duplicate = Decidim::Bih::Report.new(
          organization: @organization,
          description: "Duplikat",
          status_token: token
        )
        other_organization = create_organization
        other_org_report = Decidim::Bih::Report.new(
          organization: other_organization,
          description: "Druga organizacija",
          status_token: token
        )

        assert_not duplicate.valid?
        assert_includes duplicate.errors.attribute_names, :status_token
        assert other_org_report.valid?
      end

      test "validates status inclusion" do
        report = Decidim::Bih::Report.new(organization: @organization, description: "Test", status: "nepostojeci")

        assert_not report.valid?
        assert_includes report.errors.attribute_names, :status
      end

      test "requires a description" do
        report = Decidim::Bih::Report.new(organization: @organization, description: nil)

        assert_not report.valid?
        assert_includes report.errors.attribute_names, :description
      end

      test "validates category inclusion when present" do
        invalid = Decidim::Bih::Report.new(organization: @organization, description: "Test", category: "nije_kategorija")
        assert_not invalid.valid?
        assert_includes invalid.errors.attribute_names, :category

        valid = Decidim::Bih::Report.new(organization: @organization, description: "Test", category: "putevi")
        assert valid.valid?
      end

      test "category may be nil" do
        report = Decidim::Bih::Report.new(organization: @organization, description: "Test", category: nil)

        assert report.valid?
      end

      test "to_forwarder_hash maps fields" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Rupa na putu",
          category: "putevi",
          department: "Putevi i infrastruktura",
          severity: "visok",
          address: "Glavna 1",
          latitude: 44.75,
          longitude: 19.21,
          reporter_email: "gradjanin@example.org"
        )

        hash = report.to_forwarder_hash

        assert_equal report.reference, hash[:reference]
        assert_equal :putevi, hash[:category]
        assert_equal "Putevi i infrastruktura", hash[:department]
        assert_equal :visok, hash[:severity]
        assert_equal "Rupa na putu", hash[:description]
        assert_equal "Glavna 1", hash[:address]
        assert_in_delta 44.75, hash[:lat]
        assert_in_delta 19.21, hash[:lng]
        assert_nil hash[:photo_url]
        assert_equal "gradjanin@example.org", hash[:reporter_contact]
      end

      test "to_forwarder_hash emits an absolute photo URL for the external inbox" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Sa slikom")
        report.photo.attach(io: StringIO.new("fake-image"), filename: "problem.jpg", content_type: "image/jpeg")

        url = report.to_forwarder_hash[:photo_url]

        assert url.start_with?("https://"), "expected absolute https URL, got #{url.inspect}"
        assert_includes url, @organization.host
        assert_includes url, "problem.jpg"
      end

      test "to_forwarder_hash omits reporter contact when anonymous" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Anonimna prijava",
          reporter_email: "tajni@example.org",
          reporter_phone: "065123456",
          anonymous: true
        )

        assert_nil report.to_forwarder_hash[:reporter_contact]
      end

      # --- Sistem 48 city status mirror ---

      test "sistem48_status_known? reflects whether the city status is present" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Test")

        assert_not report.sistem48_status_known?

        report.update_columns(sistem48_status: "Obrada u toku") # rubocop:disable Rails/SkipsModelValidations
        assert report.reload.sistem48_status_known?
      end

      test "sistem48_syncable scope includes non-terminal reports with a reference" do
        syncable = Decidim::Bih::Report.create!(
          organization: @organization, description: "a",
          status: "proslijedjeno", sistem48_reference: "2026055148"
        )
        terminal = Decidim::Bih::Report.create!(
          organization: @organization, description: "b",
          status: "rijeseno", sistem48_reference: "2026056629"
        )
        without_ref = Decidim::Bih::Report.create!(
          organization: @organization, description: "c", status: "proslijedjeno"
        )

        scoped = Decidim::Bih::Report.where(organization: @organization).sistem48_syncable

        assert_includes scoped, syncable
        assert_not_includes scoped, terminal
        assert_not_includes scoped, without_ref
      end

      # --- stale scope ---

      test "stale scope returns proslijedjeno reports older than STALE_DAYS" do
        stale = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Stara proslijeđena",
          status: "proslijedjeno",
          created_at: (Decidim::Bih::Report::STALE_DAYS + 1).days.ago
        )

        assert_includes Decidim::Bih::Report.stale, stale
      end

      test "stale scope returns u_obradi reports older than STALE_DAYS" do
        stale = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Stara u obradi",
          status: "u_obradi",
          created_at: (Decidim::Bih::Report::STALE_DAYS + 1).days.ago
        )

        assert_includes Decidim::Bih::Report.stale, stale
      end

      test "stale scope excludes reports younger than STALE_DAYS" do
        fresh = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Svježa proslijeđena",
          status: "proslijedjeno",
          created_at: 1.day.ago
        )

        assert_not_includes Decidim::Bih::Report.stale, fresh
      end

      test "stale scope excludes primljeno reports" do
        primljeno = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Primljeno",
          status: "primljeno",
          created_at: 60.days.ago
        )

        assert_not_includes Decidim::Bih::Report.stale, primljeno
      end

      test "stale scope excludes rijeseno reports" do
        rijeseno = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Riješeno",
          status: "rijeseno",
          created_at: 60.days.ago
        )

        assert_not_includes Decidim::Bih::Report.stale, rijeseno
      end

      test "stale scope excludes odbijeno reports" do
        odbijeno = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Odbijeno",
          status: "odbijeno",
          created_at: 60.days.ago
        )

        assert_not_includes Decidim::Bih::Report.stale, odbijeno
      end

      # --- notification callbacks ---

      test "status change out of primljeno enqueues email notification when reporter_email present" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava",
          reporter_email: "gradjanin@example.org"
        )

        assert_enqueued_emails 1 do
          report.update!(status: "proslijedjeno")
        end
      end

      test "no email enqueued when reporter_email is blank" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Anonimna prijava"
        )

        assert_enqueued_emails 0 do
          report.update!(status: "proslijedjeno")
        end
      end

      test "no notification enqueued when status does not change" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava",
          reporter_email: "gradjanin@example.org"
        )

        assert_enqueued_emails 0 do
          report.update!(address: "Nova adresa")
        end
      end

      test "no notification enqueued for initial primljeno status" do
        assert_enqueued_emails 0 do
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Nova prijava",
            reporter_email: "gradjanin@example.org"
          )
        end
      end

      test "notification does not raise when no reporter_email and no viber linkage" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Anonimna prijava"
        )

        assert_nothing_raised do
          report.update!(status: "proslijedjeno")
        end
      end

      # --- status_note visibility ---

      test "status email for odbijeno includes the rejection note" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava",
          reporter_email: "gradjanin@example.org"
        )

        # deliver_later enqueues; perform_enqueued_jobs flushes the queue
        # so ActionMailer::Base.deliveries is populated.
        perform_enqueued_jobs do
          report.update!(status: "odbijeno", status_note: "Prijava van nadležnosti.")
        end

        mail = ActionMailer::Base.deliveries.last
        assert_not_nil mail, "expected a status email to be delivered"
        assert_includes mail.body.to_s, "Prijava van nadležnosti."
      end

      test "status email for rijeseno does NOT include a note even when present" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava",
          reporter_email: "gradjanin@example.org"
        )

        perform_enqueued_jobs do
          report.update!(status: "rijeseno", status_note: "Interni komentar operatora.")
        end

        mail = ActionMailer::Base.deliveries.last
        assert_not_nil mail, "expected a status email to be delivered"
        assert_not_includes mail.body.to_s, "Interni komentar operatora."
      end

      test "account notification targets authenticated author without a legacy Viber linkage" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::Viber::BusinessContact.record!(user: author, phone: "+38765123456")
        report = Decidim::Bih::Report.create!(organization: @organization, author:,
                                              description: "Prijava", reporter_phone: "+38765123456")
        assert_enqueued_with(job: Decidim::Bih::AccountNotificationJob) do
          report.update!(status: "proslijedjeno")
        end
        intent = Decidim::Bih::AccountNotification.last
        assert_equal author, intent.user
        assert_equal "report_updates", intent.topic
        assert_equal "mi_status_prijave_v1", intent.payload.dig("template", "name")
        assert_equal report.reference, intent.payload.dig("template", "body", "1")
        assert_not_includes enqueued_jobs.inspect, "+38765123456"
      end

      test "planned status automatically explains collective submission without dates or questions" do
        author = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Bih::Viber::BusinessContact.record!(user: author, phone: "+38765123456")
        report = Decidim::Bih::Report.create!(organization: @organization, author:,
                                              description: "Prijava")
        report.update!(status: "planirano")
        intent = Decidim::Bih::AccountNotification.last
        explanation = I18n.t("decidim.bih.report_planning.citizen_notification", locale: @organization.default_locale)
        assert_includes intent.payload.fetch("text"), explanation
        assert_includes intent.payload.dig("template", "body", "2"), explanation
        report.update!(reporter_email: "citizen@example.org")
        mail = Decidim::Bih::ReporterMailer.status_update(report, locale: @organization.default_locale)
        assert_includes mail.body.to_s, explanation
        assert_no_match(/[0-9?]/, explanation)
        assert_no_enqueued_jobs(only: Decidim::Bih::AccountNotificationJob) do
          report.update!(address: "Preciznija lokacija")
        end
      end

      test "anonymous reporter phone cannot select someone else's account even with a linkage" do
        Decidim::Bih::Viber::Linkage.create!(organization: @organization, viber_sender: "opaque-id",
                                             phone: "38765123456", verified_at: Time.current)
        report = Decidim::Bih::Report.create!(organization: @organization, description: "Prijava",
                                              reporter_phone: "+387 65 123-456")
        assert_no_enqueued_jobs(only: Decidim::Bih::AccountNotificationJob) do
          report.update!(status: "proslijedjeno")
        end
      end

      # --- status_history lifecycle log ---

      test "creating a report records the initial status in the history" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Nova prijava"
        )

        history = report.reload.status_history
        assert_equal 1, history.size
        assert_equal "primljeno", history.first["status"]
        assert history.first["at"].present?
      end

      test "a status change appends a {status, at} entry to the history" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava"
        )

        report.update!(status: "proslijedjeno")

        history = report.reload.status_history
        statuses = history.map { |e| e["status"] }
        assert_equal %w(primljeno proslijedjeno), statuses
        assert(history.all? { |e| e["at"].present? })
      end

      test "multiple transitions accumulate in order" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava"
        )

        report.update!(status: "proslijedjeno")
        report.update!(status: "u_obradi")
        report.update!(status: "rijeseno")

        statuses = report.reload.status_history.map { |e| e["status"] }
        assert_equal %w(primljeno proslijedjeno u_obradi rijeseno), statuses
      end

      test "non-status updates do not append to the history" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava"
        )

        report.update!(address: "Nova adresa")

        assert_equal 1, report.reload.status_history.size
      end

      test "resolved_at returns the time the report reached rijeseno" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "x")
        report.update!(status: "proslijedjeno")
        travel 1.hour do
          report.update!(status: "rijeseno")
        end

        assert_not_nil report.resolved_at
        assert_in_delta report.status_history.last["at"].to_time, report.resolved_at, 1.second
      end

      test "resolved_at is nil for a report that has not been resolved" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "x")
        report.update!(status: "proslijedjeno")

        assert_nil report.resolved_at
      end

      test "resolved_at falls back to updated_at for a legacy rijeseno row with empty history" do
        report = Decidim::Bih::Report.create!(organization: @organization, description: "x")
        old = 10.days.ago
        report.update_columns( # rubocop:disable Rails/SkipsModelValidations
          status: "rijeseno", status_history: [], updated_at: old
        )

        assert_in_delta old, report.resolved_at, 1.second
      end

      test "the history entry timestamp is PII-free (only status and at keys)" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          description: "Test prijava",
          reporter_email: "tajni@example.org"
        )

        report.update!(status: "proslijedjeno")

        report.reload.status_history.each do |entry|
          assert_equal %w(at status), entry.keys.sort
        end
        assert_not_includes report.status_history.to_json, "tajni@example.org"
      end
    end
  end
end
