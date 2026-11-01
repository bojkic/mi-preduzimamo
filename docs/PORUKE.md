# Mapa izvora poruka

Ovaj pregled nastaje isključivo iz registra u engine-u; ne sadrži liste primalaca, pristupne podatke niti dokaz stvarnog slanja.

Brojevi: 57 izvora poruka — 8 shadow, 49 legacy/unmigrated.

`shadow` prati odluke; postojeći pozivalac zadržava odluku o slanju. `legacy/unmigrated` označava zaseban postojeći put. Prisustvo klase u registru ne uključuje kanal ni pružaoca.

| Klasa | Namjena | Primalac | Pravilo izbora | Kanali | Stanje | Izvor koda |
|---|---|---|---|---|---|---|
| `authentication.phone_verification` | authentication | pending_authentication, account | requested_authentication | viber, whatsapp, sms (fallback) | legacy_unmigrated | engine:app/commands/decidim/bih/register_with_phone.rb; engine:app/controllers/concerns/decidim/bih/phone_verification_actions.rb; engine:app/services/decidim/bih/sms/infobip_gateway.rb |
| `authentication.phone_login` | authentication | account | requested_authentication | viber, whatsapp, sms (fallback) | legacy_unmigrated | engine:app/controllers/decidim/bih/phone_sessions_controller.rb; engine:app/jobs/decidim/bih/infobip/send_phone_message_job.rb |
| `authentication.viber_bot_link` | authentication | pending_authentication | requested_authentication | sms (single) | legacy_unmigrated | engine:app/services/decidim/bih/viber/account_linking.rb; engine:app/services/decidim/bih/viber/queued_phone_message_gateway.rb |
| `registration.resume_email` | account_lifecycle | pending_authentication | core_transactional | email (parallel) | legacy_unmigrated | engine:app/jobs/decidim/bih/resume_registration_email_job.rb; engine:app/mailers/decidim/bih/registration_mailer.rb |
| `registration.final_notice_email` | account_lifecycle | pending_authentication | core_transactional | email (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/registration/pending_lifecycle.rb; engine:app/mailers/decidim/bih/registration_mailer.rb |
| `registration.operator_resend` | account_lifecycle | pending_authentication | requested_authentication | email (parallel); sms (single) | legacy_unmigrated | engine:app/commands/decidim/bih/registration/resend_verification.rb; engine:app/controllers/decidim/bih/admin/pending_registrations_controller.rb; engine:lib/tasks/decidim_bih_registration.rake |
| `account.email_confirmation` | account_lifecycle | account | core_transactional | email (parallel) | legacy_unmigrated | engine:app/controllers/decidim/bih/email_confirmations_controller.rb; engine:app/mailers/decidim/bih/email_confirmation_mailer.rb |
| `account.channel_test` | optional_news | account | one_time_test_permission | viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/controllers/decidim/bih/account_notification_settings_controller.rb; engine:app/services/decidim/bih/account_notifications.rb |
| `account.push_test` | account_lifecycle | account | device_subscription | push (parallel) | legacy_unmigrated | engine:app/controllers/decidim/bih/web_push_tests_controller.rb |
| `goodwill.launch_invitation_phone` | account_lifecycle | account | requested_authentication | viber, whatsapp, sms (fallback) | legacy_unmigrated | engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb |
| `goodwill.launch_invitation_email` | account_lifecycle | account | core_transactional | email (parallel) | legacy_unmigrated | engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb; engine:app/mailers/decidim/bih/goodwill/launch_invitation_mailer.rb |
| `goodwill.invitation_waiting_for_phone` | core_event | account | core_notification_types | bell (parallel); push (parallel); email (parallel) | legacy_unmigrated | engine:app/events/decidim/bih/goodwill/launch_invitation_waiting_for_phone_event.rb; engine:app/jobs/decidim/bih/goodwill/launch_invitation_delivery_job.rb |
| `goodwill.points_earned` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/goodwill/ledger.rb; engine:app/events/decidim/bih/goodwill/points_earned_event.rb |
| `goodwill.daily_cap_reached` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/goodwill/earning_rules.rb |
| `goodwill.referral_verified` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/goodwill/referrals.rb |
| `goodwill.reward_decision` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/admin/goodwill_notifier.rb; engine:lib/tasks/decidim_bih_goodwill.rake |
| `goodwill.match_request_decided` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/admin/goodwill_notifier.rb |
| `campaign.transactional_phone` | campaign | account | platform_news_topic | viber, whatsapp, messenger, instagram, email (single) | shadow | engine:lib/tasks/decidim_bih_launch_campaign.rake; engine:app/services/decidim/bih/launch/campaign_send.rb; engine:app/services/decidim/bih/launch/message_dispatcher.rb |
| `campaign.marketing_phone` | campaign | account | platform_news_topic | viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/services/decidim/bih/launch/message_dispatcher.rb; engine:app/services/decidim/bih/launch/campaign_recipients.rb |
| `campaign.letter_p11` | campaign | external_institution | none |  | legacy_unmigrated | engine:app/services/decidim/bih/launch/campaign_recipients.rb; engine:app/services/decidim/bih/launch/message_templates.rb |
| `report.reporter_status_email` | own_report_correspondence | anonymous_report_contact, account | report_contact_address | email (parallel) | legacy_unmigrated | engine:app/models/decidim/bih/report.rb; engine:app/mailers/decidim/bih/reporter_mailer.rb |
| `report.author_external_copy` | own_report_correspondence | account | report_updates_topic | viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/models/decidim/bih/report.rb; engine:app/services/decidim/bih/account_notifications.rb |
| `report.staff_alert` | case_operations | staff | none | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/jobs/decidim/bih/report_staff_alert_job.rb |
| `report.case_message_to_author` | own_report_correspondence | account | report_updates_topic | bell (parallel); push (parallel); viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/jobs/decidim/bih/report_case_message_job.rb; engine:app/services/decidim/bih/report_case_workflow.rb |
| `report.case_message_to_staff` | case_operations | staff | none | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/jobs/decidim/bih/report_case_message_job.rb |
| `report.case_deadline_reminder` | case_operations | staff | none | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/jobs/decidim/bih/report_case_reminder_job.rb |
| `report.city_reply` | case_operations | staff | none | bell (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/report_city_reply.rb; engine:app/services/decidim/bih/report_mailbox/process_message.rb |
| `report.sistem48_forward` | external_institution | external_institution | external_recipient_config | email (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/report_dispatching.rb; engine:app/mailers/decidim/bih/report_dispatch_mailer.rb; engine:app/services/decidim/bih/sistem48/forwarder.rb; engine:app/jobs/decidim/bih/report_case_forward_job.rb; engine:app/mailers/decidim/bih/sistem48/report_mailer.rb |
| `report.stale_digest_email` | operator_report | operator_mailbox | operator_recipient_config | email (parallel) | legacy_unmigrated | engine:lib/tasks/decidim_bih_reports.rake; engine:app/mailers/decidim/bih/reports/stale_digest_mailer.rb |
| `komsiluk.urgent_post` | optional_news | account | legacy_urgent_bell | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/komsiluk_post_notification_service.rb; engine:app/jobs/decidim/bih/komsiluk_post_notification_job.rb; engine:app/services/decidim/bih/komsiluk/urgent_notification_policy.rb |
| `komsiluk.area_broadcast` | optional_news | account | neighborhood_info_topic | bell (parallel); push (parallel); viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/services/decidim/bih/komsiluk_broadcast.rb; engine:app/jobs/decidim/bih/broadcast_notification_job.rb; engine:app/controllers/decidim/bih/admin/broadcasts_controller.rb |
| `city.service_alert_viber` | optional_news | account | city_service_alerts_topic | viber, whatsapp, messenger, instagram, email (single) | shadow | host:app/jobs/decidim_app/bijeljina/city_service_alert_notification_job.rb; host:app/services/decidim_app/bijeljina/city_service_event_publisher.rb |
| `operator.direct_message` | operator_report | account | community_news_topic | bell (parallel); push (parallel); viber, whatsapp, messenger, instagram, email (single) | shadow | engine:app/services/decidim/bih/operator_messenger.rb; engine:app/controllers/decidim/bih/admin/operator_messages_controller.rb |
| `operator.role_expiry_warning` | operator_report | staff | none | bell (parallel); email (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/operator_role_expiry_notifier.rb; engine:app/mailers/decidim/bih/operator_role_expiry_mailer.rb |
| `ops.analytics_digest` | operator_report | operator_mailbox | operator_recipient_config | email (parallel) | legacy_unmigrated | engine:lib/tasks/decidim_bih_analytics.rake; engine:app/mailers/decidim/bih/admin/analytics_digest_mailer.rb |
| `ops.engine_health_alert` | operator_report | operator_mailbox | operator_recipient_config | email (parallel) | legacy_unmigrated | engine:lib/tasks/decidim_bih_operations.rake; engine:app/mailers/decidim/bih/admin/ops_health_alert_mailer.rb |
| `ops.host_standalone_alert` | operator_report | operator_mailbox | operator_recipient_config | email (parallel) | legacy_unmigrated | host:script/lib/mi_ops_notify.rb; host:script/lib/mi_health_notifications.rb; host:bin/ops-health-alert.sh |
| `volunteer.decision` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/volunteer_notifications.rb; engine:app/controllers/decidim/bih/volunteer_controller.rb |
| `partner.membership_invitation` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/partner_membership_notifications.rb |
| `community.contribution_decision` | core_event | account | core_notification_types | bell (parallel); push (parallel) | legacy_unmigrated | engine:app/services/decidim/bih/community_contribution_notifications.rb; engine:app/services/decidim/bih/approve_partner_project_submission.rb; engine:app/services/decidim/bih/create_contribution_offer.rb; engine:app/services/decidim/bih/manage_contribution_offer.rb |
| `core.welcome` | core_event | account | core_notification_types | bell (parallel); push (parallel); email (parallel) | legacy_unmigrated | engine:app/overrides/decidim/authorization_referral_override.rb; core:app/events/decidim/welcome_notification_event.rb |
| `core.event_bell` | core_event | account, staff | core_notification_types | bell (parallel) | legacy_unmigrated | core:app/services/decidim/events_manager.rb; core:app/services/decidim/notification_generator.rb |
| `core.event_email` | core_event | account, staff | core_email_frequency | email (parallel) | legacy_unmigrated | core:app/services/decidim/email_notification_generator.rb; core:app/mailers/decidim/notification_mailer.rb |
| `core.digest_email` | core_event | account, staff | core_email_frequency | email (parallel) | legacy_unmigrated | core:lib/tasks/decidim_mailers_tasks.rake; core:app/mailers/decidim/notifications_digest_mailer.rb |
| `core.newsletter_email` | optional_news | account | core_newsletter | email (parallel) | legacy_unmigrated | decidim-admin:app/commands/decidim/admin/deliver_newsletter.rb; decidim-admin:app/queries/decidim/admin/newsletter_recipients.rb; core:app/mailers/decidim/newsletter_mailer.rb |
| `core.conversation_email` | conversation | account | core_direct_message | email (parallel) | legacy_unmigrated | core:app/commands/decidim/messaging/start_conversation.rb; core:app/mailers/decidim/messaging/conversation_mailer.rb |
| `core.conversation_push` | conversation | account | device_subscription | push (parallel) | legacy_unmigrated | core:app/commands/decidim/messaging/reply_to_conversation.rb; engine:app/services/decidim/bih/web_push.rb |
| `core.devise_transactional` | core_transactional | account | core_transactional | email (parallel) | legacy_unmigrated | core:app/mailers/decidim/decidim_devise_mailer.rb; engine:app/overrides/decidim/passwords_email_confirmed_guard_override.rb |
| `core.account_lifecycle` | core_transactional | account | core_transactional | email (parallel) | legacy_unmigrated | core:app/mailers/decidim/block_user_mailer.rb; core:app/mailers/decidim/delete_user_mailer.rb; core:app/mailers/decidim/user_update_mailer.rb; core:app/mailers/decidim/participants_account_mailer.rb |
| `core.moderation_email` | core_transactional | staff | core_moderation_email | email (parallel) | legacy_unmigrated | core:app/mailers/decidim/reported_mailer.rb; core:app/mailers/decidim/user_report_mailer.rb |
| `core.export_email` | core_transactional | account, staff | core_transactional | email (parallel) | legacy_unmigrated | core:app/mailers/decidim/export_mailer.rb; core:app/jobs/decidim/download_your_data_export_job.rb |
| `push.bell_fanout` | core_event | account, staff | device_subscription | push (parallel) | legacy_unmigrated | core:app/jobs/decidim/notification_generator_for_recipient_job.rb; engine:app/overrides/decidim/web_push_override.rb; engine:app/jobs/decidim/bih/web_push_delivery_job.rb |
| `chat.web_reply` | reactive_chat | provider_inbound_identity, account | channel_session | web_chat (single) | legacy_unmigrated | host:app/services/decidim_app/bijeljina/web_concierge.rb; engine:app/controllers/decidim/bih/concierge/web_chat_controller.rb |
| `chat.external_reply` | reactive_chat | provider_inbound_identity | channel_session | viber, whatsapp, messenger, instagram (single) | legacy_unmigrated | host:app/jobs/decidim_app/infobip/process_inbound_delivery_job.rb; host:app/services/decidim_app/bijeljina/external_chat_concierge.rb; engine:app/jobs/decidim/bih/infobip/send_chat_text_job.rb |
| `channel.connection_challenge` | account_lifecycle | provider_inbound_identity | channel_session | whatsapp, messenger, instagram (single) | legacy_unmigrated | engine:app/services/decidim/bih/channel_connections.rb |
| `channel.opt_out_reply` | reactive_chat | provider_inbound_identity | channel_session | viber, whatsapp, messenger, instagram (single) | legacy_unmigrated | host:app/services/decidim_app/bijeljina/channel_notification_opt_out.rb; engine:app/services/decidim/bih/notification_preferences.rb |
| `postal.verification_letter` | account_lifecycle | account | none | postal (single) | legacy_unmigrated | engine:app/overrides/decidim/postal_postages_controller_override.rb; engine:app/services/decidim/bih/postal/postal_token_service.rb |

## Površine koje ne šalju poruke

| Granica | Značenje |
|---|---|
| `boundary.public_pages` | Javne stranice i table prikazuju sadržaj posjetiocu. |
| `boundary.venue_screen` | Javni ekran prikazuje sadržaj bez liste primalaca. |
| `boundary.referral_share` | Dijeljenje otvara korisnikovu aplikaciju; korisnik šalje poruku. |
| `boundary.printed_qr` | QR kod ili plakat se priprema za štampu. |
| `boundary.postal_posting` | Štampanje ili označavanje pisma ne potvrđuje predaju ni prijem. |
| `boundary.support_mailbox` | Klik na kontakt otvara spoljnu aplikaciju. |
| `boundary.odoo_campaigns` | Publika i slanje kampanja vode se u zasebnom Odoo sistemu. |
| `boundary.browser_consent` | Saglasnost za skripte u browseru nije izbor kanala poruka. |
| `boundary.page_nudges` | Baner i ponuda instalacije ili push-a prikazuju se na stranici. |
| `boundary.admin_read_screens` | Administratorski pregled prikazuje sačuvano stanje. |

Pri izmjeni registra ažurirajte ovaj pregled komandom `bundle exec ruby script/message_producer_map --write`. Provjera bez upisa je `bundle exec ruby script/message_producer_map --check`.

Za stvarnu isporuku svaka instalacija podešava svoje naloge, primaoce, dozvole, odjave i kanale. Uspješan scheduler, red za slanje ili prihvatanje od pružaoca nisu dokaz prijema ili čitanja poruke.
