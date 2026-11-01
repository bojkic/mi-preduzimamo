# frozen_string_literal: true

require "sidekiq/web"

Rails.application.routes.draw do
  post "/locale", to: "decidim_app/locales#create", as: :mi_locale
  get "/sitemap.xml", to: "decidim_app/sitemaps#show", defaults: { format: :xml }
  # Milica's expiring browser-bound auth return; ticket stays in the session.
  get "/u-komsiluku/usluge", to: "decidim_app/komsiluk_context#services", as: :komsiluk_services
  get "/u-komsiluku/objave/:id/milica", to: "decidim_app/komsiluk_context#notice_help", as: :komsiluk_notice_help
  get "/milica/prijava", to: "decidim_app/milica_registration_handoffs#show", as: :milica_registration_handoff

  # Infobip Viber inbound webhook for the "Mi pre(d)uzimamo!" concierge bot.
  # Declared BEFORE the engine mount so it is not shadowed by /biceriseno.
  post "/biceriseno/viber/webhook", to: "decidim_app/viber/webhook#create"

  # Authenticated Infobip inbound chat webhooks. Each route has a fixed action
  # so request JSON can never select a different configured channel.
  post "/biceriseno/viber-bm/webhook", to: "decidim_app/infobip/webhook#viber_bm"
  post "/biceriseno/whatsapp/webhook", to: "decidim_app/infobip/webhook#whatsapp"
  post "/biceriseno/messenger/webhook", to: "decidim_app/infobip/webhook#messenger"
  post "/biceriseno/instagram/webhook", to: "decidim_app/infobip/webhook#instagram"

  # Opaque Instagram/Messenger handoff into the one-step phone registration.
  # The credential stays in the filtered query string on GET; POST uses the
  # encrypted browser session and redirects to a clean registration URL.
  get "/registracija/drustvene-mreze",
      to: "decidim_app/social_registration_handoffs#show",
      as: :social_registration_handoff
  post "/registracija/drustvene-mreze", to: "decidim_app/social_registration_handoffs#create"

  # One-step registration (isporuka D, spec 5.2–5.4). The engine serves the
  # whole flow under its own mount as well; these ROOT paths exist because the
  # form goes on posters and into SMS, where every character is paid for, and
  # because a citizen who arrived at the short path must stay on it — the
  # engine builds every in-flow URL from Decidim::Bih.registration_base_path,
  # which config/initializers/decidim_bih_registration.rb points here.
  # Declared BEFORE the mounts so neither /biceriseno nor Core's "/" catch-all
  # shadows them; the verbs mirror the engine's own routes exactly.
  get "/registracija", to: "decidim/bih/registrations#new", as: :phone_registration_root
  post "/registracija", to: "decidim/bih/registrations#create"
  get "/registracija/potvrda", to: "decidim/bih/registrations#pending"
  post "/registracija/potvrda/ponovo", to: "decidim/bih/registrations#resend"
  post "/registracija/potvrda/kod", to: "decidim/bih/registrations#confirm"
  # A POST, never a GET (R-D4): this poll can sign the waiting browser in, and
  # a state-changing endpoint must not be reachable by a prefetch or a crawler.
  # Rails appends (.:format), so /registracija/potvrda/status.json is this same
  # route — no separate literal-dot route is needed.
  post "/registracija/potvrda/status", to: "decidim/bih/registrations#status", defaults: { format: :json }
  delete "/registracija/potvrda", to: "decidim/bih/registrations#change"
  post "/registracija/potvrda/pocni-ispocetka", to: "decidim/bih/registrations#start_over"

  # The short invite link a citizen can say aloud or print as a QR code:
  # /p/<nadimak> 302s to /registracija?ref=<nadimak> (the engine's controller
  # does the redirect; the registration form captures the code). GET only, no
  # state. config/initializers/decidim_bih_goodwill.rb sets
  # Decidim::Bih.invite_short_path to "/p" so the shared links are built here.
  get "/p/:code", to: "decidim/bih/invite_links#short", constraints: { code: /[\w-]+/ }, as: :short_invite

  # Decidim's own sign-up is now a door into the same room, so it redirects
  # rather than opening a second, password-based one. 302 and not 301: a 301 is
  # cached by browsers and would outlive a rollback of this delivery.
  #
  # ONLY these two verbs, deliberately. Decidim's devise_for exposes just
  # new/create under /users (account edit lives at /account, deletion at
  # DELETE /account), so a redirect on any other verb would be inventing a
  # route Decidim never had — and shadowing whatever it puts there next. Every
  # /users/sign_in, password, confirmation and omniauth route is untouched.
  get "/users/sign_up", to: redirect("/registracija", status: 302)
  post "/users", to: redirect("/registracija", status: 302)

  # Decidim 0.32 also exposes sign-up below each locale. Keep those doors
  # on the same phone-first flow without shadowing other account actions.
  scope "/:locale", constraints: { locale: /sr|sr-Cyrl|bs|hr/ } do
    get "/users/sign_up", to: redirect(status: 302) { |params, _request| "/registracija?locale=#{params[:locale]}" }
    post "/users", to: redirect(status: 302) { |params, _request| "/registracija?locale=#{params[:locale]}" }
  end

  # Event links share /v/ token redaction and require POST to sign in.
  get "/v/:token", to: "decidim_app/launch_event_links#show", constraints: { token: /event-[A-Za-z0-9_-]{32}/ }, as: :launch_event_link
  post "/v/:token", to: "decidim_app/launch_event_links#consume", constraints: { token: /event-[A-Za-z0-9_-]{32}/ }
  get "/lansiranje/anketa", to: "decidim_app/launch_event_polls#show", as: :launch_event_poll
  get "/lansiranje/anketa/rezultati", to: "decidim_app/launch_event_polls#results", as: :launch_event_poll_results
  post "/lansiranje/anketa/glas", to: "decidim_app/launch_event_polls#vote", as: :launch_event_poll_vote
  get "/admin/lansiranje", to: "decidim_app/admin/launch_events#show", as: :launch_event_admin
  post "/admin/lansiranje/posalji", to: "decidim_app/admin/launch_events#send_message", as: :launch_event_send
  post "/admin/lansiranje/proba", to: "decidim_app/admin/launch_events#test_message", as: :launch_event_test

  # Short magic-link routes so SMS link is /v/<token> (length-sensitive).
  get "/v/:token", to: "decidim/bih/magic_links#show"
  post "/v/:token", to: "decidim/bih/magic_links#consume"

  # Stable, non-personal Komšiluk campaign links for printed materials and QR.
  # A scan only redirects to the matching filtered Decidim proposals list.
  get "/k/:area", to: "decidim_app/komsiluk_campaign_links#show", as: :komsiluk_campaign_short

  # Legacy city-data URLs kept as redirects to MI bot. Declared BEFORE the
  # engine mount so old links do not fall through to engine routing.
  get "/biceriseno/odvoz-smeca", to: "decidim_app/city_pages#waste", as: :city_waste
  get "/biceriseno/budzet", to: "decidim_app/city_pages#budget", as: :city_budget

  # Community-support projects are a separate product from participatory
  # budgeting. The old Decidim process URL now points to the dedicated project
  # catalog; its unpublished native process is only an internal storage seam.
  get "/processes/projekti-zajednice", to: redirect("/biceriseno/projekti", status: 302)
  get "/processes/projekti-zajednice/f/:component_id/budgets/:budget_id/projects/:id",
      to: redirect(status: 302) { |params, _request| "/biceriseno/projekti/#{params[:id]}" },
      constraints: { component_id: /\d+/, budget_id: /\d+/, id: /\d+/ }
  get "/processes/projekti-zajednice/*legacy_path", to: redirect("/biceriseno/projekti", status: 302)

  scope "/admin/bih", module: "decidim_app/admin", as: "decidim_app_admin" do
    get "/komsiluk-posts/:id/source", to: "komsiluk_sources#show", as: :komsiluk_source
    patch "/komsiluk-posts/:id/source", to: "komsiluk_sources#update"
    get "/city-alerts", to: "city_service_events#index", as: :city_service_events
    post "/city-alerts/automation-policy", to: "city_service_events#automation_policy", as: :city_service_automation_policy
    post "/city-alerts/bulk-check-automatic", to: "city_service_events#bulk_check_automatic", as: :city_service_events_bulk_check_automatic
    post "/city-alerts/:id/check-automatic", to: "city_service_events#check_automatic_publication", as: :city_service_event_check_automatic
    post "/city-alerts/:id/incident", to: "city_service_events#incident_decision", as: :city_service_event_incident
    post "/city-alerts/bulk-review", to: "city_service_events#bulk_review", as: :city_service_events_bulk_review
    post "/city-alerts/:id/revoke-answers",
         to: "city_service_events#revoke_answers", as: :city_service_event_revoke_answers
    post "/city-alerts/:id/approve-answers",
         to: "city_service_events#approve_answers", as: :city_service_event_approve_answers
    post "/city-alerts/:id/revoke-coverage", to: "city_service_events#revoke_coverage", as: :city_service_event_revoke_coverage
    get "/city-alerts/:id/map", to: "city_service_events#map", as: :city_service_event_map
    patch "/city-alerts/:id", to: "city_service_events#update", as: :city_service_event
    post "/city-alerts/:id/publish-board",
         to: "city_service_events#publish_board", as: :city_service_event_publish_board
    post "/city-alerts/:id/publish-viber",
         to: "city_service_events#publish_viber", as: :city_service_event_publish_viber
    get "/city-alerts/:id/notification-preview",
        to: "city_service_events#notification_preview", as: :city_service_event_notification_preview
    post "/city-alerts/:id/withdraw", to: "city_service_events#withdraw", as: :city_service_event_withdraw
    post "/city-alerts/:id/dismiss",
         to: "city_service_events#dismiss", as: :city_service_event_dismiss

    # Admin content editor pilot: operator overrides of the shipped city-service
    # FAQ answers, and the foundation's own call status. Same permission as the
    # city alerts above; keys are the shipped CityServicesData::ENTRIES keys.
    get "/city-faq", to: "city_service_entries#index", as: :city_service_entries
    get "/city-faq/:key/edit", to: "city_service_entries#edit", as: :city_service_entry_edit, constraints: { key: /[a-z0-9_]+/ }
    get "/city-faq/:key/preview", to: "city_service_entries#preview", as: :city_service_entry_preview, constraints: { key: /[a-z0-9_]+/ }
    patch "/city-faq/:key", to: "city_service_entries#update", as: :city_service_entry, constraints: { key: /[a-z0-9_]+/ }
    post "/city-faq/:key/approve", to: "city_service_entries#approve", as: :city_service_entry_approve, constraints: { key: /[a-z0-9_]+/ }
    post "/city-faq/:key/rollback", to: "city_service_entries#rollback", as: :city_service_entry_rollback, constraints: { key: /[a-z0-9_]+/ }
    get "/foundation-status", to: "foundation_status#show", as: :foundation_status
    patch "/foundation-status", to: "foundation_status#update"
    post "/foundation-status/approve", to: "foundation_status#approve", as: :foundation_status_approve
    post "/foundation-status/rollback", to: "foundation_status#rollback", as: :foundation_status_rollback
  end

  # Read-only community projector screen. A short root path so it can be typed
  # into a venue laptop; it renders the engine's read-only aggregate screen.
  # Declared BEFORE the engine mount so it is not shadowed by /biceriseno.
  # Rails already appends (.:format) to every route, so /ekran.json is matched
  # by this same route — no separate literal-dot route is needed.
  get "/ekran", to: "decidim/bih/screen#show", as: :venue_screen

  # Launch-campaign pages. Short root paths because they go on posters and into
  # SMS, where every character is paid for. `page:` MUST go through `defaults:`
  # — an inline `page:` on the route itself becomes a routing CONSTRAINT, not a
  # param, and the controller would never see it.
  # Keep the established campaign entry point as a reversible redirect.
  # A permanent redirect could outlive rollback. The survey routes above
  # remain separate; each community publishes its configured event notice.
  get "/lansiranje", to: redirect("/trka", status: 302), as: :launch_event
  get "/pozivnica", to: "decidim_app/launch_pages#show", defaults: { page: "pozivnica" }, as: :launch_invitation_rules
  get "/trka", to: "decidim_app/launch_pages#show", defaults: { page: "trka" }, as: :launch_race_rules
  get "/moderacija", to: "decidim_app/launch_pages#show", defaults: { page: "moderacija" }, as: :launch_moderation
  get "/neutralnost", to: "decidim_app/launch_pages#show", defaults: { page: "neutralnost" }, as: :launch_neutrality
  get "/pitanja", to: "decidim_app/launch_pages#show", defaults: { page: "pitanja" }, as: :launch_faq
  get "/otvoreni-kod", to: "decidim_app/open_source#show", as: :open_source
  get "/ko-smo", to: "decidim_app/launch_pages#show", defaults: { page: "ko-smo" }, as: :launch_about

  # "Bice riseno" anonymous civic problem-reporting intake surface.
  # Mounted BEFORE Core so Core's "/" catch-all routes don't shadow it.
  mount Decidim::Bih::Engine => "/biceriseno"
  mount Decidim::Core::Engine => "/"
  authenticate :user, ->(u) { u.admin? } do
    mount Sidekiq::Web => "/sidekiq"
  end
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", :as => :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", :as => :pwa_service_worker, :defaults => { format: :js }
  get "manifest" => "rails/pwa#manifest", :as => :pwa_manifest

  # Defines the root path route ("/")
  # root "posts#index"
end
