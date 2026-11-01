# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Sistem48
      class ReportMailerTest < ActionMailer::TestCase
        setup do
          @routing_env = %w(SISTEM48_FROM SISTEM48_CENTRAL_INTAKE SISTEM48_EMAIL_PUTEVI).to_h { |key| [key, ENV[key]] }
          @routing_config = [Decidim::Bih.sistem48_mailer_from, Decidim::Bih.sistem48_central_intake]
          @routing_env.each_key { |key| ENV.delete(key) }
          Decidim::Bih.sistem48_mailer_from = "reports@community.example.invalid"
          Decidim::Bih.sistem48_central_intake = "intake@community.example.invalid"
          assert_equal :test, ReportMailer.delivery_method
        end

        teardown do
          Decidim::Bih.sistem48_mailer_from, Decidim::Bih.sistem48_central_intake = @routing_config
          @routing_env.each { |key, prior| prior.nil? ? ENV.delete(key) : ENV[key] = prior }
        end

        def report(overrides = {})
          {
            reference: "TEST-2040-900001",
            category: :putevi,
            department: "Izmišljena služba za test",
            severity: :visok,
            description: "IZMIŠLJENA TESTNA PRIJAVA — nije stvarni događaj.",
            address: "Izmišljena ulica 12, Testna zajednica",
            lat: 0.505172,
            lng: 0.505956,
            photo_url: "https://files.example.invalid/authored-report.jpg",
            reporter_contact: "IZMIŠLJENI PRIJAVILAC, TEST-CONTACT"
          }.merge(overrides)
        end

        # Authored toy polygon near (0.5, 0.5), with invented contact labels.
        def create_mz(organization)
          Decidim::Bih::LocalArea.create!(
            organization:,
            kind: "mz",
            slug: "mz-mailer-centar",
            name: { "sr" => "MZ Izmišljeni vrt", "en" => "MZ Izmišljeni vrt" },
            predsjednik: "IZMIŠLJENI PREDSTAVNIK",
            telefon: "TEST-PHONE",
            boundary: {
              "type" => "Polygon",
              "coordinates" => [
                [
                  [0.500, 0.500],
                  [0.510, 0.500],
                  [0.510, 0.510],
                  [0.500, 0.510],
                  [0.500, 0.500]
                ]
              ]
            }
          )
        end

        # ─── W6.3: additive MZ-president context in the forward ──────────────

        test "includes the MZ and its president when coordinates resolve to an MZ" do
          organization = create_organization
          create_mz(organization)

          body = ReportMailer.report_email(report(organization_id: organization.id)).body.to_s

          assert_includes body, "Mjesna zajednica: MZ Izmišljeni vrt"
          assert_includes body, "Predsjednik MZ: IZMIŠLJENI PREDSTAVNIK"
          assert_includes body, "Telefon MZ: TEST-PHONE"
        end

        test "still routes to the central intake — MZ enrichment is additive, not a re-route" do
          organization = create_organization
          create_mz(organization)

          mail = ReportMailer.report_email(report(organization_id: organization.id))

          assert_equal [DepartmentRouting.central_intake], mail.to
        end

        test "omits the MZ section when coordinates fall outside every MZ" do
          organization = create_organization
          create_mz(organization)

          body = ReportMailer.report_email(
            report(organization_id: organization.id, lat: 0.900, lng: 0.950)
          ).body.to_s

          assert_not_includes body, "Mjesna zajednica:"
        end

        test "omits the MZ section when no organization is resolved" do
          # No organization_id (older payload / standalone) => no geo lookup.
          body = ReportMailer.report_email(report).body.to_s

          assert_not_includes body, "Mjesna zajednica:"
        end

        test "omits the MZ section when coordinates are blank" do
          organization = create_organization
          create_mz(organization)

          body = ReportMailer.report_email(
            report(organization_id: organization.id, lat: nil, lng: nil)
          ).body.to_s

          assert_not_includes body, "Mjesna zajednica:"
        end

        test "text-only and incomplete coordinates preserve the location without an empty map link" do
          [[nil, nil], ["", ""], [0.505172, nil], [nil, 0.505956]].each do |lat, lng|
            body = ReportMailer.report_email(report(lat:, lng:)).body.to_s

            assert_includes body, "Lokacija: Izmišljena ulica 12, Testna zajednica"
            assert_not_includes body, "Koordinate:"
            assert_not_includes body, "Mapa:"
            assert_not_includes body, "openstreetmap.org"
          end
        end

        test "renders the MZ name in Serbian even when the ambient locale is not Serbian" do
          organization = create_organization
          mz = create_mz(organization)
          mz.update!(name: {
                       "sr" => "Mjesna zajednica Izmišljeni vrt",
                       "en" => "Fictional Garden Community",
                       "hr" => "Izmišljeni kvart"
                     })

          body = I18n.with_locale(:en) do
            ReportMailer.report_email(report(organization_id: organization.id)).body.to_s
          end

          assert_includes body, "Mjesna zajednica: Mjesna zajednica Izmišljeni vrt"
          assert_not_includes body, "Fictional Garden Community"
        end

        test "shows the MZ name but omits the president line when no president is on file" do
          organization = create_organization
          mz = create_mz(organization)
          mz.update!(predsjednik: nil, telefon: nil)

          body = ReportMailer.report_email(report(organization_id: organization.id)).body.to_s

          assert_includes body, "Mjesna zajednica: MZ Izmišljeni vrt"
          assert_not_includes body, "Predsjednik MZ:"
          assert_not_includes body, "Telefon MZ:"
        end

        test "routes to the central intake and carries reference + category in the subject" do
          mail = ReportMailer.report_email(report)

          assert_equal [DepartmentRouting.central_intake], mail.to
          assert_equal [Decidim::Bih.sistem48_mailer_from], mail.from
          assert_includes mail.subject, "TEST-2040-900001"
          assert_includes mail.subject, "putevi"
        end

        test "body is enriched FixMyStreet-style with reference, category and an OSM map link" do
          body = ReportMailer.report_email(report).body.to_s

          assert_includes body, "TEST-2040-900001"
          assert_includes body, "putevi"
          assert_includes body, "Izmišljena služba za test"
          assert_includes body, "IZMIŠLJENA TESTNA PRIJAVA — nije stvarni događaj."
          assert_includes body, "0.505172,0.505956"
          assert_includes body,
                          "https://www.openstreetmap.org/?mlat=0.505172&mlon=0.505956#map=18/0.505172/0.505956"
          assert_includes body, "IZMIŠLJENI PRIJAVILAC, TEST-CONTACT"
          assert_includes body, "fotografija"
        end

        test "shows 'anonimno' when no reporter contact is given" do
          body = ReportMailer.report_email(report(reporter_contact: nil)).body.to_s

          assert_includes body, "Kontakt prijavioca: anonimno"
        end

        test "omits the photo note when no photo is attached" do
          body = ReportMailer.report_email(report(photo_url: nil)).body.to_s

          assert_not_includes body, "fotografija"
        end

        test "the configured message is delivered to the in-memory test transport" do
          assert_emails 1 do
            ReportMailer.report_email(report).deliver_now
          end
          assert_equal [DepartmentRouting.central_intake], ActionMailer::Base.deliveries.last.to
        end

        # ─── Urgent (hitan) flagging — subject marker + prominent body line ───

        test "prefixes the subject with an urgency marker for a hitan report (symbol)" do
          subject = ReportMailer.report_email(report(severity: :hitan)).subject

          assert subject.start_with?("[HITNO] "), "expected subject to start with [HITNO] , got: #{subject}"
          assert_includes subject, "TEST-2040-900001"
          assert_includes subject, "putevi"
        end

        test "prefixes the subject with an urgency marker for a hitan report (string)" do
          subject = ReportMailer.report_email(report(severity: "hitan")).subject

          assert subject.start_with?("[HITNO] "), "expected subject to start with [HITNO] , got: #{subject}"
        end

        test "leaves the subject byte-identical for a non-hitan (normalan) report" do
          subject = ReportMailer.report_email(report(severity: :normalan)).subject

          assert_equal "Prijava problema [TEST-2040-900001] — putevi", subject
        end

        test "renders the Hitnost line prominently for a hitan report" do
          body = ReportMailer.report_email(report(severity: :hitan)).body.to_s

          assert_includes body, "⚠ HITNOST: HITAN ⚠"
        end

        test "leaves the Hitnost line byte-identical for a non-hitan (normalan) report" do
          body = ReportMailer.report_email(report(severity: :normalan)).body.to_s

          assert_includes body, "Hitnost: normalan"
          assert_not_includes body, "⚠"
        end
      end
    end
  end
end
