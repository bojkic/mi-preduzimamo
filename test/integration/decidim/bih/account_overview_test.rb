# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class AccountOverviewTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "anonymous visitors are redirected to sign in" do
        get "/biceriseno/moj-nalog"

        assert_response :redirect
        assert_redirected_to "/users/sign_in"
      end

      test "core account path opens the MI account overview by default" do
        sign_in @user

        get "/account"

        assert_response :redirect
        assert_redirected_to "/biceriseno/moj-nalog"
      end

      test "account settings are integrated while the core fallback remains reachable" do
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Profil i postavke naloga"
        assert_includes response.body, "name=\"user[name]\""
        assert_includes response.body, "action=\"/biceriseno/moj-nalog\""
        assert_includes response.body, "href=\"#osnovni-podaci\""

        get "/account", params: { settings: "1" }

        assert_response :success
        assert_includes response.body, "Ažuriraj nalog"
        assert_includes response.body, "name=\"user[name]\""
      end

      test "citizens can update core account fields from the MI account overview" do
        sign_in @user

        put "/biceriseno/moj-nalog", params: {
          user: {
            name: "Mila Gradjanka",
            nickname: "mila-gradjanka",
            email: @user.email,
            personal_url: "https://example.org/mila",
            about: "Volim svoj komsiluk.",
            locale: @user.locale
          }
        }

        assert_redirected_to "/biceriseno/moj-nalog#osnovni-podaci"
        @user.reload
        assert_equal "Mila Gradjanka", @user.name
        assert_equal "mila-gradjanka", @user.nickname
        assert_equal "https://example.org/mila", @user.personal_url
        assert_equal "Volim svoj komsiluk.", @user.about
      end

      test "phone-only citizens can update core account fields without adding email or sending update mail" do
        @user = FactoryBot.create(:user, :confirmed, organization: @organization, email: "", extended_data: { "mi_phone_only_registration" => true })
        sign_in @user

        assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
          put "/biceriseno/moj-nalog", params: {
            user: {
              name: "Mila Gradjanka",
              nickname: "mila-phone-only",
              email: "",
              personal_url: "https://example.org/mila",
              about: "Volim svoj komsiluk.",
              locale: @user.locale
            }
          }
        end

        assert_redirected_to "/biceriseno/moj-nalog#osnovni-podaci"
        @user.reload
        assert_equal "", @user.email
        assert_equal "Mila Gradjanka", @user.name
        assert_equal "mila-phone-only", @user.nickname
        assert_equal "https://example.org/mila", @user.personal_url
        assert_equal "Volim svoj komsiluk.", @user.about
      end

      test "signed-in citizens see the account setup overview and quick links" do
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 100, reason: "report")
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Moj nalog"
        assert_includes response.body, "Završi nalog"
        assert_includes response.body, "Izaberi Komšiluk"
        assert_includes response.body, "Potvrdi telefon"
        assert_includes response.body, "Potvrdi adresu pismom"
        assert_includes response.body, "Dva načina verifikacije"
        assert_includes response.body, "/postal_letter/"
        assert_includes response.body, "/biceriseno/moj-doprinos"
        # Phase 4: both the button and the card now lead to the one canonical
        # communication page rather than Decidim's notifications settings.
        assert_includes response.body, "/biceriseno/moj-nalog/poruke"
        assert_includes response.body, "Zatraži pismo"
        assert_includes response.body, "Još nije zatraženo"
        assert_includes response.body, "Profil i postavke naloga"
        assert_includes response.body, "Sakrij javni doprinos"
        assert_not_includes response.body, "Javni profil i doprinos"
        assert_includes response.body, "Prijave problema"
        assert_includes response.body, "Praćene teme"
        assert_includes response.body, "Odgovori"
        assert_includes response.body, "Bodova do sljedećeg nivoa"
        assert_includes response.body, "Viber asistent"
        assert_includes response.body, "Nije povezan"
        assert_not_includes response.body, "Sedmični niz"
        assert_includes response.body, "Prijavi organizaciju"
        assert_select ".mi-account-links a[href=?]", "/biceriseno/organizacije/nova"
        assert_select ".mi-account-links a[href=?]", "/biceriseno/moj-doprinos", count: 0
        assert_select ".mi-account-links a[href=?]", "/biceriseno/prijave", count: 0
        assert_select ".mi-account-links a[href=?]", "/biceriseno/volontiranje", count: 0
        assert_select ".mi-account-links a[href=?]", "/biceriseno/komsiluk-board", count: 0
        assert_operator response.body.index("Završi nalog"), :<, response.body.index("Profil i postavke naloga")
        assert_operator response.body.index("Dva načina verifikacije"), :<, response.body.index("Profil i postavke naloga")
        assert_operator response.body.index("Profil i postavke naloga"), :<, response.body.index("Šta pratiš sada")
      end

      test "account quick links include the citizen's organization memberships" do
        profile = Decidim::Bih::PartnerProfile.create!(
          organization: @organization,
          display_name: "Udruženje Moj Grad",
          slug: "udruzenje-moj-grad",
          kind: "association",
          verification_status: "verified",
          verified_at: Time.current
        )
        profile.memberships.create!(
          organization: @organization,
          user: @user,
          role: "owner",
          status: "accepted",
          accepted_at: Time.current
        )
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_select ".mi-account-links a[href=?]", "/biceriseno/organizacije"
        assert_select ".mi-account-links a[href=?]", "/biceriseno/organizacija/udruzenje-moj-grad"
        assert_includes response.body, "Moje organizacije"
        assert_includes response.body, "Udruženje Moj Grad"
      end

      test "citizens can hide and show public profile recognition" do
        sign_in @user

        patch "/biceriseno/moj-nalog/javno-priznanje", params: { enabled: "0" }

        assert_redirected_to "/biceriseno/moj-nalog#osnovni-podaci"
        assert_equal false, @user.reload.extended_data["bih_public_recognition"]
        follow_redirect!
        assert_response :success
        assert_includes response.body, "Sakriveno"
        assert_includes response.body, "Prikaži javni doprinos"

        patch "/biceriseno/moj-nalog/javno-priznanje", params: { enabled: "1" }

        assert_redirected_to "/biceriseno/moj-nalog#osnovni-podaci"
        assert_equal true, @user.reload.extended_data["bih_public_recognition"]
      end

      test "postal verification pending state is visible on the account overview" do
        Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          granted_at: nil,
          verification_metadata: { "letter_sent_at" => Time.current.iso8601 }
        )
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Zatraženo, čeka štampu"
        assert_includes response.body, "Pismo je zatraženo ili poslano"
        assert_includes response.body, "/postal_letter/"
      end

      test "postal verification sent state links to manual code entry" do
        Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          granted_at: nil,
          verification_metadata: {
            "verification_code" => "112233",
            "letter_sent_at" => Time.current.iso8601
          }
        )
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Poslano, čeka kod"
        assert_includes response.body, "Upiši kod"
        assert_includes response.body, "/postal_letter/authorizations/edit"
      end

      test "verified phone and postal status are marked complete" do
        Decidim::Authorization.create!(
          user: @user,
          name: "sms",
          unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765123456"),
          granted_at: Time.current,
          verification_metadata: {}
        )
        # A grant on its own is no longer the whole story: Decidim::Bih::
        # AccountSummary#phone_step reports :reverify — "confirmed, but the
        # number was not kept" — for a granted sms authorization with no
        # CitizenPhone row, because the platform now messages that number.
        # A genuinely finished phone verification has both, so the fixture
        # has both.
        Decidim::Bih::VerifiedPhone.synchronize!(user: @user, organization: @organization, phone: "+38765123456")
        Decidim::Authorization.create!(
          user: @user,
          name: "postal_letter",
          granted_at: Time.current,
          verification_metadata: {}
        )
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Telefon je potvrđen"
        assert_includes response.body, "Adresa je potvrđena pismom"
        assert_not_includes response.body, "Čeka potvrdu"
      end

      test "account overview summarizes current reports rewards and volunteering" do
        report = Decidim::Bih::Report.create!(
          organization: @organization,
          author: @user,
          description: "Rupa na putu kod skole",
          status: "u_obradi"
        )
        Decidim::Bih::Goodwill::Ledger.new.award(@user, 600, reason: "volunteer_hour")
        Decidim::Bih::Goodwill::RedeemReward.call(@user, "majica")
        opportunity = Decidim::Bih::VolunteerOpportunity.create!(
          organization: @organization,
          title: "Čišćenje parka",
          active: true,
          review_status: "approved",
          starts_at: 2.days.from_now
        )
        Decidim::Bih::VolunteerSignup.create!(
          organization: @organization,
          opportunity:,
          user: @user,
          status: "waitlisted",
          review_status: "automatic",
          review_source: "automatic",
          queued_at: Time.current
        )
        create_legacy_volunteer_log!(
          organization: @organization,
          opportunity:,
          user: @user,
          hours: 1,
          status: "pending"
        )
        followed_user = FactoryBot.create(:user, :confirmed, organization: @organization)
        Decidim::Follow.create!(user: @user, followable: followed_user)
        user_type = "Decidim::UserBaseEntity"
        now = Time.current
        # These rows exercise the private account summary query without requiring
        # a full Decidim commentable resource and its counter callbacks.
        # rubocop:disable Rails/SkipsModelValidations
        parent_comment_id = Decidim::Comments::Comment.insert_all!(
          [{
            decidim_commentable_type: user_type,
            decidim_commentable_id: followed_user.id,
            decidim_root_commentable_type: user_type,
            decidim_root_commentable_id: followed_user.id,
            decidim_author_type: user_type,
            decidim_author_id: followed_user.id,
            body: { "sr" => "Roditeljski komentar" },
            depth: 0,
            alignment: 0,
            comments_count: 0,
            up_votes_count: 0,
            down_votes_count: 0,
            created_at: now,
            updated_at: now
          }],
          returning: %w(id)
        ).rows.first.first
        Decidim::Comments::Comment.insert_all!(
          [{
            decidim_commentable_type: "Decidim::Comments::Comment",
            decidim_commentable_id: parent_comment_id,
            decidim_root_commentable_type: user_type,
            decidim_root_commentable_id: followed_user.id,
            decidim_author_type: user_type,
            decidim_author_id: @user.id,
            body: { "sr" => "Moj odgovor" },
            depth: 1,
            alignment: 0,
            comments_count: 0,
            up_votes_count: 0,
            down_votes_count: 0,
            created_at: now,
            updated_at: now
          }]
        )
        # rubocop:enable Rails/SkipsModelValidations
        Decidim::Bih::VolunteerOpportunity.create!(
          organization: @organization,
          title: "Sadnja drveća",
          active: true,
          review_status: "approved",
          starts_at: 4.days.from_now
        )
        Decidim::Bih::Viber::Linkage.create!(
          organization: @organization,
          user: @user,
          viber_sender: "sender-account-overview",
          verified_at: Time.current
        )
        sign_in @user

        get "/biceriseno/moj-nalog"

        assert_response :success
        assert_includes response.body, "Šta pratiš sada"
        assert_includes response.body, "Prijava #{report.reference}"
        assert_includes response.body, "U obradi"
        assert_includes response.body, "Majica"
        assert_includes response.body, "Zatraženo"
        assert_includes response.body, "/biceriseno/zajednistvo?tab=nagrade"
        assert_includes response.body, "Čišćenje parka"
        assert_includes response.body, "Na listi čekanja"
        assert_includes response.body, "/biceriseno/volontiranje"
        assert_includes response.body, "Praćene teme"
        assert_includes response.body, "1 praćenih tema i autora"
        assert_includes response.body, "/profiles/#{@user.nickname}/following"
        assert_includes response.body, "Odgovori"
        assert_includes response.body, "1 tvojih odgovora u raspravama"
        assert_includes response.body, "/profiles/#{@user.nickname}/activity"
        assert_includes response.body, "Povezan"
      end
    end
  end
end
