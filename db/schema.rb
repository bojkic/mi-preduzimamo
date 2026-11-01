# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_01_130700) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "ltree"
  enable_extension "pg_trgm"
  enable_extension "plpgsql"

  create_table "active_hashcash_stamps", force: :cascade do |t|
    t.string "version", null: false
    t.integer "bits", null: false
    t.date "date", null: false
    t.string "resource", null: false
    t.string "ext", null: false
    t.string "rand", null: false
    t.string "counter", null: false
    t.string "request_path"
    t.string "ip_address"
    t.jsonb "context"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["counter", "rand", "date", "resource", "bits", "version", "ext"], name: "index_active_hashcash_stamps_unique", unique: true
    t.index ["ip_address", "created_at"], name: "index_active_hashcash_stamps_on_ip_address_and_created_at", where: "(ip_address IS NOT NULL)"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", precision: nil, null: false
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "city_service_source_snapshots", force: :cascade do |t|
    t.string "source_key", null: false
    t.string "source_version", null: false
    t.jsonb "check_payload", default: {}, null: false
    t.jsonb "last_good_payload", default: {}, null: false
    t.datetime "attempted_at"
    t.datetime "last_success_at"
    t.string "content_hash"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source_key"], name: "index_city_service_source_snapshots_on_source_key", unique: true
  end

  create_table "decidim_accountability_milestones", id: :serial, force: :cascade do |t|
    t.date "entry_date"
    t.jsonb "description"
    t.integer "decidim_accountability_result_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "title"
    t.index ["decidim_accountability_result_id"], name: "index_decidim_accountability_milestones_on_results_id"
    t.index ["entry_date"], name: "index_decidim_accountability_milestones_on_entry_date"
  end

  create_table "decidim_accountability_results", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.string "reference"
    t.date "start_date"
    t.date "end_date"
    t.decimal "progress", precision: 5, scale: 2
    t.integer "parent_id"
    t.integer "decidim_accountability_status_id"
    t.integer "decidim_component_id"
    t.integer "decidim_scope_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "children_count", default: 0
    t.float "weight", default: 1.0
    t.string "external_id"
    t.integer "comments_count", default: 0, null: false
    t.datetime "deleted_at"
    t.text "address"
    t.float "latitude"
    t.float "longitude"
    t.index ["decidim_accountability_status_id"], name: "decidim_accountability_results_on_status_id"
    t.index ["decidim_component_id"], name: "index_decidim_accountability_results_on_decidim_component_id"
    t.index ["decidim_scope_id"], name: "index_decidim_accountability_results_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_accountability_results_on_deleted_at"
    t.index ["external_id"], name: "index_decidim_accountability_results_on_external_id"
    t.index ["parent_id"], name: "decidim_accountability_results_on_parent_id"
  end

  create_table "decidim_accountability_statuses", id: :serial, force: :cascade do |t|
    t.string "key"
    t.jsonb "name"
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "description"
    t.integer "progress"
    t.index ["decidim_component_id"], name: "index_decidim_accountability_statuses_on_decidim_component_id"
  end

  create_table "decidim_action_logs", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "user_id", null: false
    t.bigint "decidim_component_id"
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.string "participatory_space_type"
    t.bigint "participatory_space_id"
    t.string "action", null: false
    t.jsonb "extra"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "version_id"
    t.string "visibility", default: "admin-only"
    t.integer "decidim_scope_id"
    t.integer "decidim_area_id"
    t.string "user_type", default: "Decidim::User", null: false
    t.index ["created_at"], name: "index_decidim_action_logs_on_created_at"
    t.index ["decidim_area_id"], name: "index_decidim_action_logs_on_decidim_area_id"
    t.index ["decidim_component_id"], name: "index_action_logs_on_component_id"
    t.index ["decidim_organization_id"], name: "index_action_logs_on_organization_id"
    t.index ["decidim_scope_id"], name: "index_decidim_action_logs_on_decidim_scope_id"
    t.index ["participatory_space_type", "participatory_space_id"], name: "index_action_logs_on_space_type_and_id"
    t.index ["resource_type", "resource_id"], name: "index_action_logs_on_resource_type_and_id"
    t.index ["user_id", "user_type"], name: "index_decidim_action_log_on_users"
    t.index ["user_id"], name: "index_action_logs_on_user_id"
    t.index ["version_id"], name: "index_decidim_action_logs_on_version_id"
    t.index ["visibility"], name: "index_decidim_action_logs_on_visibility"
  end

  create_table "decidim_amendments", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.string "decidim_amendable_type"
    t.bigint "decidim_amendable_id"
    t.string "decidim_emendation_type"
    t.bigint "decidim_emendation_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "state", default: 0, null: false
    t.index ["decidim_amendable_id", "decidim_amendable_type"], name: "index_on_amendable"
    t.index ["decidim_emendation_id"], name: "index_decidim_amendments_on_decidim_emendation_id"
    t.index ["decidim_user_id", "decidim_amendable_id", "decidim_amendable_type"], name: "index_on_amender_and_amendable"
    t.index ["decidim_user_id"], name: "index_decidim_amendments_on_decidim_user_id"
  end

  create_table "decidim_api_jwt_denylists", force: :cascade do |t|
    t.string "jti", null: false
    t.datetime "exp", null: false
    t.index ["jti"], name: "index_decidim_api_jwt_denylists_on_jti"
  end

  create_table "decidim_app_city_service_automation_decisions", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.string "policy_version", null: false
    t.string "content_version", null: false
    t.string "mode", null: false
    t.string "outcome", null: false
    t.string "publication_revision"
    t.datetime "checked_at"
    t.bigint "checked_by_id"
    t.string "check_result"
    t.string "checked_publication_revision"
    t.string "checked_policy_version"
    t.string "checked_evidence_digest"
    t.jsonb "blockers", default: [], null: false
    t.jsonb "target_slugs", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["checked_by_id"], name: "idx_city_auto_checked_by"
    t.index ["event_id", "policy_version", "content_version"], name: "idx_city_automation_decision", unique: true
    t.index ["event_id"], name: "idx_on_event_id_cf525971a6"
    t.check_constraint "checked_at IS NULL AND checked_by_id IS NULL AND check_result IS NULL AND checked_publication_revision IS NULL AND checked_policy_version IS NULL AND checked_evidence_digest IS NULL OR checked_at IS NOT NULL AND checked_by_id IS NOT NULL AND (check_result::text = ANY (ARRAY['ok'::character varying, 'corrected'::character varying, 'withdrawn'::character varying]::text[])) AND checked_publication_revision IS NOT NULL AND checked_policy_version IS NOT NULL AND checked_evidence_digest IS NOT NULL", name: "city_automation_check_complete"
  end

  create_table "decidim_app_city_service_coverages", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "identity_key", null: false
    t.string "source_key", null: false
    t.string "targeting_level", null: false
    t.jsonb "area_slugs", default: [], null: false
    t.jsonb "evidence", default: {}, null: false
    t.bigint "reviewer_id", null: false
    t.bigint "event_id", null: false
    t.date "valid_until", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "identity_key"], name: "idx_city_coverage_identity", unique: true
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_75d2622751"
    t.index ["event_id"], name: "index_decidim_app_city_service_coverages_on_event_id"
    t.index ["reviewer_id"], name: "index_decidim_app_city_service_coverages_on_reviewer_id"
  end

  create_table "decidim_app_city_service_duplicate_decisions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "event_id", null: false
    t.bigint "other_event_id", null: false
    t.string "decision", null: false
    t.bigint "reviewer_id", null: false
    t.jsonb "previous_memberships", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_6581fa5047"
    t.index ["event_id", "other_event_id"], name: "idx_city_duplicate_pair", unique: true
    t.index ["reviewer_id"], name: "idx_on_reviewer_id_a571b53f81"
  end

  create_table "decidim_app_city_service_effects", force: :cascade do |t|
    t.bigint "event_id", null: false
    t.string "identity", null: false
    t.string "kind", null: false
    t.jsonb "payload", default: {}, null: false
    t.datetime "completed_at"
    t.datetime "last_attempt_at"
    t.integer "attempts", default: 0, null: false
    t.string "error_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_at", "id"], name: "idx_city_effect_pending"
    t.index ["event_id"], name: "index_decidim_app_city_service_effects_on_event_id"
    t.index ["identity"], name: "index_decidim_app_city_service_effects_on_identity", unique: true
  end

  create_table "decidim_app_city_service_entries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "key", null: false
    t.string "title", null: false
    t.text "body", null: false
    t.string "source_url", null: false
    t.date "source_checked_on"
    t.string "reviewed_content_hash"
    t.string "state", default: "draft", null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "idx_app_city_service_entries_approved_by"
    t.index ["decidim_organization_id", "key"], name: "idx_app_city_service_entries_org_key", unique: true
    t.index ["decidim_organization_id"], name: "idx_app_city_service_entries_org"
  end

  create_table "decidim_app_city_service_events", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "reviewed_by_id"
    t.string "source_key", null: false
    t.string "source_label"
    t.string "provider"
    t.string "source_url"
    t.string "source_fingerprint", null: false
    t.datetime "fetched_at"
    t.string "parser_version", default: "unknown", null: false
    t.string "event_type", null: false
    t.string "severity", null: false
    t.string "targeting_level", default: "unknown", null: false
    t.jsonb "affected_area_slugs", default: [], null: false
    t.jsonb "target_komsiluk_slugs", default: [], null: false
    t.string "title", null: false
    t.text "summary", null: false
    t.text "affected_text"
    t.text "recommended_action"
    t.text "viber_text"
    t.datetime "starts_at"
    t.datetime "ends_at"
    t.decimal "confidence", precision: 5, scale: 4, default: "0.0", null: false
    t.string "state", default: "pending_review", null: false
    t.datetime "reviewed_at"
    t.datetime "published_at"
    t.datetime "dismissed_at"
    t.text "review_note"
    t.jsonb "classifier_reasons", default: [], null: false
    t.jsonb "komsiluk_post_ids", default: [], null: false
    t.string "viber_dedupe_key"
    t.string "viber_delivery"
    t.integer "viber_jobs_count", default: 0, null: false
    t.integer "viber_recipients_count", default: 0, null: false
    t.jsonb "policy_snapshot", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source_occurrence_id"
    t.string "content_version"
    t.datetime "source_published_at"
    t.datetime "source_updated_at"
    t.jsonb "extraction_metadata", default: {}, null: false
    t.string "lifecycle", default: "scheduled", null: false
    t.string "reviewed_content_version"
    t.bigint "superseded_by_id"
    t.bigint "incident_id"
    t.index ["decidim_organization_id", "source_key", "source_fingerprint"], name: "idx_app_city_events_org_source_fingerprint", unique: true
    t.index ["decidim_organization_id", "source_key", "source_occurrence_id"], name: "idx_city_events_occurrence"
    t.index ["decidim_organization_id", "source_key", "state"], name: "idx_app_city_events_org_source_state"
    t.index ["decidim_organization_id", "state", "starts_at"], name: "idx_app_city_events_org_state_starts"
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_3dd2e52663"
    t.index ["incident_id"], name: "index_decidim_app_city_service_events_on_incident_id"
    t.index ["reviewed_by_id"], name: "index_decidim_app_city_service_events_on_reviewed_by_id"
    t.index ["superseded_by_id"], name: "index_decidim_app_city_service_events_on_superseded_by_id"
  end

  create_table "decidim_app_city_service_incidents", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "identity_key", null: false
    t.string "service", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "identity_key"], name: "idx_city_incident_identity", unique: true
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_718cc518a0"
  end

  create_table "decidim_app_city_service_projections", force: :cascade do |t|
    t.bigint "incident_id", null: false
    t.bigint "komsiluk_id", null: false
    t.bigint "post_id", null: false
    t.string "revision", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["incident_id", "komsiluk_id"], name: "idx_city_incident_board", unique: true
    t.index ["incident_id"], name: "index_decidim_app_city_service_projections_on_incident_id"
    t.index ["komsiluk_id"], name: "index_decidim_app_city_service_projections_on_komsiluk_id"
    t.index ["post_id"], name: "index_decidim_app_city_service_projections_on_post_id"
  end

  create_table "decidim_app_foundation_status_overrides", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "current_open_status", default: "unverified", null: false
    t.date "reviewed_on"
    t.date "review_expires_on"
    t.string "state", default: "draft", null: false
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "idx_app_foundation_status_overrides_approved_by"
    t.index ["decidim_organization_id"], name: "idx_app_foundation_status_overrides_org", unique: true
  end

  create_table "decidim_app_launch_event_deliveries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "actor_id"
    t.string "event_key", null: false
    t.string "message_key", null: false
    t.boolean "test_message", default: false, null: false
    t.string "status", default: "pending", null: false
    t.string "token_digest"
    t.string "phone_digest"
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "attempted_at"
    t.jsonb "provider_message_ids", default: [], null: false
    t.string "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "event_key", "message_key", "test_message"], name: "idx_launch_event_delivery_once", unique: true
    t.index ["token_digest"], name: "index_decidim_app_launch_event_deliveries_on_token_digest", unique: true
  end

  create_table "decidim_app_launch_event_votes", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "event_key", null: false
    t.string "choice", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "event_key"], name: "idx_launch_event_one_vote", unique: true
  end

  create_table "decidim_app_parking_zone_streets", force: :cascade do |t|
    t.string "street_name", null: false
    t.string "normalized_street_name", null: false
    t.jsonb "aliases", default: [], null: false
    t.string "zone", null: false
    t.text "segment_note"
    t.string "source_url", null: false
    t.string "source_map_url", null: false
    t.date "source_checked_on", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "idx_app_parking_zone_streets_active"
    t.index ["normalized_street_name"], name: "idx_app_parking_zone_streets_normalized", unique: true
    t.index ["zone"], name: "idx_app_parking_zone_streets_zone"
  end

  create_table "decidim_area_types", force: :cascade do |t|
    t.bigint "decidim_organization_id"
    t.jsonb "name", null: false
    t.jsonb "plural", null: false
    t.index ["decidim_organization_id"], name: "index_decidim_area_types_on_decidim_organization_id"
  end

  create_table "decidim_areas", force: :cascade do |t|
    t.jsonb "name"
    t.bigint "area_type_id"
    t.bigint "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["area_type_id"], name: "index_decidim_areas_on_area_type_id"
    t.index ["decidim_organization_id"], name: "index_decidim_areas_on_decidim_organization_id"
  end

  create_table "decidim_assemblies", id: :serial, force: :cascade do |t|
    t.string "slug", null: false
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "title", null: false
    t.jsonb "subtitle", null: false
    t.jsonb "short_description", null: false
    t.jsonb "description", null: false
    t.boolean "promoted", default: false
    t.datetime "published_at", precision: nil
    t.jsonb "developer_group"
    t.jsonb "meta_scope"
    t.jsonb "local_area"
    t.jsonb "target"
    t.jsonb "participatory_scope"
    t.jsonb "participatory_structure"
    t.integer "decidim_scope_id"
    t.boolean "scopes_enabled", default: true, null: false
    t.boolean "private_space", default: false
    t.string "reference"
    t.bigint "decidim_area_id"
    t.bigint "parent_id"
    t.ltree "parents_path"
    t.integer "children_count", default: 0
    t.jsonb "purpose_of_action"
    t.jsonb "composition"
    t.date "creation_date"
    t.string "created_by"
    t.jsonb "created_by_other"
    t.date "duration"
    t.date "included_at"
    t.date "closing_date"
    t.jsonb "closing_date_reason"
    t.jsonb "internal_organisation"
    t.boolean "is_transparent", default: true
    t.jsonb "special_features"
    t.string "twitter_handler"
    t.string "instagram_handler"
    t.string "facebook_handler"
    t.string "youtube_handler"
    t.string "github_handler"
    t.integer "weight", default: 1, null: false
    t.integer "follows_count", default: 0, null: false
    t.jsonb "announcement"
    t.datetime "deleted_at"
    t.boolean "has_members", default: false
    t.integer "access_mode", default: 0, null: false
    t.index ["decidim_area_id"], name: "index_decidim_assemblies_on_decidim_area_id"
    t.index ["decidim_organization_id", "slug"], name: "index_unique_assembly_slug_and_organization", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_assemblies_on_decidim_organization_id"
    t.index ["decidim_scope_id"], name: "index_decidim_assemblies_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_assemblies_on_deleted_at"
    t.index ["parent_id"], name: "decidim_assemblies_assemblies_on_parent_id"
  end

  create_table "decidim_assemblies_settings", force: :cascade do |t|
    t.boolean "enable_organization_chart", default: true
    t.bigint "decidim_organization_id"
    t.index ["decidim_organization_id"], name: "index_decidim_assemblies_settings_on_decidim_organization_id"
  end

  create_table "decidim_assembly_members", force: :cascade do |t|
    t.bigint "decidim_assembly_id"
    t.integer "weight", default: 0, null: false
    t.string "full_name"
    t.string "gender"
    t.date "birthday"
    t.string "birthplace"
    t.date "designation_date"
    t.string "position"
    t.string "position_other"
    t.date "ceased_date"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "decidim_user_id"
    t.index ["decidim_assembly_id"], name: "index_decidim_assembly_members_on_decidim_assembly_id"
    t.index ["decidim_user_id"], name: "index_decidim_assembly_members_on_decidim_user_id"
    t.index ["weight", "created_at"], name: "index_decidim_assembly_members_on_weight_and_created_at"
  end

  create_table "decidim_assembly_user_roles", force: :cascade do |t|
    t.integer "decidim_user_id"
    t.integer "decidim_assembly_id"
    t.string "role"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_assembly_id", "decidim_user_id", "role"], name: "index_unique_user_and_assembly_role", unique: true
    t.index ["decidim_user_id"], name: "index_decidim_assembly_user_roles_on_decidim_user_id"
  end

  create_table "decidim_attachment_collections", force: :cascade do |t|
    t.jsonb "name", null: false
    t.jsonb "description", null: false
    t.integer "weight", default: 0, null: false
    t.string "collection_for_type", null: false
    t.bigint "collection_for_id", null: false
    t.index ["collection_for_type", "collection_for_id"], name: "decidim_attachment_collections_collection_for_id_and_type"
  end

  create_table "decidim_attachments", id: :serial, force: :cascade do |t|
    t.jsonb "title", null: false
    t.jsonb "description"
    t.string "content_type", null: false
    t.string "file_size", null: false
    t.integer "attached_to_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "attached_to_type", null: false
    t.integer "weight", default: 0, null: false
    t.integer "attachment_collection_id"
    t.string "link"
    t.index ["attached_to_id", "attached_to_type"], name: "index_decidim_attachments_on_attached_to"
    t.index ["attachment_collection_id"], name: "index_decidim_attachments_on_attachment_collection_id"
  end

  create_table "decidim_authorization_transfer_records", force: :cascade do |t|
    t.bigint "transfer_id", null: false
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["resource_type", "resource_id"], name: "index_decidim_authorization_transfer_records_on_resource"
    t.index ["transfer_id"], name: "index_decidim_authorization_transfer_records_on_transfer_id"
  end

  create_table "decidim_authorization_transfers", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "source_user_id", null: false
    t.bigint "authorization_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.index ["authorization_id"], name: "index_decidim_authorization_transfers_on_authorization_id"
    t.index ["source_user_id"], name: "index_decidim_authorization_transfers_on_source_user_id"
    t.index ["user_id"], name: "index_decidim_authorization_transfers_on_user_id"
  end

  create_table "decidim_authorizations", id: :serial, force: :cascade do |t|
    t.string "name", null: false
    t.jsonb "metadata"
    t.integer "decidim_user_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "unique_id"
    t.datetime "granted_at", precision: nil
    t.jsonb "verification_metadata", default: {}
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.index ["decidim_user_id", "name"], name: "index_decidim_authorizations_on_decidim_user_id_and_name", unique: true
    t.index ["decidim_user_id"], name: "index_decidim_authorizations_on_decidim_user_id"
    t.index ["unique_id"], name: "index_decidim_authorizations_on_unique_id"
  end

  create_table "decidim_awesome_authorization_groups", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.jsonb "name", default: {}, null: false
    t.jsonb "purpose", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "decidim_awesome_authorization_groups_organization_id"
  end

  create_table "decidim_awesome_authorization_members", force: :cascade do |t|
    t.string "email", null: false
    t.bigint "authorization_group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["authorization_group_id", "email"], name: "index_auth_members_group_email", unique: true
    t.index ["authorization_group_id"], name: "decidim_awesome_authorization_members_authorization_group_id"
  end

  create_table "decidim_awesome_config", force: :cascade do |t|
    t.string "var"
    t.jsonb "value"
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_organization_id"], name: "index_decidim_awesome_on_decidim_organization_id"
    t.index ["var", "decidim_organization_id"], name: "index_decidim_awesome_organization_var", unique: true
  end

  create_table "decidim_awesome_config_constraints", force: :cascade do |t|
    t.jsonb "settings"
    t.bigint "decidim_awesome_config_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_awesome_config_id"], name: "decidim_awesome_config_constraints_config"
    t.index ["settings", "decidim_awesome_config_id"], name: "index_decidim_awesome_settings_awesome_config", unique: true
  end

  create_table "decidim_awesome_editor_images", force: :cascade do |t|
    t.string "image"
    t.string "path"
    t.bigint "decidim_author_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_author_id"], name: "decidim_awesome_editor_images_author"
    t.index ["decidim_organization_id"], name: "decidim_awesome_editor_images_constraint_organization"
  end

  create_table "decidim_awesome_follow_up_questionnaire_messages", force: :cascade do |t|
    t.bigint "follow_up_questionnaire_id", null: false
    t.bigint "decidim_user_id"
    t.string "session_token"
    t.bigint "status_id", null: false
    t.text "body"
    t.string "author_type", null: false
    t.bigint "author_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_type", "author_id"], name: "index_fuqm_on_author"
    t.index ["decidim_user_id"], name: "index_fuqm_on_decidim_user_id"
    t.index ["follow_up_questionnaire_id", "decidim_user_id", "session_token", "created_at"], name: "index_fuqm_on_respondent_created_at"
    t.index ["follow_up_questionnaire_id"], name: "index_fuqm_on_follow_up_questionnaire_id"
    t.index ["session_token"], name: "index_fuqm_on_session_token"
    t.index ["status_id"], name: "index_fuqm_on_status_id"
  end

  create_table "decidim_awesome_follow_up_questionnaire_statuses", force: :cascade do |t|
    t.bigint "follow_up_questionnaire_id", null: false
    t.jsonb "name", default: {}, null: false
    t.string "color", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["follow_up_questionnaire_id"], name: "index_fuqs_on_follow_up_questionnaire_id"
  end

  create_table "decidim_awesome_follow_up_questionnaires", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_component_id", null: false
    t.bigint "decidim_questionnaire_id", null: false
    t.jsonb "name", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.string "responder_name_field"
    t.string "responder_email_field"
    t.string "reply_to"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "settings", default: {}, null: false
    t.index ["active", "position"], name: "index_decidim_awesome_fuq_on_active_position"
    t.index ["decidim_component_id"], name: "index_decidim_awesome_fuq_on_component_id"
    t.index ["decidim_organization_id"], name: "index_decidim_awesome_fuq_on_organization_id"
    t.index ["decidim_questionnaire_id"], name: "index_decidim_awesome_fuq_on_questionnaire_id", unique: true
  end

  create_table "decidim_awesome_proposal_extra_fields", force: :cascade do |t|
    t.bigint "decidim_proposal_id", null: false
    t.jsonb "vote_weight_totals"
    t.integer "weight_total", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "private_body"
    t.string "decidim_proposal_type", null: false
    t.datetime "private_body_updated_at", precision: nil
    t.datetime "deleted_at"
    t.index ["decidim_proposal_id", "decidim_proposal_type"], name: "index_decidim_awesome_proposal_extra_fields_on_decidim_proposal"
    t.index ["deleted_at"], name: "index_decidim_awesome_proposal_extra_fields_on_deleted_at"
  end

  create_table "decidim_awesome_vote_weights", force: :cascade do |t|
    t.bigint "proposal_vote_id", null: false
    t.integer "weight", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["proposal_vote_id"], name: "decidim_awesome_proposals_weights_vote"
  end

  create_table "decidim_bih_account_notifications", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "topic", null: false
    t.string "deduplication_digest", null: false
    t.text "payload_ciphertext", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "channels", default: [], null: false
    t.jsonb "provider_message_ids", default: [], null: false
    t.string "reason"
    t.datetime "expires_at", null: false
    t.datetime "attempted_at"
    t.datetime "delivered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "deduplication_digest"], name: "idx_bih_account_notifications_dedupe", unique: true
    t.index ["decidim_user_id", "created_at"], name: "idx_bih_account_notifications_user_time"
  end

  create_table "decidim_bih_broadcasts", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "local_area_id", null: false
    t.bigint "sent_by_id"
    t.text "message", null: false
    t.string "channels", default: "bell", null: false
    t.integer "recipients_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "created_at"], name: "idx_bih_broadcasts_on_org_and_created_at"
  end

  create_table "decidim_bih_case_usage_days", force: :cascade do |t|
    t.date "day", null: false
    t.decimal "reserved_usd", precision: 14, scale: 8, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["day"], name: "index_decidim_bih_case_usage_days_on_day", unique: true
    t.check_constraint "reserved_usd >= 0::numeric", name: "case_usage_nonnegative"
  end

  create_table "decidim_bih_channel_connection_challenges", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "channel", null: false
    t.string "business_sender", null: false
    t.string "token_digest", null: false
    t.integer "confirmation_attempts", default: 0, null: false
    t.string "confirmation_digest"
    t.text "recipient_ciphertext"
    t.datetime "last_inbound_at"
    t.datetime "expires_at", null: false
    t.datetime "proved_at"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "mi_challenge_org"
    t.index ["decidim_user_id"], name: "mi_challenge_user"
    t.index ["token_digest"], name: "mi_channel_challenge_token", unique: true
  end

  create_table "decidim_bih_channel_connections", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "channel", null: false
    t.string "business_sender", null: false
    t.string "recipient_digest", null: false
    t.text "recipient_ciphertext", null: false
    t.datetime "verified_at", null: false
    t.datetime "revoked_at"
    t.datetime "last_inbound_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "channel", "business_sender", "decidim_user_id"], name: "mi_channel_active_user", unique: true, where: "(revoked_at IS NULL)"
    t.index ["decidim_organization_id", "channel", "business_sender", "recipient_digest"], name: "mi_channel_active_recipient", unique: true, where: "(revoked_at IS NULL)"
    t.index ["decidim_organization_id"], name: "mi_connection_org"
    t.index ["decidim_user_id"], name: "mi_connection_user"
  end

  create_table "decidim_bih_citizen_phones", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.string "phone", null: false
    t.datetime "verified_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "idx_bih_citizen_phones_org"
    t.index ["decidim_user_id"], name: "idx_bih_citizen_phones_user", unique: true
  end

  create_table "decidim_bih_citizen_profiles", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.bigint "komsiluk_id"
    t.bigint "mz_id"
    t.string "source"
    t.datetime "assigned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id"], name: "idx_bih_citizen_profiles_on_org_and_user", unique: true
    t.index ["decidim_organization_id", "komsiluk_id"], name: "idx_bih_citizen_profiles_on_org_and_komsiluk"
    t.index ["decidim_organization_id", "mz_id"], name: "idx_bih_citizen_profiles_on_org_and_mz"
  end

  create_table "decidim_bih_concierge_feedbacks", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "reply_id", null: false
    t.string "session_digest", null: false
    t.string "value", null: false
    t.string "locale"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "citizen_message"
    t.text "bot_reply_text"
    t.index ["decidim_organization_id", "created_at"], name: "idx_bih_concierge_feedbacks_org_created"
    t.index ["decidim_organization_id", "reply_id", "session_digest"], name: "idx_bih_concierge_feedbacks_once", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_concierge_feedbacks_org"
    t.index ["decidim_user_id"], name: "idx_bih_concierge_feedbacks_user"
    t.check_constraint "value::text = ANY (ARRAY['helpful'::character varying::text, 'not_helpful'::character varying::text, 'share_question'::character varying::text])", name: "chk_bih_concierge_feedback_value"
  end

  create_table "decidim_bih_concierge_metric_rollups", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.date "day", null: false
    t.string "kind", null: false
    t.string "topic", null: false
    t.string "label", null: false
    t.bigint "count", default: 0, null: false
    t.string "latency_bucket"
    t.string "release_sha", limit: 40
    t.integer "prompt_version"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "facet", default: "unknown", null: false
    t.string "traffic_kind", default: "unclassified", null: false
    t.index ["decidim_organization_id", "day", "kind", "topic", "label", "latency_bucket", "facet", "traffic_kind", "release_sha", "prompt_version"], name: "idx_bih_concierge_metric_detail_unique", unique: true, where: "((kind)::text = 'answer_detail'::text)", nulls_not_distinct: true
    t.index ["decidim_organization_id", "day", "kind", "topic", "label", "latency_bucket"], name: "idx_bih_concierge_metric_rollups_unique", unique: true, where: "((kind)::text <> 'answer_detail'::text)", nulls_not_distinct: true
    t.index ["decidim_organization_id", "day"], name: "idx_bih_concierge_metric_rollups_org_day"
    t.check_constraint "count >= 0", name: "chk_bih_concierge_metric_rollups_count"
  end

  create_table "decidim_bih_concierge_usage_aggregates", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.date "bucket_on", null: false
    t.string "channel", null: false
    t.string "outcome", null: false
    t.string "answer_intent", default: "unknown", null: false
    t.string "locale", default: "sr", null: false
    t.bigint "requests_count", default: 0, null: false
    t.bigint "message_length_total", default: 0, null: false
    t.bigint "reply_length_total", default: 0, null: false
    t.bigint "quick_replies_total", default: 0, null: false
    t.bigint "sticker_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "resolution_answered_count", default: 0, null: false
    t.bigint "resolution_clarification_count", default: 0, null: false
    t.bigint "resolution_handoff_count", default: 0, null: false
    t.bigint "resolution_draft_count", default: 0, null: false
    t.bigint "resolution_submitted_count", default: 0, null: false
    t.bigint "resolution_cancelled_count", default: 0, null: false
    t.bigint "resolution_unsupported_count", default: 0, null: false
    t.bigint "resolution_source_unavailable_count", default: 0, null: false
    t.bigint "resolution_delivery_failed_count", default: 0, null: false
    t.bigint "handoff_offered_count", default: 0, null: false
    t.bigint "handoff_completed_count", default: 0, null: false
    t.bigint "grounded_answer_count", default: 0, null: false
    t.bigint "action_receipt_count", default: 0, null: false
    t.bigint "resolution_safety_guidance_count", default: 0, null: false
    t.index ["decidim_organization_id", "bucket_on", "channel", "outcome", "answer_intent", "locale"], name: "idx_bih_concierge_usage_unique", unique: true
    t.index ["decidim_organization_id", "bucket_on"], name: "idx_bih_concierge_usage_org_day"
    t.index ["decidim_organization_id"], name: "idx_bih_concierge_usage_org"
    t.check_constraint "requests_count >= 0 AND message_length_total >= 0 AND reply_length_total >= 0 AND quick_replies_total >= 0 AND sticker_count >= 0", name: "chk_bih_concierge_usage_counts"
    t.check_constraint "resolution_answered_count >= 0 AND resolution_clarification_count >= 0 AND resolution_handoff_count >= 0 AND resolution_draft_count >= 0 AND resolution_submitted_count >= 0 AND resolution_cancelled_count >= 0 AND resolution_unsupported_count >= 0 AND resolution_source_unavailable_count >= 0 AND resolution_delivery_failed_count >= 0 AND handoff_offered_count >= 0 AND handoff_completed_count >= 0 AND grounded_answer_count >= 0 AND action_receipt_count >= 0", name: "chk_bih_concierge_dialogue_counts"
    t.check_constraint "resolution_safety_guidance_count >= 0", name: "chk_bih_concierge_safety_guidance_count"
  end

  create_table "decidim_bih_contribution_needs", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "partner_profile_id", null: false
    t.bigint "decidim_author_id"
    t.bigint "reviewed_by_id"
    t.bigint "decidim_budgets_project_id"
    t.string "need_type", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.decimal "quantity", precision: 12, scale: 2, null: false
    t.string "unit", null: false
    t.date "needed_by"
    t.string "location"
    t.string "review_status", default: "pending", null: false
    t.string "fulfillment_status", default: "open", null: false
    t.datetime "reviewed_at"
    t.datetime "published_at"
    t.datetime "closed_at"
    t.text "rejection_reason"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_author_id"], name: "idx_bih_contribution_needs_author"
    t.index ["decidim_budgets_project_id"], name: "idx_bih_contribution_needs_project"
    t.index ["decidim_organization_id", "review_status", "fulfillment_status", "created_at"], name: "idx_bih_contribution_needs_public_queue"
    t.index ["partner_profile_id", "review_status", "fulfillment_status"], name: "idx_bih_contribution_needs_profile_status"
    t.index ["partner_profile_id"], name: "idx_bih_contribution_needs_profile"
    t.index ["reviewed_by_id"], name: "idx_bih_contribution_needs_reviewer"
  end

  create_table "decidim_bih_contribution_offers", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "contribution_need_id", null: false
    t.bigint "decidim_user_id"
    t.bigint "partner_profile_id"
    t.bigint "accepted_by_id"
    t.bigint "declined_by_id"
    t.bigint "confirmed_by_id"
    t.bigint "recognized_by_id"
    t.decimal "quantity", precision: 12, scale: 2, null: false
    t.string "status", default: "offered", null: false
    t.text "decline_reason"
    t.datetime "accepted_at"
    t.datetime "declined_at"
    t.datetime "withdrawn_at"
    t.datetime "delivered_at"
    t.datetime "confirmed_at"
    t.datetime "recognized_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["accepted_by_id"], name: "idx_bih_contribution_offers_accepted_by"
    t.index ["confirmed_by_id"], name: "idx_bih_contribution_offers_confirmed_by"
    t.index ["contribution_need_id", "decidim_user_id"], name: "idx_bih_contribution_offers_active_user", unique: true, where: "((partner_profile_id IS NULL) AND ((status)::text = ANY (ARRAY[('offered'::character varying)::text, ('accepted'::character varying)::text, ('delivered'::character varying)::text, ('confirmed'::character varying)::text])))"
    t.index ["contribution_need_id", "partner_profile_id"], name: "idx_bih_contribution_offers_active_profile", unique: true, where: "((partner_profile_id IS NOT NULL) AND ((status)::text = ANY (ARRAY[('offered'::character varying)::text, ('accepted'::character varying)::text, ('delivered'::character varying)::text, ('confirmed'::character varying)::text])))"
    t.index ["contribution_need_id", "status"], name: "idx_bih_contribution_offers_need_status"
    t.index ["decidim_organization_id", "status", "created_at"], name: "idx_bih_contribution_offers_queue"
    t.index ["decidim_user_id"], name: "idx_bih_contribution_offers_user"
    t.index ["declined_by_id"], name: "idx_bih_contribution_offers_declined_by"
    t.index ["partner_profile_id"], name: "idx_bih_contribution_offers_profile"
    t.index ["recognized_by_id"], name: "idx_bih_contribution_offers_recognized_by"
  end

  create_table "decidim_bih_goodwill_accounts", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "owner_type"
    t.bigint "owner_id"
    t.string "kind", default: "user", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "cached_balance", default: 0, null: false
    t.bigint "cached_contribution", default: 0, null: false
    t.index ["decidim_organization_id", "cached_contribution", "id"], name: "idx_bih_goodwill_accounts_org_contribution_rank", order: { cached_contribution: :desc }, where: "(((kind)::text = 'user'::text) AND (cached_contribution > 0))"
    t.index ["decidim_organization_id", "cached_contribution"], name: "idx_bih_goodwill_accounts_leaderboard", where: "((kind)::text = 'user'::text)"
    t.index ["decidim_organization_id", "owner_type", "owner_id"], name: "idx_bih_goodwill_accounts_on_org_and_owner", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_goodwill_accounts_one_system_per_org", unique: true, where: "((kind)::text = 'system'::text)"
    t.index ["decidim_organization_id"], name: "index_decidim_bih_goodwill_accounts_on_decidim_organization_id"
    t.index ["owner_type", "owner_id"], name: "idx_bih_goodwill_accounts_on_owner"
  end

  create_table "decidim_bih_goodwill_award_admissions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "account_id", null: false
    t.string "source_key", null: false
    t.string "action", null: false
    t.string "period", default: "day", null: false
    t.date "period_start", null: false
    t.datetime "occurred_at", null: false
    t.string "outcome", null: false
    t.integer "amount", default: 0, null: false
    t.bigint "transaction_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "action", "period_start", "outcome"], name: "idx_goodwill_admission_allowance"
    t.index ["decidim_organization_id", "source_key"], name: "idx_goodwill_admission_source", unique: true
    t.check_constraint "amount >= 0 AND (period::text = ANY (ARRAY['day'::character varying::text, 'month'::character varying::text])) AND (outcome::text = ANY (ARRAY['awarded'::character varying::text, 'capped'::character varying::text, 'disabled'::character varying::text, 'ineligible'::character varying::text, 'duplicate'::character varying::text]))", name: "chk_goodwill_admission_outcome"
  end

  create_table "decidim_bih_goodwill_correction_intents", force: :cascade do |t|
    t.bigint "report_event_id", null: false
    t.string "decision_version", null: false
    t.integer "target_amount", null: false
    t.bigint "report_id", null: false
    t.datetime "processed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["report_event_id"], name: "idx_goodwill_correction_intent_event", unique: true
  end

  create_table "decidim_bih_goodwill_credit_corrections", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "account_id", null: false
    t.string "source_key", null: false
    t.string "decision_version", null: false
    t.string "rule_version", default: "2026-09-outcomes-v1", null: false
    t.bigint "original_transaction_id", null: false
    t.bigint "actor_id"
    t.integer "previous_target", null: false
    t.integer "target_amount", null: false
    t.integer "recognition_delta", null: false
    t.datetime "earned_at", null: false
    t.string "reason", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["account_id", "earned_at"], name: "idx_goodwill_correction_account_period"
    t.index ["decidim_organization_id", "source_key", "decision_version"], name: "idx_goodwill_correction_source_version", unique: true
    t.check_constraint "target_amount >= 0 AND previous_target >= 0 AND recognition_delta = (target_amount - previous_target)", name: "chk_goodwill_correction_delta"
  end

  create_table "decidim_bih_goodwill_credit_settlements", force: :cascade do |t|
    t.bigint "credit_correction_id", null: false
    t.string "status", default: "pending", null: false
    t.integer "wallet_delta", default: 0, null: false
    t.bigint "transaction_id"
    t.bigint "settled_by_id"
    t.datetime "notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["credit_correction_id"], name: "idx_goodwill_settlement_correction", unique: true
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'settled'::character varying::text, 'admin_pending'::character varying::text, 'superseded'::character varying::text])", name: "chk_goodwill_settlement_status"
  end

  create_table "decidim_bih_goodwill_entries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_goodwill_transaction_id", null: false
    t.bigint "decidim_bih_goodwill_account_id", null: false
    t.integer "amount", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_goodwill_account_id", "created_at"], name: "idx_bih_goodwill_entries_on_account_and_created"
    t.index ["decidim_bih_goodwill_account_id"], name: "idx_bih_goodwill_entries_on_account"
    t.index ["decidim_bih_goodwill_transaction_id"], name: "idx_bih_goodwill_entries_on_txn"
    t.index ["decidim_organization_id", "decidim_bih_goodwill_account_id", "created_at"], name: "idx_bih_goodwill_entries_org_account_created_amt", where: "(amount > 0)", include: ["amount", "decidim_bih_goodwill_transaction_id"]
    t.index ["decidim_organization_id"], name: "index_decidim_bih_goodwill_entries_on_decidim_organization_id"
  end

  create_table "decidim_bih_goodwill_group_memberships", force: :cascade do |t|
    t.integer "decidim_user_id", null: false
    t.integer "decidim_user_group_id", null: false
    t.string "role", default: "requested", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_user_group_id", "decidim_user_id"], name: "idx_bih_group_members_pair", unique: true
    t.index ["decidim_user_id"], name: "idx_bih_group_members_user"
    t.index ["role", "decidim_user_group_id"], name: "idx_bih_group_members_creator", unique: true, where: "((role)::text = 'creator'::text)"
  end

  create_table "decidim_bih_goodwill_match_requests", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.integer "points", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.bigint "created_by_id"
    t.bigint "decided_by_id"
    t.datetime "decided_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "payout_status", default: "unpaid", null: false
    t.integer "payout_amount_minor_units"
    t.string "payout_currency", default: "BAM", null: false
    t.string "payout_reference"
    t.text "payout_note"
    t.date "payout_paid_on"
    t.datetime "payout_recorded_at"
    t.bigint "payout_recorded_by_id"
    t.index ["created_by_id"], name: "idx_bih_goodwill_match_requests_on_created_by"
    t.index ["decided_by_id"], name: "idx_bih_goodwill_match_requests_on_decided_by"
    t.index ["decidim_organization_id", "payout_status", "updated_at", "id"], name: "idx_bih_goodwill_match_requests_org_payout_updated"
    t.index ["decidim_organization_id", "status", "created_at", "id"], name: "idx_bih_goodwill_match_requests_org_status_created"
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_a679c1c8c8"
    t.index ["owner_type", "owner_id"], name: "idx_bih_goodwill_match_requests_on_owner"
    t.index ["payout_recorded_by_id"], name: "idx_bih_goodwill_match_requests_on_payout_by"
  end

  create_table "decidim_bih_goodwill_referrals", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "referrer_id", null: false
    t.bigint "invitee_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "rewarded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "pending_reason"
    t.datetime "next_attempt_at"
    t.bigint "transaction_id"
    t.index ["decidim_organization_id", "status", "rewarded_at", "referrer_id"], name: "idx_bih_goodwill_referrals_org_status_rewarded"
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_2dde59e534"
    t.index ["invitee_id"], name: "idx_bih_goodwill_referrals_on_invitee", unique: true
    t.index ["referrer_id"], name: "idx_bih_goodwill_referrals_on_referrer"
    t.index ["status", "next_attempt_at"], name: "idx_goodwill_referral_due"
  end

  create_table "decidim_bih_goodwill_reward_fulfillment_events", force: :cascade do |t|
    t.bigint "decidim_bih_goodwill_reward_fulfillment_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "event_type", null: false
    t.string "source", null: false
    t.string "actor_role"
    t.datetime "occurred_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_goodwill_reward_fulfillment_id", "occurred_at", "id"], name: "idx_bih_reward_events_fulfillment_time"
    t.index ["decidim_bih_goodwill_reward_fulfillment_id"], name: "idx_bih_reward_events_fulfillment"
    t.index ["decidim_organization_id", "event_type", "occurred_at"], name: "idx_bih_reward_events_org_type_time"
    t.index ["decidim_organization_id"], name: "idx_bih_reward_events_org"
    t.index ["decidim_user_id"], name: "idx_bih_reward_events_actor"
  end

  create_table "decidim_bih_goodwill_reward_fulfillments", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_goodwill_transaction_id"
    t.bigint "decidim_user_id", null: false
    t.bigint "handled_by_id"
    t.string "reward_key", null: false
    t.integer "cost", null: false
    t.string "status", default: "requested", null: false
    t.datetime "handled_at"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "reward_expires_at"
    t.string "request_key"
    t.boolean "auto_issued", default: false, null: false
    t.string "entry_code"
    t.datetime "issued_at"
    t.datetime "confirmation_deadline_at"
    t.datetime "attendance_confirmed_at"
    t.datetime "entry_code_used_at"
    t.index ["decidim_bih_goodwill_transaction_id"], name: "idx_bih_reward_fulfillments_transaction", unique: true
    t.index ["decidim_organization_id", "confirmation_deadline_at"], name: "idx_bih_launch_invitation_pending_confirmation", where: "((auto_issued = true) AND (attendance_confirmed_at IS NULL))"
    t.index ["decidim_organization_id", "decidim_user_id", "created_at", "id"], name: "idx_bih_reward_fulfillments_org_user_created"
    t.index ["decidim_organization_id", "decidim_user_id", "request_key"], name: "idx_bih_reward_fulfillments_request_key", unique: true, where: "(request_key IS NOT NULL)"
    t.index ["decidim_organization_id", "decidim_user_id", "reward_key"], name: "idx_bih_auto_issued_one_per_user_reward", unique: true, where: "(auto_issued = true)"
    t.index ["decidim_organization_id", "entry_code"], name: "idx_bih_reward_fulfillments_entry_code", unique: true, where: "(entry_code IS NOT NULL)"
    t.index ["decidim_organization_id", "reward_expires_at", "status"], name: "idx_bih_reward_fulfillments_expiry_status", where: "(reward_expires_at IS NOT NULL)"
    t.index ["decidim_organization_id", "status", "created_at", "id"], name: "idx_bih_reward_fulfillments_org_status_created"
    t.index ["decidim_organization_id"], name: "idx_bih_reward_fulfillments_org"
    t.index ["decidim_user_id"], name: "idx_bih_reward_fulfillments_user"
    t.index ["handled_by_id"], name: "idx_bih_reward_fulfillments_handler"
  end

  create_table "decidim_bih_goodwill_rewards", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "key", null: false
    t.jsonb "title", default: {}, null: false
    t.jsonb "description", default: {}
    t.integer "cost", default: 0, null: false
    t.integer "stock"
    t.datetime "expires_at"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "sponsor_partner_profile_id"
    t.boolean "deducts_points", default: true, null: false
    t.boolean "auto_issue_at_threshold", default: false, null: false
    t.index ["decidim_organization_id", "key"], name: "idx_bih_goodwill_rewards_org_key", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_goodwill_rewards_org"
    t.index ["sponsor_partner_profile_id"], name: "idx_bih_rewards_sponsor_profile"
  end

  create_table "decidim_bih_goodwill_transactions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "kind", null: false
    t.string "reason"
    t.string "idempotency_key"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "idempotency_key"], name: "idx_bih_goodwill_txns_on_org_and_idemkey", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["decidim_organization_id", "kind", "created_at", "id"], name: "idx_bih_goodwill_txns_org_kind_created", order: { created_at: :desc, id: :desc }
    t.index ["decidim_organization_id", "kind", "reason", "created_at"], name: "idx_bih_goodwill_txns_cap_lookup"
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_2960380927"
    t.index ["kind"], name: "index_decidim_bih_goodwill_transactions_on_kind"
  end

  create_table "decidim_bih_governance_approval_attestations", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "governance_approval_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "operator_audit_event_id"
    t.string "approval_role", null: false
    t.datetime "attested_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "attested_at", "id"], name: "idx_bih_release_attestations_org_time"
    t.index ["decidim_organization_id"], name: "idx_bih_release_attestations_org"
    t.index ["decidim_user_id"], name: "idx_bih_release_attestations_user"
    t.index ["governance_approval_id"], name: "idx_bih_release_attestations_approval", unique: true
    t.index ["operator_audit_event_id"], name: "idx_bih_release_attestations_audit", unique: true
  end

  create_table "decidim_bih_governance_approvals", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "operator_audit_event_id"
    t.string "governance_kind", null: false
    t.string "approval_role", null: false
    t.string "status", null: false
    t.string "scope_key"
    t.string "app_sha"
    t.string "engine_sha"
    t.text "evidence_summary", null: false
    t.string "evidence_digest", null: false
    t.datetime "approved_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "secondary_approver_id"
    t.string "secondary_approval_role"
    t.datetime "restart_window_starts_at"
    t.datetime "restart_window_ends_at"
    t.string "local_fast_gate_status"
    t.string "local_full_gate_status"
    t.string "external_ci_status"
    t.string "branch_protection_status"
    t.string "backup_health_status"
    t.string "restore_smoke_status"
    t.string "backup_manifest_digest"
    t.string "migration_state"
    t.index ["decidim_organization_id", "governance_kind", "app_sha", "engine_sha"], name: "idx_bih_governance_release_shas"
    t.index ["decidim_organization_id", "governance_kind", "approved_at", "id"], name: "idx_bih_governance_approvals_org_kind_time"
    t.index ["decidim_organization_id", "status", "approved_at"], name: "idx_bih_governance_approvals_org_status_time"
    t.index ["decidim_organization_id"], name: "idx_bih_governance_approvals_org"
    t.index ["decidim_user_id"], name: "idx_bih_governance_approvals_actor"
    t.index ["operator_audit_event_id"], name: "idx_bih_governance_approvals_audit"
    t.index ["secondary_approver_id"], name: "idx_bih_governance_secondary_approver"
  end

  create_table "decidim_bih_inbound_email_effects", force: :cascade do |t|
    t.bigint "inbound_email_id", null: false
    t.bigint "decidim_bih_report_id", null: false
    t.string "effect", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_report_id"], name: "idx_inbound_email_effects_decidim_bih_rep_1edb82"
    t.index ["inbound_email_id", "decidim_bih_report_id", "effect"], name: "idx_bih_inbound_effect_identity", unique: true
    t.index ["inbound_email_id"], name: "index_decidim_bih_inbound_email_effects_on_inbound_email_id"
  end

  create_table "decidim_bih_inbound_email_links", force: :cascade do |t|
    t.bigint "inbound_email_id", null: false
    t.bigint "decidim_bih_report_id", null: false
    t.string "matching_method", null: false
    t.string "assurance", null: false
    t.bigint "capability_id"
    t.bigint "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["capability_id"], name: "index_decidim_bih_inbound_email_links_on_capability_id"
    t.index ["created_by_id"], name: "index_decidim_bih_inbound_email_links_on_created_by_id"
    t.index ["decidim_bih_report_id"], name: "index_decidim_bih_inbound_email_links_on_decidim_bih_report_id"
    t.index ["inbound_email_id", "decidim_bih_report_id"], name: "idx_bih_inbound_links_report", unique: true
    t.index ["inbound_email_id"], name: "index_decidim_bih_inbound_email_links_on_inbound_email_id"
  end

  create_table "decidim_bih_inbound_emails", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "account", null: false
    t.string "folder", null: false
    t.string "gm_msgid", null: false
    t.bigint "uidvalidity", null: false
    t.bigint "uid", null: false
    t.string "gm_thrid"
    t.string "message_id"
    t.string "in_reply_to"
    t.string "from_digest"
    t.string "from_domain"
    t.string "content_digest"
    t.text "labels", default: [], null: false, array: true
    t.text "references", default: [], null: false, array: true
    t.text "file_numbers", default: [], null: false, array: true
    t.boolean "message_id_conflict", default: false, null: false
    t.boolean "no_auto_response", default: false, null: false
    t.boolean "history_only", default: false, null: false
    t.jsonb "authentication", default: {}, null: false
    t.integer "size_bytes", null: false
    t.text "subject_ciphertext"
    t.text "body_text_ciphertext"
    t.text "raw_ciphertext"
    t.string "classification"
    t.string "review_reason"
    t.string "history_reason"
    t.string "state", default: "stored", null: false
    t.integer "processing_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.datetime "processed_at"
    t.datetime "data_redacted_at"
    t.datetime "internal_date", null: false
    t.bigint "dismissed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account", "folder", "uidvalidity", "uid"], name: "idx_bih_inbound_emails_uid", unique: true
    t.index ["decidim_organization_id", "account", "gm_msgid"], name: "idx_bih_inbound_emails_provider_identity", unique: true
    t.index ["decidim_organization_id", "message_id"], name: "idx_bih_inbound_emails_message_id"
    t.index ["decidim_organization_id"], name: "index_decidim_bih_inbound_emails_on_decidim_organization_id"
    t.index ["dismissed_by_id"], name: "index_decidim_bih_inbound_emails_on_dismissed_by_id"
    t.index ["gm_thrid"], name: "index_decidim_bih_inbound_emails_on_gm_thrid"
    t.index ["state", "locked_at"], name: "index_decidim_bih_inbound_emails_on_state_and_locked_at"
  end

  create_table "decidim_bih_komsiluk_help_responses", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.bigint "user_id", null: false
    t.datetime "withdrawn_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id", "user_id"], name: "idx_komsiluk_help_response", unique: true
    t.index ["user_id"], name: "index_decidim_bih_komsiluk_help_responses_on_user_id"
  end

  create_table "decidim_bih_komsiluk_phone_deliveries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "send_intent_id", null: false
    t.bigint "platform_delivery_id", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "channels", default: [], null: false
    t.string "destination_digest", null: false
    t.jsonb "provider_message_ids", default: [], null: false
    t.jsonb "previous_attempts", default: [], null: false
    t.datetime "due_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "attempted_at"
    t.datetime "delivered_at"
    t.string "reason"
    t.datetime "provider_checked_at"
    t.string "provider_status"
    t.integer "reserved_minor", default: 0, null: false
    t.datetime "budget_released_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "idx_komsiluk_phone_org"
    t.index ["decidim_user_id"], name: "idx_komsiluk_phone_user"
    t.index ["platform_delivery_id"], name: "idx_komsiluk_phone_receipt_unique", unique: true
    t.index ["status", "due_at"], name: "idx_komsiluk_phone_pending"
  end

  create_table "decidim_bih_komsiluk_photo_drafts", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "user_id", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_decidim_bih_komsiluk_photo_drafts_on_expires_at"
    t.index ["organization_id"], name: "index_decidim_bih_komsiluk_photo_drafts_on_organization_id"
    t.index ["user_id"], name: "index_decidim_bih_komsiluk_photo_drafts_on_user_id"
  end

  create_table "decidim_bih_komsiluk_post_flags", force: :cascade do |t|
    t.bigint "decidim_bih_komsiluk_post_id", null: false
    t.bigint "decidim_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_komsiluk_post_id", "decidim_user_id"], name: "idx_bih_komsiluk_post_flags_unique", unique: true
  end

  create_table "decidim_bih_komsiluk_post_reviews", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_komsiluk_post_id", null: false
    t.bigint "reviewer_id"
    t.string "action", null: false
    t.string "reason", null: false
    t.string "previous_status", null: false
    t.string "resulting_status", null: false
    t.integer "content_revision", null: false
    t.integer "flagged_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_komsiluk_post_id", "created_at"], name: "idx_board_reviews_post_time"
    t.index ["decidim_organization_id"], name: "idx_board_reviews_org"
  end

  create_table "decidim_bih_komsiluk_post_revisions", force: :cascade do |t|
    t.bigint "post_id", null: false
    t.bigint "actor_id"
    t.integer "content_revision", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.boolean "notified", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_decidim_bih_komsiluk_post_revisions_on_actor_id"
    t.index ["post_id", "content_revision"], name: "idx_komsiluk_post_revision", unique: true
  end

  create_table "decidim_bih_komsiluk_posts", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.bigint "komsiluk_id", null: false
    t.string "category", default: "general", null: false
    t.string "title", null: false
    t.text "body"
    t.string "status", default: "open", null: false
    t.datetime "expires_at"
    t.datetime "closed_at"
    t.datetime "hidden_at"
    t.integer "flagged_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "origin", default: "legacy", null: false
    t.integer "content_revision", default: 1, null: false
    t.string "publication_key"
    t.jsonb "details", default: {}, null: false
    t.datetime "published_at"
    t.string "review_state", default: "unreviewed", null: false
    t.integer "lock_version", default: 0, null: false
    t.string "notification_capture_identity"
    t.index ["decidim_organization_id", "komsiluk_id", "created_at", "id"], name: "idx_komsiluk_board_feed"
    t.index ["decidim_organization_id", "komsiluk_id", "publication_key"], name: "idx_komsiluk_publication_placement", unique: true, where: "(publication_key IS NOT NULL)"
    t.index ["decidim_organization_id", "komsiluk_id", "status"], name: "idx_bih_komsiluk_posts_on_org_komsiluk_status"
    t.index ["decidim_organization_id", "review_state"], name: "idx_komsiluk_board_review"
    t.index ["decidim_user_id"], name: "idx_bih_komsiluk_posts_on_user"
    t.index ["publication_key"], name: "index_decidim_bih_komsiluk_posts_on_publication_key"
  end

  create_table "decidim_bih_komsiluk_send_intents", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "kind", null: false
    t.string "state", default: "preview", null: false
    t.string "publication_key", null: false
    t.string "preview_digest", null: false
    t.text "payload_ciphertext"
    t.datetime "payload_scrubbed_at"
    t.datetime "expires_at", null: false
    t.datetime "confirmed_at"
    t.integer "recipients_count", default: 0, null: false
    t.integer "reserved_minor", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "publication_key", "kind"], name: "idx_komsiluk_intents_publication"
    t.index ["decidim_organization_id"], name: "idx_komsiluk_intents_org"
    t.index ["decidim_user_id"], name: "idx_komsiluk_intents_actor"
  end

  create_table "decidim_bih_komsiluk_sms_budgets", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.date "budget_on", null: false
    t.string "currency", null: false
    t.integer "reserved_minor", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "budget_on", "currency"], name: "idx_komsiluk_sms_budget_unique", unique: true
    t.check_constraint "reserved_minor >= 0", name: "komsiluk_sms_budget_nonnegative"
  end

  create_table "decidim_bih_local_areas", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "kind", null: false
    t.bigint "parent_id"
    t.jsonb "name", default: {}, null: false
    t.string "slug", null: false
    t.jsonb "boundary"
    t.float "centroid_lat"
    t.float "centroid_lon"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "predsjednik"
    t.string "telefon"
    t.jsonb "metadata", default: {}
    t.string "primary_mz_slug"
    t.jsonb "overlapping_mz_slugs", default: []
    t.string "zona"
    t.index ["decidim_organization_id", "kind", "zona"], name: "idx_bih_local_areas_zona"
    t.index ["decidim_organization_id", "kind"], name: "idx_bih_local_areas_on_org_and_kind"
    t.index ["decidim_organization_id", "slug"], name: "idx_bih_local_areas_on_org_and_slug", unique: true
    t.index ["parent_id"], name: "idx_bih_local_areas_on_parent_id"
    t.index ["primary_mz_slug"], name: "idx_bih_local_areas_on_primary_mz_slug"
  end

  create_table "decidim_bih_login_tokens", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.string "purpose", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "phone"
    t.index ["decidim_organization_id"], name: "index_decidim_bih_login_tokens_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "index_decidim_bih_login_tokens_on_decidim_user_id"
    t.index ["token_digest"], name: "index_decidim_bih_login_tokens_on_token_digest", unique: true
  end

  create_table "decidim_bih_mailbox_cursors", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "account", null: false
    t.string "folder", null: false
    t.bigint "uidvalidity", default: 0, null: false
    t.bigint "last_uid", default: 0, null: false
    t.datetime "activation_at"
    t.datetime "last_polled_at"
    t.datetime "last_success_at"
    t.string "last_error_class"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "account"], name: "idx_bih_mailbox_cursors_account", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_bih_mailbox_cursors_on_decidim_organization_id"
  end

  create_table "decidim_bih_messaging_attempts", force: :cascade do |t|
    t.bigint "intent_id", null: false
    t.string "channel_group", null: false
    t.string "channel", null: false
    t.string "destination_version"
    t.string "status", default: "queued", null: false
    t.string "reason"
    t.string "provider_message_id"
    t.datetime "claimed_at"
    t.datetime "settled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "destination_kind"
    t.string "destination_digest"
    t.string "provider_message_ids", default: [], null: false, array: true
    t.datetime "accepted_at"
    t.datetime "resolved_at"
    t.index ["destination_kind", "destination_digest"], name: "idx_bih_messaging_attempts_destination"
    t.index ["intent_id", "channel_group", "channel"], name: "idx_bih_messaging_attempts_group"
    t.index ["provider_message_id"], name: "idx_bih_messaging_attempts_provider"
    t.index ["provider_message_ids"], name: "idx_bih_messaging_attempts_provider_ids", using: :gin
  end

  create_table "decidim_bih_messaging_intents", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.bigint "decidim_bih_account_notification_id"
    t.string "message_class", null: false
    t.string "recipient_kind", null: false
    t.string "recipient_reference"
    t.string "correlation_key", null: false
    t.string "deduplication_scope", null: false
    t.string "status", default: "planned", null: false
    t.string "mode", default: "shadow", null: false
    t.string "policy_version", null: false
    t.string "eligibility_version", null: false
    t.string "context_digest"
    t.jsonb "reason_codes", default: [], null: false
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_account_notification_id"], name: "idx_bih_messaging_intents_legacy"
    t.index ["decidim_organization_id", "deduplication_scope", "correlation_key"], name: "idx_bih_messaging_intents_dedupe", unique: true
    t.index ["decidim_organization_id", "message_class", "created_at"], name: "idx_bih_messaging_intents_class"
  end

  create_table "decidim_bih_messaging_organization_policies", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "policy_version", null: false
    t.jsonb "defaults", default: {}, null: false
    t.jsonb "supported_combinations", default: {}, null: false
    t.datetime "effective_from", null: false
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "active"], name: "idx_bih_messaging_org_policies_active"
    t.index ["decidim_organization_id", "policy_version"], name: "idx_bih_messaging_org_policies_version", unique: true
  end

  create_table "decidim_bih_messaging_preference_changes", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "topic", null: false
    t.string "channel", null: false
    t.string "previous_state"
    t.string "new_state", null: false
    t.string "previous_source"
    t.string "source", null: false
    t.string "actor_type", null: false
    t.bigint "actor_id"
    t.string "operation", null: false
    t.string "change_id", null: false
    t.string "policy_version", null: false
    t.string "ui_revision"
    t.datetime "recorded_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["change_id"], name: "idx_bih_messaging_pref_changes_change"
    t.index ["decidim_organization_id", "decidim_user_id", "recorded_at"], name: "idx_bih_messaging_pref_changes_user"
    t.check_constraint "new_state::text = ANY (ARRAY['allowed'::character varying::text, 'blocked'::character varying::text])", name: "bih_messaging_pref_changes_new_state"
    t.check_constraint "previous_state IS NULL OR (previous_state::text = ANY (ARRAY['allowed'::character varying::text, 'blocked'::character varying::text]))", name: "bih_messaging_pref_changes_prev_state"
  end

  create_table "decidim_bih_messaging_preferences", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "topic", null: false
    t.string "state", null: false
    t.string "source", null: false
    t.string "policy_version", null: false
    t.string "change_id", null: false
    t.datetime "changed_at", null: false
    t.string "imported_from"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "topic"], name: "idx_bih_messaging_prefs_identity", unique: true
    t.index ["decidim_organization_id", "topic", "state"], name: "idx_bih_messaging_prefs_audience"
    t.index ["decidim_organization_id", "updated_at"], name: "idx_bih_messaging_prefs_batch"
    t.check_constraint "source::text = ANY (ARRAY['account'::character varying::text, 'provider_opt_out'::character varying::text, 'organization_default'::character varying::text, 'legacy_import'::character varying::text, 'unknown'::character varying::text])", name: "bih_messaging_prefs_source"
    t.check_constraint "state::text = ANY (ARRAY['allowed'::character varying::text, 'blocked'::character varying::text])", name: "bih_messaging_prefs_state"
    t.check_constraint "topic::text = ANY (ARRAY['report_updates'::character varying::text, 'community_news'::character varying::text, 'platform_news'::character varying::text, 'neighborhood_info'::character varying::text])", name: "bih_messaging_prefs_topic"
  end

  create_table "decidim_bih_messaging_suppressions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "provider", null: false
    t.string "channel", null: false
    t.string "destination_kind", null: false
    t.string "destination_digest", null: false
    t.integer "address_version", default: 1, null: false
    t.string "reason", null: false
    t.string "source", null: false
    t.datetime "suppressed_at", null: false
    t.datetime "reactivated_at"
    t.string "reactivation_evidence"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "occurred_at"
    t.string "event_ref"
    t.index ["decidim_organization_id", "channel", "reactivated_at"], name: "idx_bih_messaging_suppressions_active"
    t.index ["decidim_organization_id", "provider", "channel", "destination_digest", "address_version"], name: "idx_bih_messaging_suppressions_identity", unique: true
    t.index ["decidim_organization_id", "provider", "event_ref"], name: "idx_bih_messaging_suppressions_event", unique: true
  end

  create_table "decidim_bih_operator_audit_events", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "role"
    t.string "permission"
    t.string "event_type", null: false
    t.string "resource_type"
    t.bigint "resource_id"
    t.datetime "occurred_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "event_type", "occurred_at"], name: "idx_bih_operator_audit_org_type_time"
    t.index ["decidim_organization_id", "occurred_at", "id"], name: "idx_bih_operator_audit_org_time"
    t.index ["decidim_user_id"], name: "idx_bih_operator_audit_actor"
    t.index ["resource_type", "resource_id", "occurred_at"], name: "idx_bih_operator_audit_resource_time"
  end

  create_table "decidim_bih_operator_messages", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "sender_id"
    t.bigint "recipient_id", null: false
    t.string "subject", null: false
    t.text "body", null: false
    t.string "context_type"
    t.bigint "context_id"
    t.datetime "sent_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "delivery_request_digest"
    t.index ["context_type", "context_id", "sent_at"], name: "idx_bih_operator_messages_context_sent"
    t.index ["decidim_organization_id", "delivery_request_digest"], name: "idx_bih_operator_delivery_request", unique: true, where: "(delivery_request_digest IS NOT NULL)"
    t.index ["decidim_organization_id", "sent_at", "id"], name: "idx_bih_operator_messages_org_sent"
    t.index ["recipient_id"], name: "idx_bih_operator_messages_recipient"
    t.index ["sender_id"], name: "idx_bih_operator_messages_sender"
  end

  create_table "decidim_bih_operator_roles", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "role", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "area_scope", default: "all", null: false
    t.jsonb "komsiluk_ids", default: [], null: false
    t.index ["created_by_id"], name: "idx_bih_operator_roles_created_by"
    t.index ["decidim_organization_id", "decidim_user_id", "role", "revoked_at"], name: "idx_bih_operator_roles_org_user_role"
    t.index ["decidim_organization_id", "role", "expires_at"], name: "idx_bih_operator_roles_org_role_expiry"
  end

  create_table "decidim_bih_org_spending_requests", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "source_partner_profile_id", null: false
    t.bigint "target_partner_profile_id"
    t.bigint "requested_by_id"
    t.bigint "decided_by_id"
    t.string "request_type", null: false
    t.string "status", default: "pending", null: false
    t.integer "points", null: false
    t.string "category", null: false
    t.string "reward_title"
    t.text "reward_description"
    t.integer "reward_stock"
    t.integer "reward_cost"
    t.datetime "decided_at"
    t.text "rejection_reason"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_by_id"], name: "idx_bih_org_spending_decided_by"
    t.index ["decidim_organization_id", "status", "request_type"], name: "idx_bih_org_spending_queue"
    t.index ["decidim_organization_id"], name: "idx_bih_org_spending_org"
    t.index ["requested_by_id"], name: "idx_bih_org_spending_requested_by"
    t.index ["source_partner_profile_id"], name: "idx_bih_org_spending_source"
    t.index ["target_partner_profile_id"], name: "idx_bih_org_spending_target"
  end

  create_table "decidim_bih_partner_memberships", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "partner_profile_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "role", null: false
    t.string "status", default: "accepted", null: false
    t.bigint "invited_by_id"
    t.datetime "accepted_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "status"], name: "idx_bih_partner_members_org_user_status"
    t.index ["invited_by_id"], name: "idx_bih_partner_members_invited_by"
    t.index ["partner_profile_id", "decidim_user_id"], name: "idx_bih_partner_members_profile_user", unique: true
    t.index ["partner_profile_id", "role", "status"], name: "idx_bih_partner_members_profile_role_status"
  end

  create_table "decidim_bih_partner_notices", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "partner_profile_id", null: false
    t.bigint "author_id"
    t.string "title", null: false
    t.text "body", null: false
    t.string "notice_type", default: "update", null: false
    t.datetime "published_at"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "idx_bih_partner_notices_author"
    t.index ["decidim_organization_id", "published_at"], name: "idx_bih_partner_notices_org_published"
    t.index ["partner_profile_id", "published_at"], name: "idx_bih_partner_notices_profile_published"
  end

  create_table "decidim_bih_partner_profiles", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "display_name", null: false
    t.string "legal_name"
    t.string "slug", null: false
    t.string "kind", null: false
    t.string "verification_status", default: "draft", null: false
    t.text "public_description"
    t.string "logo"
    t.string "website"
    t.bigint "local_area_id"
    t.string "private_contact_name"
    t.string "private_contact_email"
    t.string "private_contact_phone"
    t.bigint "verified_by_id"
    t.datetime "verified_at"
    t.datetime "rejected_at"
    t.string "rejection_reason"
    t.bigint "legacy_user_group_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "legacy_user_group_id"], name: "idx_bih_partner_profiles_legacy_group", unique: true, where: "(legacy_user_group_id IS NOT NULL)"
    t.index ["decidim_organization_id", "slug"], name: "idx_bih_partner_profiles_org_slug", unique: true
    t.index ["decidim_organization_id", "verification_status", "kind"], name: "idx_bih_partner_profiles_org_status_kind"
    t.index ["verified_by_id"], name: "idx_bih_partner_profiles_verified_by"
  end

  create_table "decidim_bih_partner_project_submissions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "partner_profile_id", null: false
    t.bigint "decidim_user_id"
    t.bigint "reviewed_by_id"
    t.bigint "decidim_budgets_project_id"
    t.string "title", null: false
    t.text "description", null: false
    t.bigint "budget_amount", null: false
    t.string "address"
    t.date "starts_on"
    t.date "ends_on"
    t.string "review_status", default: "draft", null: false
    t.datetime "submitted_at"
    t.datetime "reviewed_at"
    t.text "rejection_reason"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_budgets_project_id"], name: "idx_bih_project_submissions_project", unique: true, where: "(decidim_budgets_project_id IS NOT NULL)"
    t.index ["decidim_organization_id", "review_status", "created_at"], name: "idx_bih_project_submissions_queue"
    t.index ["decidim_user_id"], name: "idx_bih_project_submissions_user"
    t.index ["partner_profile_id"], name: "idx_bih_project_submissions_profile"
    t.index ["reviewed_by_id"], name: "idx_bih_project_submissions_reviewer"
  end

  create_table "decidim_bih_platform_deliveries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "identity", null: false
    t.datetime "expires_at", null: false
    t.datetime "deadline_at", null: false
    t.datetime "fallback_requested_at"
    t.jsonb "fallback_context", default: {}, null: false
    t.datetime "inbox_created_at"
    t.datetime "acknowledged_at"
    t.string "acknowledgment_kind"
    t.datetime "push_queued_at"
    t.bigint "push_intent_id"
    t.bigint "account_notification_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "komsiluk_post_id"
    t.integer "publication_revision"
    t.datetime "cancelled_at"
    t.string "cancellation_reason"
    t.datetime "browser_displayed_at"
    t.datetime "inbox_read_at"
    t.datetime "notification_dispatched_at"
    t.bigint "notification_id"
    t.index ["decidim_organization_id", "decidim_user_id", "identity"], name: "idx_platform_delivery_identity", unique: true
    t.index ["decidim_organization_id"], name: "idx_platform_delivery_org"
    t.index ["decidim_user_id"], name: "idx_platform_delivery_user"
    t.index ["komsiluk_post_id"], name: "idx_platform_delivery_komsiluk_post"
    t.index ["notification_id"], name: "idx_platform_delivery_notification"
  end

  create_table "decidim_bih_privacy_retention_runs", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "status", default: "running", null: false
    t.boolean "dry_run", default: true, null: false
    t.string "source", default: "service", null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.integer "total", default: 0, null: false
    t.jsonb "counts", default: {}, null: false
    t.jsonb "cutoffs", default: {}, null: false
    t.string "error_class"
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "started_at", "id"], name: "idx_bih_privacy_retention_runs_org_started"
    t.index ["decidim_organization_id", "status", "started_at"], name: "idx_bih_privacy_retention_runs_org_status_started"
    t.index ["decidim_organization_id"], name: "idx_bih_privacy_retention_runs_on_org"
  end

  create_table "decidim_bih_project_donation_links", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_budgets_project_id", null: false
    t.string "campaign_key", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "active"], name: "idx_bih_project_donation_links_active"
    t.index ["decidim_organization_id", "campaign_key"], name: "idx_bih_project_donation_links_campaign", unique: true
    t.index ["decidim_organization_id", "decidim_budgets_project_id"], name: "idx_bih_project_donation_links_project", unique: true
  end

  create_table "decidim_bih_race_editions", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "key", null: false
    t.boolean "scores_visible", default: true, null: false
    t.integer "visibility_version", default: 0, null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "baseline_at"
    t.datetime "captured_at"
    t.jsonb "snapshot", default: {}, null: false
    t.string "snapshot_digest"
    t.datetime "finalized_at"
    t.bigint "finalized_by_id"
    t.string "final_digest"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "key"], name: "idx_bih_race_edition_org_key", unique: true
  end

  create_table "decidim_bih_race_events", force: :cascade do |t|
    t.bigint "edition_id", null: false
    t.bigint "actor_id"
    t.string "kind", null: false
    t.string "item_key"
    t.jsonb "data", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["edition_id", "item_key", "id"], name: "idx_bih_race_review_item"
    t.index ["edition_id"], name: "index_decidim_bih_race_events_on_edition_id"
  end

  create_table "decidim_bih_race_memberships", force: :cascade do |t|
    t.bigint "edition_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "komsiluk_id", null: false
    t.datetime "assigned_at", null: false
    t.datetime "qualified_at"
    t.string "provenance", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["edition_id", "decidim_user_id"], name: "idx_bih_race_membership_user", unique: true
    t.index ["edition_id"], name: "index_decidim_bih_race_memberships_on_edition_id"
  end

  create_table "decidim_bih_race_standings", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "komsiluk_id", null: false
    t.string "zona"
    t.integer "registered", default: 0, null: false
    t.integer "reports", default: 0, null: false
    t.integer "proposals", default: 0, null: false
    t.integer "score", default: 0, null: false
    t.datetime "reached_at"
    t.integer "rank_overall", default: 0, null: false
    t.integer "rank_in_zone", default: 0, null: false
    t.datetime "computed_at", null: false
    t.boolean "final", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "edition_key", default: "2026", null: false
    t.index ["decidim_organization_id", "final", "rank_overall"], name: "idx_bih_race_standings_rank"
    t.index ["decidim_organization_id", "komsiluk_id", "final"], name: "idx_bih_race_standings_unique", unique: true
  end

  create_table "decidim_bih_report_collections", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "title", null: false
    t.string "topic", null: false
    t.string "state", default: "collecting", null: false
    t.bigint "assigned_to_id"
    t.datetime "review_due_at"
    t.text "summary"
    t.text "submission_snapshot"
    t.string "recipient"
    t.string "external_reference"
    t.datetime "submitted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id"], name: "index_decidim_bih_report_collections_on_assigned_to_id"
    t.index ["decidim_organization_id"], name: "idx_bih_report_collections_org"
  end

  create_table "decidim_bih_report_corroborations", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.bigint "report_id", null: false
    t.bigint "original_report_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "report_id"], name: "idx_bih_corroboration_actor_problem", unique: true
  end

  create_table "decidim_bih_report_dispatch_evidence", force: :cascade do |t|
    t.bigint "dispatch_id", null: false
    t.bigint "evidence_item_id", null: false
    t.string "request_source_type"
    t.bigint "request_source_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dispatch_id"], name: "index_decidim_bih_report_dispatch_evidence_on_dispatch_id"
    t.index ["evidence_item_id", "request_source_type", "request_source_id", "dispatch_id"], name: "dispatch_evidence_request_identity", unique: true
    t.index ["evidence_item_id"], name: "index_decidim_bih_report_dispatch_evidence_on_evidence_item_id"
    t.index ["request_source_type", "request_source_id"], name: "idx_report_dispatch_evidence_request_source_81b8d2"
  end

  create_table "decidim_bih_report_dispatches", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.bigint "approved_by_id", null: false
    t.string "kind", null: false
    t.string "state", default: "queued", null: false
    t.string "input_digest", null: false
    t.string "deduplication_key", null: false
    t.text "snapshot_ciphertext", null: false
    t.string "message_id", null: false
    t.string "error_class"
    t.datetime "started_at"
    t.datetime "accepted_at"
    t.datetime "reconciled_at"
    t.bigint "reconciled_by_id"
    t.text "reconciliation_evidence"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "data_redacted_at"
    t.index ["approved_by_id"], name: "index_decidim_bih_report_dispatches_on_approved_by_id"
    t.index ["deduplication_key"], name: "idx_bih_dispatch_identity", unique: true
    t.index ["reconciled_by_id"], name: "index_decidim_bih_report_dispatches_on_reconciled_by_id"
    t.index ["report_id"], name: "index_decidim_bih_report_dispatches_on_report_id"
    t.index ["state", "created_at"], name: "idx_bih_dispatch_pending"
  end

  create_table "decidim_bih_report_events", force: :cascade do |t|
    t.bigint "decidim_bih_report_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id"
    t.string "event_type", null: false
    t.string "source", null: false
    t.string "actor_role"
    t.datetime "occurred_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_bih_report_id", "occurred_at", "id"], name: "idx_bih_report_events_report_occurred"
    t.index ["decidim_bih_report_id"], name: "idx_bih_report_events_report"
    t.index ["decidim_organization_id", "event_type", "occurred_at"], name: "idx_bih_report_events_org_type_occurred"
    t.index ["decidim_organization_id"], name: "idx_bih_report_events_org"
    t.index ["decidim_user_id"], name: "idx_bih_report_events_actor"
  end

  create_table "decidim_bih_report_evidence_items", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.string "source", null: false
    t.bigint "source_id"
    t.bigint "blob_id"
    t.string "checksum", null: false
    t.string "content_type", null: false
    t.bigint "byte_size", null: false
    t.jsonb "assessment", default: {}, null: false
    t.string "sensitive_flags", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "purged_at"
    t.bigint "source_blob_id"
    t.text "purge_descriptor_ciphertext"
    t.datetime "purge_completed_at"
    t.index ["blob_id"], name: "index_decidim_bih_report_evidence_items_on_blob_id"
    t.index ["report_id", "checksum"], name: "report_evidence_live_identity", unique: true, where: "(purged_at IS NULL)"
    t.index ["report_id"], name: "index_decidim_bih_report_evidence_items_on_report_id"
    t.check_constraint "purged_at IS NULL AND blob_id IS NOT NULL OR purged_at IS NOT NULL AND blob_id IS NULL", name: "report_evidence_live_blob_or_tombstone"
  end

  create_table "decidim_bih_report_evidence_shares", force: :cascade do |t|
    t.bigint "evidence_item_id", null: false
    t.bigint "dispatch_id", null: false
    t.string "request_source_type"
    t.bigint "request_source_id"
    t.string "recipient_digest", null: false
    t.string "token_digest", null: false
    t.text "token_ciphertext", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "last_accessed_at"
    t.integer "access_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dispatch_id"], name: "index_decidim_bih_report_evidence_shares_on_dispatch_id"
    t.index ["evidence_item_id", "request_source_type", "request_source_id", "recipient_digest"], name: "prepared_service_evidence_share_identity", unique: true
    t.index ["evidence_item_id"], name: "index_decidim_bih_report_evidence_shares_on_evidence_item_id"
    t.index ["request_source_type", "request_source_id"], name: "idx_report_evidence_shares_request_source_2c39a2"
    t.index ["token_digest"], name: "index_decidim_bih_report_evidence_shares_on_token_digest", unique: true
  end

  create_table "decidim_bih_report_messages", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.bigint "actor_id"
    t.bigint "account_notification_id"
    t.string "actor_role", null: false
    t.string "kind", null: false
    t.text "body", null: false
    t.string "notification_state", default: "pending", null: false
    t.datetime "notified_at"
    t.datetime "read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "answers_message_id"
    t.index ["account_notification_id"], name: "index_decidim_bih_report_messages_on_account_notification_id"
    t.index ["actor_id"], name: "index_decidim_bih_report_messages_on_actor_id"
    t.index ["answers_message_id"], name: "index_decidim_bih_report_messages_on_answers_message_id"
    t.index ["report_id"], name: "index_decidim_bih_report_messages_on_report_id"
  end

  create_table "decidim_bih_report_obligations", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.string "kind", null: false
    t.string "actor", null: false
    t.string "state", default: "open", null: false
    t.datetime "due_at"
    t.datetime "reminded_at"
    t.string "source_type"
    t.bigint "source_id"
    t.string "fulfilled_by_type"
    t.bigint "fulfilled_by_id"
    t.string "policy_key"
    t.string "effect_key"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["effect_key"], name: "index_decidim_bih_report_obligations_on_effect_key", unique: true, where: "(effect_key IS NOT NULL)"
    t.index ["fulfilled_by_type", "fulfilled_by_id"], name: "idx_report_obligations_fulfilled_by_3bb29a"
    t.index ["report_id", "state", "due_at"], name: "index_report_obligations_open_due"
    t.index ["report_id"], name: "index_decidim_bih_report_obligations_on_report_id"
    t.index ["source_type", "source_id"], name: "idx_report_obligations_source_8243f7"
  end

  create_table "decidim_bih_report_photo_drafts", force: :cascade do |t|
    t.bigint "organization_id", null: false
    t.bigint "consumed_report_id"
    t.string "owner_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["consumed_report_id"], name: "index_decidim_bih_report_photo_drafts_on_consumed_report_id"
    t.index ["expires_at"], name: "index_decidim_bih_report_photo_drafts_on_expires_at"
    t.index ["organization_id"], name: "index_decidim_bih_report_photo_drafts_on_organization_id"
  end

  create_table "decidim_bih_report_private_storage_cleanups", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "attachment_id", null: false
    t.bigint "original_blob_id", null: false
    t.bigint "replacement_blob_id", null: false
    t.string "original_service_name", null: false
    t.text "original_key_ciphertext", null: false
    t.string "state", default: "pending", null: false
    t.string "last_error_class"
    t.datetime "cleaned_at"
    t.datetime "last_attempted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id"], name: "idx_private_cleanup_org"
    t.index ["state", "last_attempted_at", "id"], name: "idx_private_cleanup_pending"
  end

  create_table "decidim_bih_report_reply_capabilities", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_report_id", null: false
    t.string "audience", null: false
    t.text "correspondent_digests", default: [], null: false, array: true
    t.text "token_ciphertext", null: false
    t.string "token_digest", null: false
    t.bigint "question_message_id"
    t.datetime "revoked_at"
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "decidim_bih_report_id, audience, correspondent_digests, COALESCE(question_message_id, (0)::bigint)", name: "idx_bih_reply_capabilities_active", unique: true, where: "(revoked_at IS NULL)"
    t.index ["decidim_bih_report_id"], name: "idx_report_reply_capabilities_decidim_bih_rep_e2f09b"
    t.index ["decidim_organization_id"], name: "idx_report_reply_capabilities_decidim_organiz_36b3be"
    t.index ["question_message_id"], name: "idx_report_reply_capabilities_question_messag_261b14"
    t.index ["token_digest"], name: "index_decidim_bih_report_reply_capabilities_on_token_digest", unique: true
    t.check_constraint "audience::text = ANY (ARRAY['service'::character varying::text, 'citizen'::character varying::text])", name: "bih_reply_capability_audience"
  end

  create_table "decidim_bih_report_review_proposals", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.string "input_digest", null: false
    t.string "prompt_version", null: false
    t.string "state", default: "generating", null: false
    t.string "model"
    t.string "error_code"
    t.text "proposal_ciphertext"
    t.datetime "finished_at"
    t.bigint "decided_by_id"
    t.datetime "decided_at"
    t.string "approved_action"
    t.jsonb "changed_fields", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "data_redacted_at"
    t.string "failure_reason"
    t.boolean "repair_attempted", default: false, null: false
    t.index ["decided_by_id"], name: "index_decidim_bih_report_review_proposals_on_decided_by_id"
    t.index ["report_id", "input_digest", "prompt_version"], name: "idx_bih_review_proposal_version", unique: true
    t.index ["report_id"], name: "index_decidim_bih_report_review_proposals_on_report_id"
    t.index ["state", "created_at"], name: "idx_bih_review_proposal_pending"
  end

  create_table "decidim_bih_report_routing_guides", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "key", null: false
    t.string "title", null: false
    t.text "body_sr", null: false
    t.string "categories", default: [], null: false, array: true
    t.string "approved_recipient_keys", default: [], null: false, array: true
    t.boolean "active", default: false, null: false
    t.integer "version", default: 1, null: false
    t.bigint "approved_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_decidim_bih_report_routing_guides_on_approved_by_id"
    t.index ["decidim_organization_id", "key"], name: "report_routing_guide_identity", unique: true
    t.index ["decidim_organization_id"], name: "idx_report_routing_guides_decidim_organiz_32b9d7"
  end

  create_table "decidim_bih_report_second_reminders", force: :cascade do |t|
    t.bigint "report_id", null: false
    t.bigint "question_id", null: false
    t.bigint "account_notification_id", null: false
    t.datetime "delivered_at"
    t.datetime "response_due_at"
    t.datetime "closed_at"
    t.string "outcome", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_notification_id"], name: "idx_bih_second_reminder_notification"
    t.index ["question_id"], name: "idx_bih_second_reminder_question"
    t.index ["report_id"], name: "idx_bih_second_reminder_report", unique: true
  end

  create_table "decidim_bih_report_service_senders", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "email_digest", null: false
    t.string "label", null: false
    t.text "email_ciphertext", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "email_digest"], name: "idx_bih_service_senders_email", unique: true
    t.index ["decidim_organization_id"], name: "idx_report_service_senders_decidim_organiz_200b1b"
  end

  create_table "decidim_bih_reports", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "reference", null: false
    t.text "description", null: false
    t.string "category"
    t.string "department"
    t.string "severity"
    t.string "ai_summary"
    t.string "status", default: "primljeno", null: false
    t.string "address"
    t.float "latitude"
    t.float "longitude"
    t.string "reporter_email"
    t.string "reporter_phone"
    t.boolean "anonymous", default: false, null: false
    t.datetime "forwarded_at"
    t.string "sistem48_reference"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "decidim_user_id"
    t.string "forwarding_error_class"
    t.string "forwarding_error_message"
    t.string "forwarding_error_code"
    t.integer "forwarding_failure_count", default: 0, null: false
    t.datetime "forwarding_failed_at"
    t.text "status_note"
    t.string "sistem48_status"
    t.datetime "sistem48_synced_at"
    t.jsonb "status_history", default: [], null: false
    t.integer "corroboration_count", default: 0, null: false
    t.boolean "needs_review", default: false, null: false
    t.string "mz_slug"
    t.text "internal_note"
    t.bigint "duplicate_of_report_id"
    t.string "status_token", null: false
    t.boolean "public_location_exact", default: false, null: false
    t.string "review_state", default: "pending", null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.bigint "assigned_to_id"
    t.datetime "response_due_at"
    t.text "forwarding_note"
    t.string "forwarding_recipient"
    t.string "external_submission_reference"
    t.text "resolution_evidence"
    t.string "resident_feedback"
    t.datetime "reminded_due_at"
    t.bigint "report_collection_id"
    t.string "report_subtype"
    t.string "location_kind", default: "description", null: false
    t.float "location_end_latitude"
    t.float "location_end_longitude"
    t.jsonb "original_location", default: {}, null: false
    t.datetime "location_reviewed_at"
    t.bigint "location_reviewed_by_id"
    t.datetime "last_citizen_reply_at"
    t.bigint "last_reviewed_message_id"
    t.datetime "review_pending_since"
    t.string "deadline_kind"
    t.jsonb "review_draft", default: {}, null: false
    t.text "search_text"
    t.datetime "removed_from_public_at"
    t.string "closure_basis"
    t.string "removed_from_public_reason"
    t.jsonb "details", default: {}, null: false
    t.index "to_tsvector('simple'::regconfig, COALESCE(search_text, ''::text))", name: "index_decidim_bih_reports_on_search_text", using: :gin
    t.index ["decidim_organization_id", "created_at", "id"], name: "idx_bih_reports_org_created", order: { created_at: :desc, id: :desc }
    t.index ["decidim_organization_id", "created_at", "id"], name: "idx_bih_reports_org_located_created", order: { created_at: :desc, id: :desc }, where: "((latitude IS NOT NULL) AND (longitude IS NOT NULL))"
    t.index ["decidim_organization_id", "duplicate_of_report_id"], name: "idx_bih_reports_org_duplicate_of"
    t.index ["decidim_organization_id", "mz_slug"], name: "idx_bih_reports_org_mz_slug"
    t.index ["decidim_organization_id", "needs_review", "created_at"], name: "idx_bih_reports_org_needs_review_created"
    t.index ["decidim_organization_id", "reference"], name: "idx_on_decidim_organization_id_reference_a1bcc0f8c7", unique: true
    t.index ["decidim_organization_id", "response_due_at"], name: "idx_bih_reports_case_due"
    t.index ["decidim_organization_id", "review_pending_since"], name: "idx_bih_reports_review_pending"
    t.index ["decidim_organization_id", "status", "category", "created_at", "id"], name: "idx_bih_reports_org_status_category_created", order: { created_at: :desc, id: :desc }
    t.index ["decidim_organization_id", "status", "forwarding_failed_at"], name: "idx_bih_reports_forwarding_failures"
    t.index ["decidim_organization_id", "status_token"], name: "idx_bih_reports_org_status_token", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_bih_reports_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "index_decidim_bih_reports_on_decidim_user_id"
    t.index ["removed_from_public_at"], name: "index_decidim_bih_reports_on_removed_from_public_at"
    t.index ["report_collection_id"], name: "idx_bih_reports_collection"
    t.index ["status"], name: "index_decidim_bih_reports_on_status"
  end

  create_table "decidim_bih_settings", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "namespace", null: false
    t.string "key", null: false
    t.jsonb "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "namespace", "key"], name: "idx_bih_settings_org_ns_key", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_settings_org"
  end

  create_table "decidim_bih_viber_business_contacts", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "phone", null: false
    t.datetime "verified_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id"], name: "idx_bih_viber_business_contacts_on_org_and_user", unique: true
    t.index ["decidim_organization_id", "verified_at"], name: "idx_bih_viber_business_contacts_on_org_and_verified"
  end

  create_table "decidim_bih_viber_inbound_deliveries", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "provider_message_key", null: false
    t.string "sender_digest"
    t.text "encrypted_payload"
    t.string "state", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.string "error_class"
    t.datetime "received_at", null: false
    t.datetime "processed_at"
    t.datetime "expires_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "channel", default: "viber", null: false
    t.string "phase", default: "handler", null: false
    t.text "encrypted_effects"
    t.integer "effects_cursor", default: 0, null: false
    t.integer "effects_count", default: 0, null: false
    t.datetime "next_effect_scrub_at"
    t.index ["decidim_organization_id", "channel", "provider_message_key"], name: "idx_bih_viber_inbound_org_message", unique: true
    t.index ["decidim_organization_id", "channel", "sender_digest", "received_at", "id"], name: "idx_bih_inbound_sender_order"
    t.index ["decidim_organization_id"], name: "idx_bih_viber_inbound_on_org"
    t.index ["expires_at"], name: "idx_bih_viber_inbound_expires"
    t.index ["phase", "next_effect_scrub_at"], name: "idx_bih_inbound_effect_scrub"
    t.index ["state", "received_at"], name: "idx_bih_viber_inbound_state_received"
    t.check_constraint "effects_cursor >= 0 AND effects_count >= 0 AND effects_cursor <= effects_count", name: "chk_bih_inbound_effect_cursor"
    t.check_constraint "phase::text = ANY (ARRAY['handler'::character varying::text, 'effects'::character varying::text, 'complete'::character varying::text])", name: "chk_bih_inbound_delivery_phase"
  end

  create_table "decidim_bih_viber_linkages", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "viber_sender", null: false
    t.string "phone"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "decidim_user_id"
    t.index ["decidim_organization_id", "viber_sender"], name: "idx_bih_viber_linkages_on_org_and_sender", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_bih_viber_linkages_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "index_decidim_bih_viber_linkages_on_decidim_user_id"
  end

  create_table "decidim_bih_volunteer_attendances", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_volunteer_opportunity_id", null: false
    t.bigint "decidim_bih_volunteer_signup_id", null: false
    t.bigint "decidim_user_id", null: false
    t.date "work_date", null: false
    t.string "status", null: false
    t.datetime "confirmed_at", null: false
    t.bigint "confirmed_by_id", null: false
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirmed_by_id"], name: "idx_bih_attendance_confirmer"
    t.index ["decidim_bih_volunteer_opportunity_id", "decidim_user_id", "work_date"], name: "idx_bih_attendance_day_unique", unique: true
    t.index ["decidim_bih_volunteer_opportunity_id"], name: "idx_bih_attendance_opportunity"
    t.index ["decidim_bih_volunteer_signup_id"], name: "idx_bih_attendance_signup"
    t.index ["decidim_organization_id"], name: "idx_bih_attendance_org"
    t.index ["decidim_user_id"], name: "idx_bih_attendance_user"
    t.check_constraint "source::text = ANY (ARRAY['operator'::character varying, 'qr'::character varying]::text[])", name: "bih_volunteer_attendance_source_valid"
    t.check_constraint "status::text = ANY (ARRAY['confirmed'::character varying, 'absent'::character varying]::text[])", name: "bih_volunteer_attendance_status_valid"
  end

  create_table "decidim_bih_volunteer_availabilities", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.text "availability"
    t.text "interests"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "area_scope", default: "city", null: false
    t.bigint "local_area_id"
    t.jsonb "availability_windows", default: [], null: false
    t.jsonb "interest_keys", default: [], null: false
    t.jsonb "skill_keys", default: [], null: false
    t.jsonb "capability_keys", default: [], null: false
    t.jsonb "day_keys", default: [], null: false
    t.jsonb "month_keys", default: [], null: false
    t.jsonb "time_slot_keys", default: [], null: false
    t.index ["decidim_organization_id", "decidim_user_id"], name: "idx_bih_volunteer_avails_on_org_and_user", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_volunteer_avails_on_org"
    t.index ["decidim_user_id"], name: "idx_bih_volunteer_avails_on_user"
    t.index ["local_area_id"], name: "idx_bih_volunteer_avails_on_area"
  end

  create_table "decidim_bih_volunteer_bonus_commitments", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "volunteer_log_id", null: false
    t.bigint "volunteer_opportunity_id", null: false
    t.bigint "decidim_user_id", null: false
    t.integer "requested_points", null: false
    t.integer "paid_points", default: 0, null: false
    t.integer "installments", default: 0, null: false
    t.string "status", default: "payable", null: false
    t.datetime "last_attempt_at"
    t.jsonb "events", default: [], null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "volunteer_opportunity_id"], name: "idx_bih_bonus_commitment_opportunity"
    t.index ["volunteer_log_id"], name: "idx_bih_bonus_commitment_log", unique: true
    t.check_constraint "requested_points >= 0 AND paid_points >= 0 AND paid_points <= requested_points AND installments >= 0", name: "bih_bonus_commitment_amounts"
  end

  create_table "decidim_bih_volunteer_daily_awards", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.date "work_date", null: false
    t.boolean "active", default: true, null: false
    t.integer "version", default: 1, null: false
    t.bigint "transaction_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "decidim_user_id", "work_date"], name: "idx_bih_volunteer_daily_awards_unique", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_volunteer_daily_awards_org"
    t.index ["decidim_user_id"], name: "idx_bih_volunteer_daily_awards_user"
  end

  create_table "decidim_bih_volunteer_logs", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_volunteer_opportunity_id", null: false
    t.bigint "decidim_user_id", null: false
    t.decimal "hours", precision: 6, scale: 2, null: false
    t.string "status", default: "pending", null: false
    t.bigint "verified_by_id"
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "rejection_reason"
    t.date "work_date"
    t.datetime "worked_from_at"
    t.datetime "worked_until_at"
    t.index ["decidim_bih_volunteer_opportunity_id"], name: "idx_bih_volunteer_logs_on_opportunity"
    t.index ["decidim_organization_id", "decidim_user_id", "created_at", "id"], name: "idx_bih_volunteer_logs_org_user_created", order: { created_at: :desc, id: :desc }
    t.index ["decidim_organization_id", "decidim_user_id", "work_date"], name: "idx_bih_volunteer_logs_on_user_work_date"
    t.index ["decidim_organization_id", "status", "created_at", "id"], name: "idx_bih_volunteer_logs_org_status_created"
    t.index ["decidim_organization_id", "status"], name: "idx_bih_volunteer_logs_on_org_and_status"
    t.index ["decidim_organization_id"], name: "index_decidim_bih_volunteer_logs_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "idx_bih_volunteer_logs_on_user"
    t.index ["verified_by_id"], name: "idx_bih_volunteer_logs_on_verifier"
    t.check_constraint "worked_from_at IS NULL AND worked_until_at IS NULL OR work_date IS NOT NULL AND worked_from_at IS NOT NULL AND worked_until_at IS NOT NULL AND worked_until_at > worked_from_at", name: "chk_bih_volunteer_log_interval"
  end

  create_table "decidim_bih_volunteer_opportunities", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "title", null: false
    t.text "description"
    t.boolean "active", default: true, null: false
    t.bigint "decidim_author_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "starts_at"
    t.string "location"
    t.string "category"
    t.integer "capacity"
    t.string "review_status", default: "approved", null: false
    t.bigint "reviewed_by_id"
    t.datetime "reviewed_at"
    t.text "rejection_reason"
    t.string "series_key"
    t.integer "series_position"
    t.integer "series_total"
    t.string "partner_name"
    t.datetime "partner_confirmed_at"
    t.bigint "partner_confirmed_by_id"
    t.bigint "komsiluk_id"
    t.string "meeting_point"
    t.datetime "ends_at"
    t.datetime "signup_deadline_at"
    t.text "requirements"
    t.jsonb "skill_keys", default: [], null: false
    t.jsonb "capability_keys", default: [], null: false
    t.jsonb "day_keys", default: [], null: false
    t.jsonb "month_keys", default: [], null: false
    t.jsonb "time_slot_keys", default: [], null: false
    t.bigint "partner_profile_id"
    t.string "opportunity_kind", default: "volunteer", null: false
    t.integer "org_bonus_points_per_hour", default: 0, null: false
    t.integer "org_bonus_budget_cap"
    t.integer "org_bonus_max_participants"
    t.integer "org_bonus_awarded_points", default: 0, null: false
    t.string "org_bonus_recognition"
    t.datetime "cancelled_at"
    t.text "cancellation_reason"
    t.bigint "cancelled_by_id"
    t.bigint "decidim_budgets_project_id"
    t.datetime "applications_paused_at"
    t.string "proposal_identity"
    t.index ["cancelled_by_id"], name: "idx_bih_volunteer_opps_cancelled_by"
    t.index ["decidim_author_id"], name: "idx_bih_volunteer_opps_on_author"
    t.index ["decidim_budgets_project_id"], name: "idx_bih_volunteer_opportunities_project"
    t.index ["decidim_organization_id", "active", "created_at", "id"], name: "idx_bih_volunteer_opps_org_active_created", order: { created_at: :desc, id: :desc }
    t.index ["decidim_organization_id", "active"], name: "idx_bih_volunteer_opps_on_org_and_active"
    t.index ["decidim_organization_id", "cancelled_at"], name: "idx_bih_volunteer_opps_org_cancelled"
    t.index ["decidim_organization_id", "category", "starts_at"], name: "idx_bih_volunteer_opps_org_category_start"
    t.index ["decidim_organization_id", "created_at", "id"], name: "idx_bih_volunteer_opps_org_pending_review", where: "((active = false) AND ((review_status)::text = 'pending'::text))"
    t.index ["decidim_organization_id", "komsiluk_id"], name: "idx_bih_volunteer_opps_org_komsiluk"
    t.index ["decidim_organization_id", "opportunity_kind"], name: "idx_bih_volunteer_opps_org_kind"
    t.index ["decidim_organization_id", "review_status"], name: "idx_bih_volunteer_opps_on_org_and_review_status"
    t.index ["decidim_organization_id", "series_key"], name: "idx_bih_volunteer_opps_on_org_and_series"
    t.index ["decidim_organization_id"], name: "idx_on_decidim_organization_id_baa6d9b3b3"
    t.index ["komsiluk_id"], name: "idx_bih_volunteer_opps_on_komsiluk"
    t.index ["partner_confirmed_by_id"], name: "idx_bih_volunteer_opps_on_partner_confirmer"
    t.index ["partner_profile_id"], name: "idx_bih_volunteer_opps_partner_profile"
    t.index ["reviewed_by_id"], name: "idx_bih_volunteer_opps_on_reviewer"
  end

  create_table "decidim_bih_volunteer_proposal_awards", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "proposal_identity", null: false
    t.bigint "first_opportunity_id", null: false
    t.bigint "legacy_transaction_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "proposal_identity"], name: "idx_bih_volunteer_proposal_awards_unique", unique: true
    t.index ["decidim_organization_id"], name: "idx_bih_volunteer_proposal_awards_org"
  end

  create_table "decidim_bih_volunteer_signups", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_bih_volunteer_opportunity_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "attendance_confirmed_at"
    t.string "attendance_source"
    t.bigint "attendance_confirmed_by_id"
    t.string "review_status", default: "pending", null: false
    t.string "review_source", default: "application", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.text "decision_reason"
    t.datetime "queued_at"
    t.datetime "first_session_at"
    t.datetime "participation_ended_at"
    t.index ["attendance_confirmed_by_id"], name: "idx_bih_volunteer_signups_attendance_by"
    t.index ["decidim_bih_volunteer_opportunity_id", "decidim_user_id"], name: "idx_bih_volunteer_signups_on_opportunity_and_user", unique: true
    t.index ["decidim_bih_volunteer_opportunity_id", "review_status", "status", "queued_at", "id"], name: "idx_bih_signup_review_queue"
    t.index ["decidim_bih_volunteer_opportunity_id"], name: "idx_bih_volunteer_signups_on_opportunity"
    t.index ["decidim_organization_id", "attendance_confirmed_at"], name: "idx_bih_volunteer_signups_org_attended"
    t.index ["decidim_organization_id"], name: "idx_bih_volunteer_signups_on_org"
    t.index ["decidim_user_id"], name: "idx_bih_volunteer_signups_on_user"
    t.index ["reviewed_by_id"], name: "idx_bih_signup_reviewer"
    t.check_constraint "((review_status::text <> ALL (ARRAY['rejected'::character varying, 'closed'::character varying]::text[])) OR status::text = 'cancelled'::text) AND (status::text <> 'pending'::text OR review_status::text = 'pending'::text) AND ((status::text <> ALL (ARRAY['going'::character varying, 'waitlisted'::character varying]::text[])) OR (review_status::text = ANY (ARRAY['approved'::character varying, 'automatic'::character varying]::text[])) OR review_status::text = 'pending'::text AND review_source::text = 'legacy_auto'::text)", name: "bih_volunteer_signup_review_allocation_valid"
    t.check_constraint "(status::text = 'cancelled'::text) = (participation_ended_at IS NOT NULL)", name: "bih_volunteer_signup_end_time_valid"
    t.check_constraint "review_source::text = ANY (ARRAY['application'::character varying, 'admin'::character varying, 'automatic'::character varying, 'legacy_auto'::character varying, 'system'::character varying]::text[])", name: "bih_volunteer_signup_source_valid"
    t.check_constraint "review_status::text <> 'approved'::text OR reviewed_at IS NOT NULL AND reviewed_by_id IS NOT NULL", name: "bih_volunteer_signup_reviewer_valid"
    t.check_constraint "review_status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'automatic'::character varying, 'rejected'::character varying, 'closed'::character varying]::text[])", name: "bih_volunteer_signup_review_valid"
    t.check_constraint "status::text <> 'waitlisted'::text OR queued_at IS NOT NULL", name: "bih_volunteer_signup_queue_time_valid"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'going'::character varying, 'waitlisted'::character varying, 'cancelled'::character varying]::text[])", name: "bih_volunteer_signup_status_valid"
  end

  create_table "decidim_blogs_posts", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "body"
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "decidim_author_id", null: false
    t.string "decidim_author_type", null: false
    t.integer "likes_count", default: 0, null: false
    t.integer "comments_count", default: 0, null: false
    t.integer "follows_count", default: 0, null: false
    t.datetime "published_at", precision: nil
    t.datetime "deleted_at"
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_blogs_posts_on_decidim_author"
    t.index ["decidim_component_id"], name: "index_decidim_blogs_posts_on_decidim_component_id"
    t.index ["deleted_at"], name: "index_decidim_blogs_posts_on_deleted_at"
  end

  create_table "decidim_budgets_budgets", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.integer "weight", default: 0, null: false
    t.jsonb "description"
    t.bigint "total_budget", default: 0
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "decidim_scope_id"
    t.datetime "deleted_at"
    t.index ["decidim_component_id"], name: "index_decidim_budgets_budgets_on_decidim_component_id"
    t.index ["decidim_scope_id"], name: "index_decidim_budgets_budgets_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_budgets_budgets_on_deleted_at"
  end

  create_table "decidim_budgets_line_items", id: :serial, force: :cascade do |t|
    t.integer "decidim_order_id"
    t.integer "decidim_project_id"
    t.index ["decidim_order_id", "decidim_project_id"], name: "decidim_budgets_line_items_order_project_unique", unique: true
    t.index ["decidim_order_id"], name: "index_decidim_budgets_line_items_on_decidim_order_id"
    t.index ["decidim_project_id"], name: "index_decidim_budgets_line_items_on_decidim_project_id"
  end

  create_table "decidim_budgets_orders", id: :serial, force: :cascade do |t|
    t.integer "decidim_user_id"
    t.datetime "checked_out_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "decidim_budgets_budget_id"
    t.index ["decidim_budgets_budget_id"], name: "index_decidim_budgets_orders_on_decidim_budgets_budget_id"
    t.index ["decidim_user_id"], name: "index_decidim_budgets_orders_on_decidim_user_id"
  end

  create_table "decidim_budgets_projects", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.bigint "budget_amount", null: false
    t.integer "decidim_scope_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "reference"
    t.bigint "decidim_budgets_budget_id"
    t.date "selected_at"
    t.integer "comments_count", default: 0, null: false
    t.integer "follows_count", default: 0, null: false
    t.text "address"
    t.float "latitude"
    t.float "longitude"
    t.datetime "deleted_at"
    t.index ["decidim_budgets_budget_id"], name: "index_decidim_budgets_projects_on_decidim_budgets_budget_id"
    t.index ["decidim_scope_id"], name: "index_decidim_budgets_projects_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_budgets_projects_on_deleted_at"
  end

  create_table "decidim_categories", id: :serial, force: :cascade do |t|
    t.jsonb "name", null: false
    t.jsonb "description"
    t.integer "parent_id"
    t.integer "decidim_participatory_space_id"
    t.string "decidim_participatory_space_type"
    t.integer "weight", default: 0, null: false
    t.index ["decidim_participatory_space_id", "decidim_participatory_space_type"], name: "index_decidim_categories_on_decidim_participatory_space"
    t.index ["parent_id"], name: "index_decidim_categories_on_parent_id"
  end

  create_table "decidim_categorizations", force: :cascade do |t|
    t.bigint "decidim_category_id", null: false
    t.string "categorizable_type", null: false
    t.bigint "categorizable_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["categorizable_type", "categorizable_id"], name: "decidim_categorizations_categorizable_id_and_type"
    t.index ["decidim_category_id"], name: "index_decidim_categorizations_on_decidim_category_id"
  end

  create_table "decidim_coauthorships", force: :cascade do |t|
    t.bigint "decidim_author_id", null: false
    t.string "coauthorable_type"
    t.bigint "coauthorable_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "decidim_author_type", null: false
    t.index ["coauthorable_type", "coauthorable_id"], name: "index_coauthorable_on_coauthorship"
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_coauthorships_on_decidim_author"
  end

  create_table "decidim_comments_comment_votes", id: :serial, force: :cascade do |t|
    t.integer "weight", null: false
    t.integer "decidim_comment_id", null: false
    t.integer "decidim_author_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "decidim_author_type", null: false
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_comments_comment_votes_on_decidim_author"
    t.index ["decidim_author_id"], name: "decidim_comments_comment_vote_author"
    t.index ["decidim_comment_id", "decidim_author_id"], name: "decidim_comments_comment_vote_comment_author_unique", unique: true
    t.index ["decidim_comment_id"], name: "decidim_comments_comment_vote_comment"
  end

  create_table "decidim_comments_comments", id: :serial, force: :cascade do |t|
    t.string "decidim_commentable_type", null: false
    t.integer "decidim_commentable_id", null: false
    t.integer "decidim_author_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "depth", default: 0, null: false
    t.integer "alignment", default: 0, null: false
    t.string "decidim_root_commentable_type", null: false
    t.integer "decidim_root_commentable_id", null: false
    t.string "decidim_author_type", null: false
    t.jsonb "body"
    t.integer "comments_count", default: 0, null: false
    t.string "decidim_participatory_space_type"
    t.integer "decidim_participatory_space_id"
    t.datetime "deleted_at", precision: nil
    t.integer "up_votes_count", default: 0, null: false
    t.integer "down_votes_count", default: 0, null: false
    t.index ["created_at"], name: "index_decidim_comments_comments_on_created_at"
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_comments_comments_on_decidim_author"
    t.index ["decidim_author_id"], name: "decidim_comments_comment_author"
    t.index ["decidim_commentable_type", "decidim_commentable_id"], name: "decidim_comments_comment_commentable"
    t.index ["decidim_participatory_space_id", "decidim_participatory_space_type"], name: "index_decidim_comments_on_decidim_participatory_space"
    t.index ["decidim_root_commentable_type", "decidim_root_commentable_id"], name: "decidim_comments_comment_root_commentable"
  end

  create_table "decidim_components", id: :serial, force: :cascade do |t|
    t.string "manifest_name"
    t.jsonb "name"
    t.integer "participatory_space_id", null: false
    t.jsonb "settings", default: {}
    t.integer "weight", default: 0
    t.jsonb "permissions"
    t.datetime "published_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "visible", default: true
    t.datetime "deleted_at"
    t.string "participatory_space_type", null: false
    t.index ["deleted_at"], name: "index_decidim_components_on_deleted_at"
    t.index ["participatory_space_id", "participatory_space_type"], name: "index_decidim_components_on_decidim_participatory_space"
  end

  create_table "decidim_content_block_attachments", force: :cascade do |t|
    t.string "name"
    t.bigint "decidim_content_block_id", null: false
    t.index ["decidim_content_block_id"], name: "decidim_content_block_attachments_on_content_block"
  end

  create_table "decidim_content_blocks", force: :cascade do |t|
    t.integer "decidim_organization_id", null: false
    t.string "manifest_name", null: false
    t.string "scope_name", null: false
    t.jsonb "settings"
    t.datetime "published_at", precision: nil
    t.integer "weight"
    t.jsonb "images", default: {}
    t.integer "scoped_resource_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "scope_name", "scoped_resource_id", "manifest_name"], name: "idx_decidim_content_blocks_org_id_scope_scope_id_manifest"
    t.index ["decidim_organization_id"], name: "index_decidim_content_blocks_on_decidim_organization_id"
    t.index ["manifest_name"], name: "index_decidim_content_blocks_on_manifest_name"
    t.index ["published_at"], name: "index_decidim_content_blocks_on_published_at"
    t.index ["scope_name"], name: "index_decidim_content_blocks_on_scope_name"
  end

  create_table "decidim_contextual_help_sections", force: :cascade do |t|
    t.string "section_id", null: false
    t.bigint "organization_id", null: false
    t.jsonb "content", null: false
    t.index ["organization_id"], name: "index_decidim_contextual_help_sections_on_organization_id"
    t.index ["section_id"], name: "index_decidim_contextual_help_sections_on_section_id"
  end

  create_table "decidim_debates_debates", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.jsonb "instructions"
    t.datetime "start_time", precision: nil
    t.datetime "end_time", precision: nil
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "information_updates"
    t.integer "decidim_author_id", null: false
    t.string "reference"
    t.string "decidim_author_type", null: false
    t.datetime "closed_at", precision: nil
    t.jsonb "conclusions"
    t.integer "likes_count", default: 0, null: false
    t.integer "comments_count", default: 0, null: false
    t.datetime "last_comment_at", precision: nil
    t.integer "last_comment_by_id"
    t.string "last_comment_by_type"
    t.bigint "decidim_scope_id"
    t.integer "follows_count", default: 0, null: false
    t.boolean "comments_enabled", default: true
    t.datetime "deleted_at"
    t.string "comments_layout"
    t.index ["closed_at"], name: "index_decidim_debates_debates_on_closed_at"
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_debates_debates_on_decidim_author"
    t.index ["decidim_component_id"], name: "index_decidim_debates_debates_on_decidim_component_id"
    t.index ["decidim_scope_id"], name: "index_decidim_debates_debates_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_debates_debates_on_deleted_at"
    t.index ["likes_count"], name: "index_decidim_debates_debates_on_likes_count"
  end

  create_table "decidim_editor_images", force: :cascade do |t|
    t.bigint "decidim_author_id", null: false
    t.bigint "decidim_organization_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_author_id"], name: "decidim_editor_images_author"
    t.index ["decidim_organization_id"], name: "decidim_editor_images_constraint_organization"
  end

  create_table "decidim_follows", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.string "decidim_followable_type"
    t.bigint "decidim_followable_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_followable_id", "decidim_followable_type"], name: "index_follows_followable_id_and_type"
    t.index ["decidim_user_id", "decidim_followable_id", "decidim_followable_type"], name: "index_uniq_on_follows_user_and_followable", unique: true
    t.index ["decidim_user_id"], name: "index_decidim_follows_on_decidim_user_id"
  end

  create_table "decidim_forms_display_conditions", force: :cascade do |t|
    t.bigint "decidim_question_id", null: false
    t.bigint "decidim_condition_question_id", null: false
    t.bigint "decidim_response_option_id"
    t.integer "condition_type", default: 0, null: false
    t.jsonb "condition_value"
    t.boolean "mandatory", default: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_condition_question_id"], name: "decidim_forms_display_condition_condition_question"
    t.index ["decidim_question_id"], name: "decidim_forms_display_condition_question"
    t.index ["decidim_response_option_id"], name: "decidim_forms_display_condition_response_option"
  end

  create_table "decidim_forms_question_matrix_rows", force: :cascade do |t|
    t.bigint "decidim_question_id"
    t.integer "position"
    t.jsonb "body"
    t.index ["decidim_question_id"], name: "index_decidim_forms_question_matrix_questionnaire_id"
    t.index ["position"], name: "index_decidim_forms_question_matrix_rows_on_position"
  end

  create_table "decidim_forms_questionnaires", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.jsonb "tos"
    t.string "questionnaire_for_type"
    t.integer "questionnaire_for_id"
    t.datetime "published_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "salt"
    t.index ["questionnaire_for_type", "questionnaire_for_id"], name: "index_decidim_forms_questionnaires_questionnaire_for"
  end

  create_table "decidim_forms_questions", id: :serial, force: :cascade do |t|
    t.integer "decidim_questionnaire_id"
    t.integer "position"
    t.string "question_type"
    t.boolean "mandatory"
    t.jsonb "body"
    t.jsonb "description"
    t.integer "max_choices"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "max_characters", default: 0
    t.integer "response_options_count", default: 0, null: false
    t.integer "matrix_rows_count", default: 0, null: false
    t.integer "display_conditions_count", default: 0, null: false
    t.integer "display_conditions_for_other_questions_count", default: 0, null: false
    t.datetime "survey_responses_published_at"
    t.index ["decidim_questionnaire_id"], name: "index_decidim_forms_questions_on_decidim_questionnaire_id"
    t.index ["position"], name: "index_decidim_forms_questions_on_position"
  end

  create_table "decidim_forms_response_choices", force: :cascade do |t|
    t.bigint "decidim_response_id"
    t.bigint "decidim_response_option_id"
    t.integer "position"
    t.jsonb "body"
    t.text "custom_body"
    t.integer "decidim_question_matrix_row_id"
    t.index ["decidim_response_id"], name: "index_decidim_forms_response_choices_response_id"
    t.index ["decidim_response_option_id"], name: "index_decidim_forms_response_choices_response_option_id"
  end

  create_table "decidim_forms_response_options", force: :cascade do |t|
    t.bigint "decidim_question_id"
    t.jsonb "body"
    t.boolean "free_text"
    t.index ["decidim_question_id"], name: "index_decidim_forms_response_options_question_id"
  end

  create_table "decidim_forms_responses", id: :serial, force: :cascade do |t|
    t.text "body"
    t.integer "decidim_user_id"
    t.integer "decidim_questionnaire_id"
    t.integer "decidim_question_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "session_token", default: "", null: false
    t.string "ip_hash"
    t.index ["decidim_question_id"], name: "index_decidim_forms_responses_question_id"
    t.index ["decidim_questionnaire_id"], name: "index_decidim_forms_responses_on_decidim_questionnaire_id"
    t.index ["decidim_user_id"], name: "index_decidim_forms_responses_on_decidim_user_id"
    t.index ["ip_hash"], name: "index_decidim_forms_responses_on_ip_hash"
    t.index ["session_token"], name: "index_decidim_forms_responses_on_session_token"
  end

  create_table "decidim_gamification_badge_scores", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "badge_name", null: false
    t.integer "value", default: 0, null: false
    t.index ["user_id"], name: "index_decidim_gamification_badge_scores_on_user_id"
  end

  create_table "decidim_identities", id: :serial, force: :cascade do |t|
    t.string "provider", null: false
    t.string "uid", null: false
    t.integer "decidim_user_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "decidim_organization_id"
    t.index ["decidim_organization_id"], name: "index_decidim_identities_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "index_decidim_identities_on_decidim_user_id"
    t.index ["provider", "uid", "decidim_organization_id"], name: "decidim_identities_provider_uid_organization_unique", unique: true
  end

  create_table "decidim_impersonation_logs", force: :cascade do |t|
    t.bigint "decidim_admin_id"
    t.bigint "decidim_user_id"
    t.datetime "started_at", precision: nil
    t.datetime "ended_at", precision: nil
    t.datetime "expired_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.text "reason"
    t.index ["decidim_admin_id"], name: "index_decidim_impersonation_logs_on_decidim_admin_id"
    t.index ["decidim_user_id"], name: "index_decidim_impersonation_logs_on_decidim_user_id"
  end

  create_table "decidim_likes", force: :cascade do |t|
    t.string "resource_type"
    t.bigint "resource_id"
    t.string "decidim_author_type"
    t.bigint "decidim_author_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_author_type", "decidim_author_id"], name: "idx_likes_authors"
    t.index ["resource_type", "resource_id"], name: "index_decidim_likes_on_resource_type_and_resource_id"
  end

  create_table "decidim_meetings_agenda_items", force: :cascade do |t|
    t.bigint "decidim_agenda_id"
    t.integer "position"
    t.bigint "parent_id"
    t.integer "duration"
    t.jsonb "title"
    t.jsonb "description"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_agenda_id"], name: "index_decidim_meetings_agenda_items_on_decidim_agenda_id"
    t.index ["parent_id"], name: "index_decidim_meetings_agenda_items_on_parent_id"
  end

  create_table "decidim_meetings_agendas", force: :cascade do |t|
    t.jsonb "title"
    t.bigint "decidim_meeting_id", null: false
    t.boolean "visible"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_agendas_on_decidim_meeting_id"
  end

  create_table "decidim_meetings_invites", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.bigint "decidim_meeting_id", null: false
    t.datetime "sent_at", precision: nil
    t.datetime "accepted_at", precision: nil
    t.datetime "rejected_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_invites_on_decidim_meeting_id"
    t.index ["decidim_user_id"], name: "index_decidim_meetings_invites_on_decidim_user_id"
  end

  create_table "decidim_meetings_meeting_links", force: :cascade do |t|
    t.bigint "decidim_component_id", null: false
    t.bigint "decidim_meeting_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_component_id"], name: "index_decidim_meetings_meeting_links_on_decidim_component_id"
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_meeting_links_on_decidim_meeting_id"
  end

  create_table "decidim_meetings_meetings", id: :serial, force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.datetime "start_time", precision: nil
    t.datetime "end_time", precision: nil
    t.text "address"
    t.jsonb "location"
    t.jsonb "location_hints"
    t.integer "decidim_component_id"
    t.integer "decidim_author_id"
    t.integer "decidim_scope_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "closing_report"
    t.integer "attendees_count"
    t.integer "contributions_count"
    t.text "attending_organizations"
    t.time "closed_at"
    t.float "latitude"
    t.float "longitude"
    t.string "reference"
    t.boolean "registrations_enabled", default: false, null: false
    t.integer "available_slots", default: 0, null: false
    t.jsonb "registration_terms"
    t.integer "reserved_slots", default: 0, null: false
    t.boolean "private_meeting", default: false
    t.boolean "transparent", default: true
    t.boolean "registration_form_enabled", default: false
    t.string "decidim_author_type"
    t.integer "comments_count", default: 0, null: false
    t.string "online_meeting_url"
    t.string "registration_url"
    t.string "salt"
    t.boolean "customize_registration_email", default: false
    t.jsonb "registration_email_custom_content"
    t.integer "follows_count", default: 0, null: false
    t.datetime "published_at", precision: nil
    t.string "video_url"
    t.string "audio_url"
    t.boolean "closing_visible"
    t.boolean "comments_enabled", default: true
    t.datetime "comments_start_time", precision: nil
    t.datetime "comments_end_time", precision: nil
    t.string "state"
    t.integer "iframe_access_level", default: 0
    t.integer "iframe_embed_type", default: 0
    t.integer "type_of_meeting", default: 0, null: false
    t.integer "registration_type", default: 0, null: false
    t.datetime "withdrawn_at", precision: nil
    t.datetime "deleted_at"
    t.boolean "reminder_enabled", default: true, null: false
    t.integer "send_reminders_before_hours"
    t.jsonb "reminder_message_custom_content", default: {}, null: false
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_meetings_meetings_on_author"
    t.index ["decidim_author_id"], name: "index_decidim_meetings_meetings_on_decidim_author_id"
    t.index ["decidim_component_id"], name: "index_decidim_meetings_meetings_on_decidim_component_id"
    t.index ["decidim_scope_id"], name: "index_decidim_meetings_meetings_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_meetings_meetings_on_deleted_at"
  end

  create_table "decidim_meetings_polls", force: :cascade do |t|
    t.bigint "decidim_meeting_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_polls_on_decidim_meeting_id"
  end

  create_table "decidim_meetings_questionnaires", force: :cascade do |t|
    t.string "questionnaire_for_type"
    t.bigint "questionnaire_for_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["questionnaire_for_type", "questionnaire_for_id"], name: "index_decidim_meetings_questionnaires_questionnaire_for"
  end

  create_table "decidim_meetings_questions", force: :cascade do |t|
    t.bigint "decidim_questionnaire_id"
    t.integer "position"
    t.string "question_type"
    t.jsonb "body"
    t.integer "max_choices"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "status", default: 0
    t.index ["decidim_questionnaire_id"], name: "index_decidim_meetings_questions_on_decidim_questionnaire_id"
    t.index ["position"], name: "index_decidim_meetings_questions_on_position"
  end

  create_table "decidim_meetings_registrations", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.bigint "decidim_meeting_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "code"
    t.datetime "validated_at", precision: nil
    t.boolean "public_participation", default: false
    t.string "status", default: "registered"
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_registrations_on_decidim_meeting_id"
    t.index ["decidim_user_id", "decidim_meeting_id"], name: "decidim_meetings_registrations_user_meeting_unique", unique: true
    t.index ["decidim_user_id"], name: "index_decidim_meetings_registrations_on_decidim_user_id"
    t.index ["status"], name: "index_decidim_meetings_registrations_on_status"
  end

  create_table "decidim_meetings_response_choices", force: :cascade do |t|
    t.bigint "decidim_response_id"
    t.bigint "decidim_response_option_id"
    t.integer "position"
    t.jsonb "body"
    t.text "custom_body"
    t.index ["decidim_response_id"], name: "index_decidim_meetings_response_choices_response_id"
    t.index ["decidim_response_option_id"], name: "index_decidim_meetings_response_choices_response_option_id"
  end

  create_table "decidim_meetings_response_options", force: :cascade do |t|
    t.bigint "decidim_question_id"
    t.jsonb "body"
    t.index ["decidim_question_id"], name: "index_decidim_meetings_response_options_question_id"
  end

  create_table "decidim_meetings_responses", force: :cascade do |t|
    t.bigint "decidim_user_id"
    t.bigint "decidim_questionnaire_id"
    t.bigint "decidim_question_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_question_id"], name: "index_decidim_meetings_responses_question_id"
    t.index ["decidim_questionnaire_id"], name: "index_decidim_meetings_responses_on_decidim_questionnaire_id"
    t.index ["decidim_user_id"], name: "index_decidim_meetings_responses_on_decidim_user_id"
  end

  create_table "decidim_meetings_services", force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.bigint "decidim_meeting_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_meeting_id"], name: "index_decidim_meetings_services_on_decidim_meeting_id"
  end

  create_table "decidim_members", force: :cascade do |t|
    t.bigint "decidim_user_id"
    t.integer "participatory_space_id"
    t.string "participatory_space_type"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "role"
    t.boolean "published", default: false
    t.index ["decidim_user_id", "participatory_space_type", "participatory_space_id"], name: "unique_space_members", unique: true
    t.index ["decidim_user_id"], name: "index_decidim_members_on_user_id"
    t.index ["participatory_space_type", "participatory_space_id"], name: "index_decidim_members_on_participatory_space"
  end

  create_table "decidim_messaging_conversations", force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "decidim_messaging_messages", force: :cascade do |t|
    t.bigint "decidim_conversation_id", null: false
    t.bigint "decidim_sender_id", null: false
    t.text "body", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_conversation_id"], name: "index_decidim_messaging_messages_on_decidim_conversation_id"
    t.index ["decidim_sender_id"], name: "index_decidim_messaging_messages_on_decidim_sender_id"
  end

  create_table "decidim_messaging_participations", force: :cascade do |t|
    t.bigint "decidim_conversation_id", null: false
    t.bigint "decidim_participant_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_conversation_id"], name: "index_conversation_participations_on_conversation_id"
    t.index ["decidim_participant_id"], name: "index_conversation_participations_on_participant_id"
  end

  create_table "decidim_messaging_receipts", force: :cascade do |t|
    t.bigint "decidim_message_id", null: false
    t.bigint "decidim_recipient_id", null: false
    t.datetime "read_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_message_id"], name: "index_decidim_messaging_receipts_on_decidim_message_id"
    t.index ["decidim_recipient_id"], name: "index_decidim_messaging_receipts_on_decidim_recipient_id"
  end

  create_table "decidim_metrics", force: :cascade do |t|
    t.date "day", null: false
    t.string "metric_type", null: false
    t.integer "cumulative", null: false
    t.integer "quantity", null: false
    t.bigint "decidim_organization_id", null: false
    t.string "participatory_space_type"
    t.bigint "participatory_space_id"
    t.string "related_object_type"
    t.bigint "related_object_id"
    t.bigint "decidim_category_id"
    t.bigint "decidim_taxonomy_id"
    t.index ["day", "metric_type", "decidim_organization_id", "participatory_space_type", "participatory_space_id", "related_object_type", "related_object_id", "decidim_category_id"], name: "idx_metric_by_day_type_org_space_object_category", unique: true
    t.index ["day"], name: "index_decidim_metrics_on_day"
    t.index ["decidim_category_id"], name: "index_decidim_metrics_on_decidim_category_id"
    t.index ["decidim_organization_id"], name: "index_decidim_metrics_on_decidim_organization_id"
    t.index ["decidim_taxonomy_id"], name: "index_decidim_metrics_on_decidim_taxonomy_id"
    t.index ["metric_type"], name: "index_decidim_metrics_on_metric_type"
    t.index ["participatory_space_type", "participatory_space_id"], name: "index_metric_on_participatory_space_id_and_type"
    t.index ["related_object_type", "related_object_id"], name: "index_metric_on_related_object_id_and_type"
  end

  create_table "decidim_moderations", id: :serial, force: :cascade do |t|
    t.integer "decidim_participatory_space_id", null: false
    t.string "decidim_reportable_type", null: false
    t.integer "decidim_reportable_id", null: false
    t.integer "report_count", default: 0, null: false
    t.datetime "hidden_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "decidim_participatory_space_type", null: false
    t.text "reported_content"
    t.index ["decidim_participatory_space_id", "decidim_participatory_space_type"], name: "decidim_moderations_participatory_space"
    t.index ["decidim_reportable_type", "decidim_reportable_id"], name: "decidim_moderations_reportable", unique: true
    t.index ["hidden_at"], name: "decidim_moderations_hidden_at"
    t.index ["report_count"], name: "decidim_moderations_report_count"
  end

  create_table "decidim_newsletters", id: :serial, force: :cascade do |t|
    t.jsonb "subject"
    t.integer "organization_id"
    t.integer "author_id"
    t.integer "total_recipients"
    t.integer "total_deliveries"
    t.datetime "sent_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "extended_data", default: {}
    t.index ["author_id"], name: "index_decidim_newsletters_on_author_id"
    t.index ["organization_id"], name: "index_decidim_newsletters_on_organization_id"
  end

  create_table "decidim_notifications", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.string "decidim_resource_type", null: false
    t.bigint "decidim_resource_id", null: false
    t.string "event_name", null: false
    t.string "event_class", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "extra"
    t.index ["decidim_resource_id"], name: "index_decidim_notifications_on_decidim_resource_id"
    t.index ["decidim_user_id"], name: "index_decidim_notifications_on_decidim_user_id"
  end

  create_table "decidim_organizations", id: :serial, force: :cascade do |t|
    t.string "host", null: false
    t.string "default_locale", null: false
    t.string "available_locales", default: [], array: true
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "description"
    t.string "twitter_handler"
    t.string "instagram_handler"
    t.string "facebook_handler"
    t.string "youtube_handler"
    t.string "github_handler"
    t.string "official_url"
    t.string "reference_prefix", null: false
    t.string "secondary_hosts", default: [], array: true
    t.string "available_authorizations", default: [], array: true
    t.text "header_snippets"
    t.boolean "enable_omnipresent_banner", default: false, null: false
    t.jsonb "omnipresent_banner_title"
    t.jsonb "omnipresent_banner_short_description"
    t.string "omnipresent_banner_url"
    t.datetime "tos_version", precision: nil
    t.boolean "badges_enabled", default: false, null: false
    t.boolean "send_welcome_notification", default: false, null: false
    t.jsonb "welcome_notification_subject"
    t.jsonb "welcome_notification_body"
    t.integer "users_registration_mode", default: 0, null: false
    t.string "id_documents_methods", default: ["online"], array: true
    t.jsonb "id_documents_explanation_text", default: {}
    t.jsonb "smtp_settings"
    t.jsonb "colors", default: {}
    t.boolean "force_users_to_authenticate_before_access_organization", default: false
    t.jsonb "omniauth_settings"
    t.boolean "rich_text_editor_in_public_views", default: false
    t.jsonb "admin_terms_of_service_body"
    t.string "time_zone", limit: 255, default: "UTC"
    t.boolean "enable_machine_translations", default: false
    t.integer "comments_max_length", default: 1000
    t.jsonb "file_upload_settings"
    t.string "machine_translation_display_priority", default: "original", null: false
    t.string "external_domain_allowlist", default: [], array: true
    t.jsonb "content_security_policy", default: {}
    t.jsonb "name", default: {}, null: false
    t.jsonb "short_name", default: {}, null: false
    t.index ["host"], name: "index_decidim_organizations_on_host", unique: true
  end

  create_table "decidim_pages_pages", id: :serial, force: :cascade do |t|
    t.jsonb "body"
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "deleted_at"
    t.index ["decidim_component_id"], name: "index_decidim_pages_pages_on_decidim_component_id"
    t.index ["deleted_at"], name: "index_decidim_pages_pages_on_deleted_at"
  end

  create_table "decidim_participatory_process_groups", id: :serial, force: :cascade do |t|
    t.jsonb "title", null: false
    t.jsonb "description", null: false
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "group_url"
    t.jsonb "developer_group"
    t.jsonb "local_area"
    t.jsonb "meta_scope"
    t.jsonb "target"
    t.jsonb "participatory_scope"
    t.jsonb "participatory_structure"
    t.boolean "promoted", default: false
    t.index ["decidim_organization_id"], name: "decidim_participatory_process_group_organization"
  end

  create_table "decidim_participatory_process_steps", id: :serial, force: :cascade do |t|
    t.jsonb "title", null: false
    t.jsonb "description"
    t.datetime "start_date", precision: nil
    t.datetime "end_date", precision: nil
    t.integer "decidim_participatory_process_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "active", default: false
    t.integer "position"
    t.index ["decidim_participatory_process_id", "active"], name: "unique_index_to_avoid_duplicate_active_steps", unique: true, where: "(active = true)"
    t.index ["decidim_participatory_process_id", "position"], name: "index_unique_position_for_process", unique: true
    t.index ["decidim_participatory_process_id"], name: "index_decidim_processes_steps__on_decidim_process_id"
    t.index ["position"], name: "index_order_by_position_for_steps"
  end

  create_table "decidim_participatory_process_user_roles", id: :serial, force: :cascade do |t|
    t.integer "decidim_user_id"
    t.integer "decidim_participatory_process_id"
    t.string "role"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_participatory_process_id", "decidim_user_id", "role"], name: "index_unique_user_and_process_role", unique: true
    t.index ["decidim_user_id"], name: "idx_proces_user_role_on_user_id"
  end

  create_table "decidim_participatory_processes", id: :serial, force: :cascade do |t|
    t.string "slug", null: false
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "title", null: false
    t.jsonb "subtitle", null: false
    t.jsonb "short_description", null: false
    t.jsonb "description", null: false
    t.boolean "promoted", default: false
    t.datetime "published_at", precision: nil
    t.jsonb "developer_group"
    t.date "end_date"
    t.jsonb "meta_scope"
    t.jsonb "local_area"
    t.jsonb "target"
    t.jsonb "participatory_scope"
    t.jsonb "participatory_structure"
    t.integer "decidim_scope_id"
    t.integer "decidim_participatory_process_group_id"
    t.jsonb "announcement"
    t.boolean "scopes_enabled", default: true, null: false
    t.date "start_date"
    t.boolean "private_space", default: false
    t.string "reference"
    t.bigint "decidim_area_id"
    t.bigint "decidim_scope_type_id"
    t.integer "weight", default: 1, null: false
    t.integer "follows_count", default: 0, null: false
    t.datetime "deleted_at"
    t.boolean "has_members", default: false
    t.integer "access_mode", default: 0, null: false
    t.index ["decidim_area_id"], name: "index_decidim_participatory_processes_on_decidim_area_id"
    t.index ["decidim_organization_id", "slug"], name: "index_unique_process_slug_and_organization", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_processes_on_decidim_organization_id"
    t.index ["decidim_participatory_process_group_id"], name: "idx_process_on_process_group_id"
    t.index ["decidim_scope_id"], name: "idx_process_on_scope_id"
    t.index ["decidim_scope_type_id"], name: "index_decidim_participatory_processes_on_decidim_scope_type_id"
    t.index ["deleted_at"], name: "index_decidim_participatory_processes_on_deleted_at"
  end

  create_table "decidim_participatory_space_links", id: :serial, force: :cascade do |t|
    t.string "from_type", null: false
    t.integer "from_id", null: false
    t.string "to_type", null: false
    t.integer "to_id", null: false
    t.string "name", null: false
    t.jsonb "data"
    t.index ["from_type", "from_id"], name: "index_participatory_space_links_on_from"
    t.index ["name"], name: "index_participatory_space_links_name"
    t.index ["to_type", "to_id"], name: "index_participatory_space_links_on_to"
  end

  create_table "decidim_private_exports", force: :cascade do |t|
    t.uuid "uuid", null: false
    t.string "export_type", null: false
    t.string "attached_to_type"
    t.integer "attached_to_id"
    t.string "content_type", null: false
    t.string "file_size", null: false
    t.datetime "expires_at"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["uuid"], name: "index_decidim_private_exports_on_uuid", unique: true
  end

  create_table "decidim_proposals_evaluation_assignments", force: :cascade do |t|
    t.bigint "decidim_proposal_id", null: false
    t.string "evaluator_role_type", null: false
    t.bigint "evaluator_role_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_proposal_id"], name: "decidim_proposals_evaluation_assignment_proposal"
    t.index ["evaluator_role_type", "evaluator_role_id"], name: "decidim_proposals_evaluation_assignment_valuator_role"
  end

  create_table "decidim_proposals_participatory_texts", force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "description"
    t.bigint "decidim_component_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_component_id"], name: "idx_participatory_texts_on_decidim_component_id"
  end

  create_table "decidim_proposals_proposal_notes", force: :cascade do |t|
    t.bigint "decidim_proposal_id", null: false
    t.bigint "decidim_author_id", null: false
    t.text "body", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "parent_id"
    t.index ["created_at"], name: "index_decidim_proposals_proposal_notes_on_created_at"
    t.index ["decidim_author_id"], name: "decidim_proposals_proposal_note_author"
    t.index ["decidim_proposal_id"], name: "decidim_proposals_proposal_note_proposal"
    t.index ["parent_id"], name: "decidim_proposals_proposal_notes_on_parent_id"
  end

  create_table "decidim_proposals_proposal_states", force: :cascade do |t|
    t.jsonb "title"
    t.jsonb "announcement_title"
    t.string "token", null: false
    t.bigint "decidim_component_id", null: false
    t.integer "proposals_count", default: 0, null: false
    t.string "bg_color", default: "#F6F8FA", null: false
    t.string "text_color", default: "#4B5058", null: false
    t.index ["decidim_component_id"], name: "index_decidim_proposals_proposal_states_on_decidim_component_id"
  end

  create_table "decidim_proposals_proposal_votes", id: :serial, force: :cascade do |t|
    t.integer "decidim_proposal_id", null: false
    t.integer "decidim_author_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "temporary", default: false, null: false
    t.index ["decidim_author_id"], name: "decidim_proposals_proposal_vote_author"
    t.index ["decidim_proposal_id", "decidim_author_id"], name: "decidim_proposals_proposal_vote_proposal_author_unique", unique: true
    t.index ["decidim_proposal_id"], name: "decidim_proposals_proposal_vote_proposal"
  end

  create_table "decidim_proposals_proposals", id: :serial, force: :cascade do |t|
    t.integer "decidim_component_id", null: false
    t.integer "decidim_scope_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "proposal_votes_count", default: 0, null: false
    t.datetime "answered_at", precision: nil
    t.jsonb "answer"
    t.string "reference"
    t.text "address"
    t.float "latitude"
    t.float "longitude"
    t.datetime "published_at", precision: nil
    t.integer "proposal_notes_count", default: 0, null: false
    t.integer "coauthorships_count", default: 0, null: false
    t.string "participatory_text_level"
    t.integer "position"
    t.boolean "created_in_meeting", default: false
    t.integer "likes_count", default: 0, null: false
    t.decimal "cost"
    t.jsonb "cost_report"
    t.jsonb "execution_period"
    t.datetime "state_published_at", precision: nil
    t.jsonb "title"
    t.jsonb "body"
    t.integer "comments_count", default: 0, null: false
    t.integer "follows_count", default: 0, null: false
    t.integer "old_state", default: 0, null: false
    t.datetime "withdrawn_at", precision: nil
    t.integer "decidim_proposals_proposal_state_id"
    t.integer "evaluation_assignments_count", default: 0
    t.datetime "deleted_at"
    t.index "md5((body)::text)", name: "decidim_proposals_proposal_body_search"
    t.index "md5((title)::text)", name: "decidim_proposals_proposal_title_search"
    t.index ["created_at"], name: "index_decidim_proposals_proposals_on_created_at"
    t.index ["decidim_component_id"], name: "index_decidim_proposals_proposals_on_decidim_component_id"
    t.index ["decidim_scope_id"], name: "index_decidim_proposals_proposals_on_decidim_scope_id"
    t.index ["deleted_at"], name: "index_decidim_proposals_proposals_on_deleted_at"
    t.index ["proposal_votes_count"], name: "index_decidim_proposals_proposals_on_proposal_votes_count"
  end

  create_table "decidim_reminder_deliveries", force: :cascade do |t|
    t.bigint "decidim_reminder_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_reminder_id"], name: "index_decidim_reminder_deliveries_on_decidim_reminder_id"
  end

  create_table "decidim_reminder_records", force: :cascade do |t|
    t.string "string", default: "active"
    t.bigint "decidim_reminder_id"
    t.string "remindable_type", null: false
    t.bigint "remindable_id", null: false
    t.integer "state", default: 0, null: false
    t.index ["decidim_reminder_id"], name: "index_decidim_reminder_records_on_decidim_reminder_id"
    t.index ["remindable_type", "remindable_id"], name: "index_decidim_reminder_records_remindable"
    t.index ["string"], name: "index_decidim_reminder_records_on_string"
  end

  create_table "decidim_reminders", force: :cascade do |t|
    t.bigint "decidim_user_id", null: false
    t.bigint "decidim_component_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_component_id"], name: "index_decidim_reminders_on_decidim_component_id"
    t.index ["decidim_user_id"], name: "index_decidim_reminders_on_decidim_user_id"
  end

  create_table "decidim_reports", id: :serial, force: :cascade do |t|
    t.integer "decidim_moderation_id", null: false
    t.integer "decidim_user_id", null: false
    t.string "reason", null: false
    t.text "details"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "locale"
    t.index ["decidim_moderation_id", "decidim_user_id"], name: "decidim_reports_moderation_user_unique", unique: true
    t.index ["decidim_moderation_id"], name: "decidim_reports_moderation"
    t.index ["decidim_user_id"], name: "decidim_reports_user"
  end

  create_table "decidim_resource_links", id: :serial, force: :cascade do |t|
    t.string "from_type", null: false
    t.integer "from_id", null: false
    t.string "to_type", null: false
    t.integer "to_id", null: false
    t.string "name", null: false
    t.jsonb "data"
    t.index ["from_type", "from_id"], name: "index_decidim_resource_links_on_from_type_and_from_id"
    t.index ["name"], name: "index_decidim_resource_links_on_name"
    t.index ["to_type", "to_id"], name: "index_decidim_resource_links_on_to_type_and_to_id"
  end

  create_table "decidim_resource_permissions", force: :cascade do |t|
    t.string "resource_type"
    t.bigint "resource_id"
    t.jsonb "permissions", default: {}
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["resource_type", "resource_id"], name: "index_decidim_resource_permissions_on_r_type_and_r_id", unique: true
  end

  create_table "decidim_scope_types", id: :serial, force: :cascade do |t|
    t.integer "decidim_organization_id"
    t.jsonb "name", null: false
    t.jsonb "plural", null: false
    t.index ["decidim_organization_id"], name: "index_decidim_scope_types_on_decidim_organization_id"
  end

  create_table "decidim_scopes", id: :serial, force: :cascade do |t|
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "name", null: false
    t.integer "scope_type_id"
    t.integer "parent_id"
    t.string "code", null: false
    t.integer "part_of", default: [], null: false, array: true
    t.index ["decidim_organization_id", "code"], name: "index_decidim_scopes_on_decidim_organization_id_and_code", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_scopes_on_decidim_organization_id"
    t.index ["parent_id"], name: "index_decidim_scopes_on_parent_id"
    t.index ["part_of"], name: "index_decidim_scopes_on_part_of", using: :gin
    t.index ["scope_type_id"], name: "index_decidim_scopes_on_scope_type_id"
  end

  create_table "decidim_searchable_resources", force: :cascade do |t|
    t.text "content_a"
    t.text "content_b"
    t.text "content_c"
    t.text "content_d"
    t.string "locale", null: false
    t.datetime "datetime", precision: nil
    t.bigint "decidim_scope_id"
    t.string "decidim_participatory_space_type"
    t.bigint "decidim_participatory_space_id"
    t.bigint "decidim_organization_id"
    t.string "resource_type"
    t.bigint "resource_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_organization_id"], name: "index_decidim_searchable_resources_on_decidim_organization_id"
    t.index ["decidim_participatory_space_type", "decidim_participatory_space_id"], name: "index_decidim_searchable_resource_on_pspace_type_and_pspace_id"
    t.index ["decidim_scope_id"], name: "index_decidim_searchable_resources_on_decidim_scope_id"
    t.index ["resource_type", "resource_id"], name: "index_decidim_searchable_rsrcs_on_s_type_and_s_id"
  end

  create_table "decidim_share_tokens", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.bigint "decidim_user_id", null: false
    t.string "token_for_type", null: false
    t.bigint "token_for_id", null: false
    t.string "token", null: false
    t.integer "times_used", default: 0
    t.datetime "created_at", precision: nil
    t.datetime "last_used_at", precision: nil
    t.datetime "expires_at", precision: nil
    t.boolean "registered_only"
    t.index ["decidim_organization_id"], name: "index_decidim_share_tokens_on_decidim_organization_id"
    t.index ["decidim_user_id"], name: "index_decidim_share_tokens_on_decidim_user_id"
    t.index ["token_for_type", "token_for_id"], name: "decidim_share_tokens_token_for"
  end

  create_table "decidim_short_links", force: :cascade do |t|
    t.bigint "decidim_organization_id", null: false
    t.string "target_type", null: false
    t.bigint "target_id", null: false
    t.string "identifier", limit: 10, null: false
    t.string "mounted_engine_name"
    t.string "route_name"
    t.jsonb "params"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decidim_organization_id", "identifier"], name: "idx_decidim_short_links_organization_id_identifier", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_short_links_on_decidim_organization_id"
    t.index ["mounted_engine_name"], name: "index_decidim_short_links_on_mounted_engine_name"
    t.index ["route_name"], name: "index_decidim_short_links_on_route_name"
    t.index ["target_type", "target_id"], name: "index_decidim_short_links_on_target"
  end

  create_table "decidim_sortitions_sortitions", force: :cascade do |t|
    t.bigint "decidim_component_id"
    t.integer "decidim_proposals_component_id"
    t.integer "dice", null: false
    t.integer "target_items", null: false
    t.datetime "request_timestamp", precision: nil, null: false
    t.jsonb "selected_proposals"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "witnesses"
    t.jsonb "additional_info"
    t.bigint "decidim_author_id", null: false
    t.string "reference"
    t.jsonb "title"
    t.jsonb "cancel_reason"
    t.datetime "cancelled_on", precision: nil
    t.integer "cancelled_by_user_id"
    t.jsonb "candidate_proposals"
    t.string "decidim_author_type", null: false
    t.integer "comments_count", default: 0, null: false
    t.datetime "deleted_at"
    t.index ["cancelled_by_user_id"], name: "index_decidim_sortitions_sortitions_on_cancelled_by_user_id"
    t.index ["decidim_author_id", "decidim_author_type"], name: "index_decidim_sortitions_sortitions_on_decidim_author"
    t.index ["decidim_author_id"], name: "idx_on_decidim_author_id_c14fe8c981"
    t.index ["decidim_component_id"], name: "index_sortitions__on_feature"
    t.index ["decidim_proposals_component_id"], name: "index_sortitions__on_proposals_feature"
    t.index ["deleted_at"], name: "index_decidim_sortitions_sortitions_on_deleted_at"
  end

  create_table "decidim_static_page_topics", force: :cascade do |t|
    t.jsonb "title", null: false
    t.jsonb "description", null: false
    t.bigint "organization_id", null: false
    t.integer "weight"
    t.boolean "show_in_footer", default: false, null: false
    t.index ["organization_id"], name: "index_decidim_static_page_topics_on_organization_id"
  end

  create_table "decidim_static_pages", id: :serial, force: :cascade do |t|
    t.jsonb "title", null: false
    t.string "slug", null: false
    t.jsonb "content", null: false
    t.integer "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "weight"
    t.bigint "topic_id"
    t.boolean "allow_public_access", default: false, null: false
    t.index ["decidim_organization_id"], name: "index_decidim_static_pages_on_decidim_organization_id"
    t.index ["topic_id"], name: "index_decidim_static_pages_on_topic_id"
  end

  create_table "decidim_surveys_surveys", id: :serial, force: :cascade do |t|
    t.integer "decidim_component_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "deleted_at"
    t.datetime "starts_at"
    t.datetime "ends_at"
    t.jsonb "announcement"
    t.boolean "allow_responses"
    t.boolean "allow_unregistered"
    t.boolean "clean_after_publish"
    t.datetime "published_at"
    t.boolean "allow_editing_responses"
    t.index ["decidim_component_id"], name: "index_decidim_surveys_surveys_on_decidim_component_id"
    t.index ["deleted_at"], name: "index_decidim_surveys_surveys_on_deleted_at"
    t.index ["published_at"], name: "index_decidim_surveys_surveys_on_published_at"
  end

  create_table "decidim_system_admins", id: :serial, force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at", precision: nil
    t.datetime "remember_created_at", precision: nil
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["email"], name: "index_decidim_system_admins_on_email", unique: true
    t.index ["reset_password_token"], name: "index_decidim_system_admins_on_reset_password_token", unique: true
  end

  create_table "decidim_taxonomies", force: :cascade do |t|
    t.jsonb "name", default: {}, null: false
    t.bigint "decidim_organization_id", null: false
    t.bigint "parent_id"
    t.integer "weight"
    t.integer "children_count", default: 0, null: false
    t.integer "taxonomizations_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "filters_count", default: 0, null: false
    t.integer "filter_items_count", default: 0, null: false
    t.integer "part_of", default: [], null: false, array: true
    t.index ["decidim_organization_id"], name: "index_decidim_taxonomies_on_decidim_organization_id"
    t.index ["parent_id"], name: "index_decidim_taxonomies_on_parent_id"
    t.index ["part_of"], name: "index_decidim_taxonomies_on_part_of", using: :gin
  end

  create_table "decidim_taxonomizations", force: :cascade do |t|
    t.bigint "taxonomy_id", null: false
    t.string "taxonomizable_type", null: false
    t.bigint "taxonomizable_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["taxonomizable_type", "taxonomizable_id"], name: "index_taxonomizations_on_taxonomizable"
    t.index ["taxonomy_id", "taxonomizable_id", "taxonomizable_type"], name: "index_taxonomizations_on_id_tid_and_ttype", unique: true
    t.index ["taxonomy_id"], name: "index_decidim_taxonomizations_on_taxonomy_id"
  end

  create_table "decidim_taxonomy_filter_items", force: :cascade do |t|
    t.bigint "taxonomy_filter_id", null: false
    t.bigint "taxonomy_item_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["taxonomy_filter_id", "taxonomy_item_id"], name: "index_taxonomy_filter_items_on_filter_id_and_item_id", unique: true
    t.index ["taxonomy_filter_id"], name: "index_decidim_taxonomy_filter_items_on_taxonomy_filter_id"
    t.index ["taxonomy_item_id"], name: "index_decidim_taxonomy_filter_items_on_taxonomy_item_id"
  end

  create_table "decidim_taxonomy_filters", force: :cascade do |t|
    t.bigint "root_taxonomy_id", null: false
    t.integer "filter_items_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "components_count", default: 0, null: false
    t.jsonb "name", default: {}
    t.jsonb "internal_name", default: {}
    t.string "participatory_space_manifests", default: [], null: false, array: true
    t.index ["root_taxonomy_id"], name: "index_decidim_taxonomy_filters_on_root_taxonomy_id"
  end

  create_table "decidim_user_blocks", force: :cascade do |t|
    t.bigint "decidim_user_id"
    t.integer "blocking_user_id"
    t.text "justification"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_user_id"], name: "index_decidim_user_blocks_on_decidim_user_id"
  end

  create_table "decidim_user_moderations", force: :cascade do |t|
    t.bigint "decidim_user_id"
    t.integer "report_count", default: 0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_user_id"], name: "index_decidim_user_moderations_on_decidim_user_id"
  end

  create_table "decidim_user_reports", force: :cascade do |t|
    t.integer "user_moderation_id"
    t.integer "user_id", null: false
    t.string "reason"
    t.text "details"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "decidim_users", id: :serial, force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at", precision: nil
    t.datetime "remember_created_at", precision: nil
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at", precision: nil
    t.datetime "last_sign_in_at", precision: nil
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "invitation_token"
    t.datetime "invitation_created_at", precision: nil
    t.datetime "invitation_sent_at", precision: nil
    t.datetime "invitation_accepted_at", precision: nil
    t.integer "invitation_limit"
    t.string "invited_by_type"
    t.integer "invited_by_id"
    t.integer "invitations_count", default: 0
    t.integer "decidim_organization_id"
    t.string "confirmation_token"
    t.datetime "confirmed_at", precision: nil
    t.datetime "confirmation_sent_at", precision: nil
    t.string "unconfirmed_email"
    t.string "name", null: false
    t.string "locale"
    t.text "delete_reason"
    t.datetime "deleted_at", precision: nil
    t.boolean "admin", default: false, null: false
    t.boolean "managed", default: false, null: false
    t.string "roles", default: [], array: true
    t.string "nickname", limit: 20, default: "", null: false
    t.string "personal_url"
    t.text "about"
    t.datetime "accepted_tos_version", precision: nil
    t.string "newsletter_token", default: ""
    t.datetime "newsletter_notifications_at", precision: nil
    t.string "type", null: false
    t.jsonb "extended_data", default: {}
    t.integer "following_count", default: 0, null: false
    t.integer "followers_count", default: 0, null: false
    t.string "notification_types", default: "all", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at", precision: nil
    t.string "session_token"
    t.string "direct_message_types", default: "all", null: false
    t.boolean "blocked", default: false, null: false
    t.datetime "blocked_at", precision: nil
    t.integer "block_id"
    t.boolean "email_on_moderations", default: true
    t.integer "follows_count", default: 0, null: false
    t.jsonb "notification_settings", default: {}
    t.string "notifications_sending_frequency", default: "none"
    t.datetime "digest_sent_at", precision: nil
    t.datetime "password_updated_at", precision: nil
    t.string "previous_passwords", default: [], array: true
    t.string "api_key"
    t.datetime "officialized_at", precision: nil
    t.jsonb "officialized_as"
    t.datetime "admin_terms_accepted_at", precision: nil
    t.boolean "email_on_assigned_proposals", default: true
    t.index ["confirmation_token"], name: "index_decidim_users_on_confirmation_token", unique: true
    t.index ["decidim_organization_id"], name: "index_decidim_users_on_decidim_organization_id"
    t.index ["email", "decidim_organization_id"], name: "index_decidim_users_on_email_and_decidim_organization_id", unique: true, where: "((deleted_at IS NULL) AND (managed = false) AND ((type)::text = 'Decidim::User'::text) AND (email IS NOT NULL) AND ((email)::text <> ''::text))"
    t.index ["id", "type"], name: "index_decidim_users_on_id_and_type"
    t.index ["invitation_token"], name: "index_decidim_users_on_invitation_token", unique: true
    t.index ["invitations_count"], name: "index_decidim_users_on_invitations_count"
    t.index ["invited_by_id", "invited_by_type"], name: "index_decidim_users_on_invited_by_id_and_invited_by_type"
    t.index ["invited_by_id"], name: "index_decidim_users_on_invited_by_id"
    t.index ["nickname", "decidim_organization_id"], name: "index_decidim_users_on_nickame_and_decidim_organization_id", unique: true, where: "((deleted_at IS NULL) AND (managed = false))"
    t.index ["notifications_sending_frequency"], name: "index_decidim_users_on_notifications_sending_frequency"
    t.index ["officialized_at"], name: "index_decidim_users_on_officialized_at"
    t.index ["reset_password_token"], name: "index_decidim_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_decidim_users_on_unlock_token", unique: true
  end

  create_table "decidim_verifications_conflicts", force: :cascade do |t|
    t.bigint "current_user_id"
    t.bigint "managed_user_id"
    t.integer "times", default: 0
    t.string "unique_id"
    t.boolean "solved", default: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["current_user_id"], name: "authorization_current_user"
    t.index ["managed_user_id"], name: "authorization_managed_user"
  end

  create_table "decidim_verifications_csv_data", force: :cascade do |t|
    t.string "email"
    t.bigint "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["decidim_organization_id"], name: "index_verifications_csv_census_to_organization"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.integer "resource_owner_id", null: false
    t.bigint "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "revoked_at", precision: nil
    t.string "scopes"
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.integer "resource_owner_id"
    t.bigint "application_id"
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.datetime "revoked_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.string "scopes"
    t.string "previous_refresh_token", default: "", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.string "name", null: false
    t.string "organization_name", null: false
    t.string "organization_url", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.bigint "decidim_organization_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "type"
    t.boolean "confidential", default: true, null: false
    t.boolean "refresh_tokens_enabled", default: false
    t.index ["decidim_organization_id"], name: "index_oauth_applications_on_decidim_organization_id"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.string "item_type", null: false
    t.integer "item_id", null: false
    t.string "event", null: false
    t.string "whodunnit"
    t.jsonb "object"
    t.datetime "created_at", precision: nil
    t.text "old_object_changes"
    t.jsonb "object_changes"
    t.index ["item_id", "item_type"], name: "index_versions_on_item_id_and_item_type"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "decidim_app_city_service_automation_decisions", "decidim_app_city_service_events", column: "event_id"
  add_foreign_key "decidim_app_city_service_automation_decisions", "decidim_users", column: "checked_by_id"
  add_foreign_key "decidim_app_city_service_coverages", "decidim_app_city_service_events", column: "event_id"
  add_foreign_key "decidim_app_city_service_coverages", "decidim_organizations"
  add_foreign_key "decidim_app_city_service_coverages", "decidim_users", column: "reviewer_id"
  add_foreign_key "decidim_app_city_service_duplicate_decisions", "decidim_app_city_service_events", column: "event_id"
  add_foreign_key "decidim_app_city_service_duplicate_decisions", "decidim_app_city_service_events", column: "other_event_id"
  add_foreign_key "decidim_app_city_service_duplicate_decisions", "decidim_organizations"
  add_foreign_key "decidim_app_city_service_duplicate_decisions", "decidim_users", column: "reviewer_id"
  add_foreign_key "decidim_app_city_service_effects", "decidim_app_city_service_events", column: "event_id"
  add_foreign_key "decidim_app_city_service_entries", "decidim_organizations"
  add_foreign_key "decidim_app_city_service_entries", "decidim_users", column: "approved_by_id"
  add_foreign_key "decidim_app_city_service_events", "decidim_app_city_service_events", column: "superseded_by_id"
  add_foreign_key "decidim_app_city_service_events", "decidim_app_city_service_incidents", column: "incident_id"
  add_foreign_key "decidim_app_city_service_events", "decidim_organizations"
  add_foreign_key "decidim_app_city_service_events", "decidim_users", column: "reviewed_by_id"
  add_foreign_key "decidim_app_city_service_incidents", "decidim_organizations"
  add_foreign_key "decidim_app_city_service_projections", "decidim_app_city_service_incidents", column: "incident_id"
  add_foreign_key "decidim_app_city_service_projections", "decidim_bih_komsiluk_posts", column: "post_id"
  add_foreign_key "decidim_app_city_service_projections", "decidim_bih_local_areas", column: "komsiluk_id"
  add_foreign_key "decidim_app_foundation_status_overrides", "decidim_organizations"
  add_foreign_key "decidim_app_foundation_status_overrides", "decidim_users", column: "approved_by_id"
  add_foreign_key "decidim_app_launch_event_deliveries", "decidim_organizations"
  add_foreign_key "decidim_app_launch_event_deliveries", "decidim_users", column: "actor_id", on_delete: :nullify
  add_foreign_key "decidim_app_launch_event_deliveries", "decidim_users", on_delete: :cascade
  add_foreign_key "decidim_app_launch_event_votes", "decidim_organizations"
  add_foreign_key "decidim_app_launch_event_votes", "decidim_users", on_delete: :cascade
  add_foreign_key "decidim_area_types", "decidim_organizations"
  add_foreign_key "decidim_areas", "decidim_area_types", column: "area_type_id"
  add_foreign_key "decidim_areas", "decidim_organizations"
  add_foreign_key "decidim_assemblies_settings", "decidim_organizations"
  add_foreign_key "decidim_attachments", "decidim_attachment_collections", column: "attachment_collection_id", name: "fk_decidim_attachments_attachment_collection_id", on_delete: :nullify
  add_foreign_key "decidim_authorization_transfer_records", "decidim_authorization_transfers", column: "transfer_id"
  add_foreign_key "decidim_authorization_transfers", "decidim_authorizations", column: "authorization_id"
  add_foreign_key "decidim_authorization_transfers", "decidim_users", column: "source_user_id"
  add_foreign_key "decidim_authorization_transfers", "decidim_users", column: "user_id"
  add_foreign_key "decidim_authorizations", "decidim_users"
  add_foreign_key "decidim_awesome_authorization_groups", "decidim_organizations"
  add_foreign_key "decidim_awesome_authorization_members", "decidim_awesome_authorization_groups", column: "authorization_group_id"
  add_foreign_key "decidim_awesome_config_constraints", "decidim_awesome_config"
  add_foreign_key "decidim_awesome_editor_images", "decidim_organizations"
  add_foreign_key "decidim_awesome_editor_images", "decidim_users", column: "decidim_author_id"
  add_foreign_key "decidim_awesome_follow_up_questionnaire_messages", "decidim_awesome_follow_up_questionnaire_statuses", column: "status_id"
  add_foreign_key "decidim_awesome_follow_up_questionnaire_messages", "decidim_awesome_follow_up_questionnaires", column: "follow_up_questionnaire_id"
  add_foreign_key "decidim_awesome_follow_up_questionnaire_statuses", "decidim_awesome_follow_up_questionnaires", column: "follow_up_questionnaire_id"
  add_foreign_key "decidim_awesome_follow_up_questionnaires", "decidim_components"
  add_foreign_key "decidim_awesome_follow_up_questionnaires", "decidim_organizations"
  add_foreign_key "decidim_bih_account_notifications", "decidim_organizations"
  add_foreign_key "decidim_bih_account_notifications", "decidim_users", on_delete: :cascade
  add_foreign_key "decidim_bih_broadcasts", "decidim_bih_local_areas", column: "local_area_id", name: "fk_bih_broadcasts_local_area"
  add_foreign_key "decidim_bih_broadcasts", "decidim_organizations"
  add_foreign_key "decidim_bih_broadcasts", "decidim_users", column: "sent_by_id", name: "fk_bih_broadcasts_sent_by", on_delete: :nullify
  add_foreign_key "decidim_bih_channel_connection_challenges", "decidim_organizations"
  add_foreign_key "decidim_bih_channel_connection_challenges", "decidim_users"
  add_foreign_key "decidim_bih_channel_connections", "decidim_organizations"
  add_foreign_key "decidim_bih_channel_connections", "decidim_users"
  add_foreign_key "decidim_bih_citizen_phones", "decidim_organizations"
  add_foreign_key "decidim_bih_citizen_phones", "decidim_users"
  add_foreign_key "decidim_bih_citizen_profiles", "decidim_bih_local_areas", column: "komsiluk_id", name: "fk_bih_citizen_profiles_komsiluk"
  add_foreign_key "decidim_bih_citizen_profiles", "decidim_bih_local_areas", column: "mz_id", name: "fk_bih_citizen_profiles_mz"
  add_foreign_key "decidim_bih_citizen_profiles", "decidim_organizations"
  add_foreign_key "decidim_bih_citizen_profiles", "decidim_users", name: "fk_bih_citizen_profiles_user", on_delete: :nullify
  add_foreign_key "decidim_bih_concierge_feedbacks", "decidim_organizations"
  add_foreign_key "decidim_bih_concierge_feedbacks", "decidim_users"
  add_foreign_key "decidim_bih_concierge_metric_rollups", "decidim_organizations"
  add_foreign_key "decidim_bih_concierge_usage_aggregates", "decidim_organizations"
  add_foreign_key "decidim_bih_contribution_needs", "decidim_bih_partner_profiles", column: "partner_profile_id", on_delete: :restrict
  add_foreign_key "decidim_bih_contribution_needs", "decidim_budgets_projects", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_needs", "decidim_organizations"
  add_foreign_key "decidim_bih_contribution_needs", "decidim_users", column: "decidim_author_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_needs", "decidim_users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_offers", "decidim_bih_contribution_needs", column: "contribution_need_id", on_delete: :restrict
  add_foreign_key "decidim_bih_contribution_offers", "decidim_bih_partner_profiles", column: "partner_profile_id", on_delete: :restrict
  add_foreign_key "decidim_bih_contribution_offers", "decidim_organizations"
  add_foreign_key "decidim_bih_contribution_offers", "decidim_users", column: "accepted_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_offers", "decidim_users", column: "confirmed_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_offers", "decidim_users", column: "declined_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_offers", "decidim_users", column: "recognized_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_contribution_offers", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_goodwill_accounts", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_award_admissions", "decidim_bih_goodwill_accounts", column: "account_id"
  add_foreign_key "decidim_bih_goodwill_award_admissions", "decidim_bih_goodwill_transactions", column: "transaction_id"
  add_foreign_key "decidim_bih_goodwill_award_admissions", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_correction_intents", "decidim_bih_report_events", column: "report_event_id"
  add_foreign_key "decidim_bih_goodwill_correction_intents", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_goodwill_credit_corrections", "decidim_bih_goodwill_accounts", column: "account_id"
  add_foreign_key "decidim_bih_goodwill_credit_corrections", "decidim_bih_goodwill_transactions", column: "original_transaction_id"
  add_foreign_key "decidim_bih_goodwill_credit_corrections", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_credit_corrections", "decidim_users", column: "actor_id"
  add_foreign_key "decidim_bih_goodwill_credit_settlements", "decidim_bih_goodwill_credit_corrections", column: "credit_correction_id"
  add_foreign_key "decidim_bih_goodwill_credit_settlements", "decidim_bih_goodwill_transactions", column: "transaction_id"
  add_foreign_key "decidim_bih_goodwill_credit_settlements", "decidim_users", column: "settled_by_id"
  add_foreign_key "decidim_bih_goodwill_entries", "decidim_bih_goodwill_accounts"
  add_foreign_key "decidim_bih_goodwill_entries", "decidim_bih_goodwill_transactions"
  add_foreign_key "decidim_bih_goodwill_entries", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_match_requests", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_match_requests", "decidim_users", column: "created_by_id"
  add_foreign_key "decidim_bih_goodwill_match_requests", "decidim_users", column: "decided_by_id"
  add_foreign_key "decidim_bih_goodwill_match_requests", "decidim_users", column: "payout_recorded_by_id"
  add_foreign_key "decidim_bih_goodwill_referrals", "decidim_bih_goodwill_transactions", column: "transaction_id"
  add_foreign_key "decidim_bih_goodwill_referrals", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_referrals", "decidim_users", column: "invitee_id"
  add_foreign_key "decidim_bih_goodwill_referrals", "decidim_users", column: "referrer_id"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillment_events", "decidim_bih_goodwill_reward_fulfillments"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillment_events", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillment_events", "decidim_users"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillments", "decidim_bih_goodwill_transactions"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillments", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillments", "decidim_users"
  add_foreign_key "decidim_bih_goodwill_reward_fulfillments", "decidim_users", column: "handled_by_id"
  add_foreign_key "decidim_bih_goodwill_rewards", "decidim_bih_partner_profiles", column: "sponsor_partner_profile_id"
  add_foreign_key "decidim_bih_goodwill_rewards", "decidim_organizations"
  add_foreign_key "decidim_bih_goodwill_transactions", "decidim_organizations"
  add_foreign_key "decidim_bih_governance_approval_attestations", "decidim_bih_governance_approvals", column: "governance_approval_id"
  add_foreign_key "decidim_bih_governance_approval_attestations", "decidim_bih_operator_audit_events", column: "operator_audit_event_id"
  add_foreign_key "decidim_bih_governance_approval_attestations", "decidim_organizations"
  add_foreign_key "decidim_bih_governance_approval_attestations", "decidim_users"
  add_foreign_key "decidim_bih_governance_approvals", "decidim_bih_operator_audit_events", column: "operator_audit_event_id"
  add_foreign_key "decidim_bih_governance_approvals", "decidim_organizations"
  add_foreign_key "decidim_bih_governance_approvals", "decidim_users"
  add_foreign_key "decidim_bih_governance_approvals", "decidim_users", column: "secondary_approver_id"
  add_foreign_key "decidim_bih_inbound_email_effects", "decidim_bih_inbound_emails", column: "inbound_email_id"
  add_foreign_key "decidim_bih_inbound_email_effects", "decidim_bih_reports"
  add_foreign_key "decidim_bih_inbound_email_links", "decidim_bih_inbound_emails", column: "inbound_email_id"
  add_foreign_key "decidim_bih_inbound_email_links", "decidim_bih_report_reply_capabilities", column: "capability_id"
  add_foreign_key "decidim_bih_inbound_email_links", "decidim_bih_reports"
  add_foreign_key "decidim_bih_inbound_email_links", "decidim_users", column: "created_by_id"
  add_foreign_key "decidim_bih_inbound_emails", "decidim_organizations"
  add_foreign_key "decidim_bih_inbound_emails", "decidim_users", column: "dismissed_by_id"
  add_foreign_key "decidim_bih_komsiluk_help_responses", "decidim_bih_komsiluk_posts", column: "post_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_help_responses", "decidim_users", column: "user_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_phone_deliveries", "decidim_bih_komsiluk_send_intents", column: "send_intent_id"
  add_foreign_key "decidim_bih_komsiluk_phone_deliveries", "decidim_bih_platform_deliveries", column: "platform_delivery_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_phone_deliveries", "decidim_organizations"
  add_foreign_key "decidim_bih_komsiluk_phone_deliveries", "decidim_users"
  add_foreign_key "decidim_bih_komsiluk_photo_drafts", "decidim_organizations", column: "organization_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_photo_drafts", "decidim_users", column: "user_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_post_flags", "decidim_bih_komsiluk_posts", name: "fk_bih_komsiluk_post_flags_post", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_post_flags", "decidim_users", name: "fk_bih_komsiluk_post_flags_user", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_post_reviews", "decidim_bih_komsiluk_posts", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_post_reviews", "decidim_organizations"
  add_foreign_key "decidim_bih_komsiluk_post_reviews", "decidim_users", column: "reviewer_id", on_delete: :nullify
  add_foreign_key "decidim_bih_komsiluk_post_revisions", "decidim_bih_komsiluk_posts", column: "post_id", on_delete: :cascade
  add_foreign_key "decidim_bih_komsiluk_post_revisions", "decidim_users", column: "actor_id", on_delete: :nullify
  add_foreign_key "decidim_bih_komsiluk_posts", "decidim_bih_local_areas", column: "komsiluk_id", name: "fk_bih_komsiluk_posts_komsiluk"
  add_foreign_key "decidim_bih_komsiluk_posts", "decidim_organizations"
  add_foreign_key "decidim_bih_komsiluk_posts", "decidim_users", name: "fk_bih_komsiluk_posts_user", on_delete: :nullify
  add_foreign_key "decidim_bih_komsiluk_send_intents", "decidim_organizations"
  add_foreign_key "decidim_bih_komsiluk_send_intents", "decidim_users"
  add_foreign_key "decidim_bih_komsiluk_sms_budgets", "decidim_organizations"
  add_foreign_key "decidim_bih_local_areas", "decidim_bih_local_areas", column: "parent_id", name: "fk_bih_local_areas_parent"
  add_foreign_key "decidim_bih_local_areas", "decidim_organizations"
  add_foreign_key "decidim_bih_login_tokens", "decidim_organizations"
  add_foreign_key "decidim_bih_login_tokens", "decidim_users"
  add_foreign_key "decidim_bih_mailbox_cursors", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_attempts", "decidim_bih_messaging_intents", column: "intent_id", on_delete: :cascade
  add_foreign_key "decidim_bih_messaging_intents", "decidim_bih_account_notifications", on_delete: :nullify
  add_foreign_key "decidim_bih_messaging_intents", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_intents", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_messaging_organization_policies", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_preference_changes", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_preference_changes", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_messaging_preferences", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_preferences", "decidim_users", on_delete: :cascade
  add_foreign_key "decidim_bih_messaging_suppressions", "decidim_organizations"
  add_foreign_key "decidim_bih_messaging_suppressions", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_operator_audit_events", "decidim_organizations"
  add_foreign_key "decidim_bih_operator_audit_events", "decidim_users"
  add_foreign_key "decidim_bih_operator_messages", "decidim_organizations"
  add_foreign_key "decidim_bih_operator_messages", "decidim_users", column: "recipient_id"
  add_foreign_key "decidim_bih_operator_messages", "decidim_users", column: "sender_id"
  add_foreign_key "decidim_bih_operator_roles", "decidim_organizations"
  add_foreign_key "decidim_bih_operator_roles", "decidim_users"
  add_foreign_key "decidim_bih_operator_roles", "decidim_users", column: "created_by_id"
  add_foreign_key "decidim_bih_org_spending_requests", "decidim_bih_partner_profiles", column: "source_partner_profile_id"
  add_foreign_key "decidim_bih_org_spending_requests", "decidim_bih_partner_profiles", column: "target_partner_profile_id"
  add_foreign_key "decidim_bih_org_spending_requests", "decidim_organizations"
  add_foreign_key "decidim_bih_org_spending_requests", "decidim_users", column: "decided_by_id"
  add_foreign_key "decidim_bih_org_spending_requests", "decidim_users", column: "requested_by_id"
  add_foreign_key "decidim_bih_partner_memberships", "decidim_bih_partner_profiles", column: "partner_profile_id"
  add_foreign_key "decidim_bih_partner_memberships", "decidim_organizations"
  add_foreign_key "decidim_bih_partner_memberships", "decidim_users"
  add_foreign_key "decidim_bih_partner_memberships", "decidim_users", column: "invited_by_id"
  add_foreign_key "decidim_bih_partner_notices", "decidim_bih_partner_profiles", column: "partner_profile_id"
  add_foreign_key "decidim_bih_partner_notices", "decidim_organizations"
  add_foreign_key "decidim_bih_partner_notices", "decidim_users", column: "author_id"
  add_foreign_key "decidim_bih_partner_profiles", "decidim_bih_local_areas", column: "local_area_id", name: "fk_bih_partner_profiles_local_area"
  add_foreign_key "decidim_bih_partner_profiles", "decidim_organizations"
  add_foreign_key "decidim_bih_partner_profiles", "decidim_users", column: "legacy_user_group_id", name: "fk_bih_partner_profiles_legacy_group", on_delete: :nullify
  add_foreign_key "decidim_bih_partner_profiles", "decidim_users", column: "verified_by_id"
  add_foreign_key "decidim_bih_partner_project_submissions", "decidim_bih_partner_profiles", column: "partner_profile_id", on_delete: :restrict
  add_foreign_key "decidim_bih_partner_project_submissions", "decidim_budgets_projects", on_delete: :nullify
  add_foreign_key "decidim_bih_partner_project_submissions", "decidim_organizations"
  add_foreign_key "decidim_bih_partner_project_submissions", "decidim_users", column: "reviewed_by_id", on_delete: :nullify
  add_foreign_key "decidim_bih_partner_project_submissions", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_platform_deliveries", "decidim_bih_komsiluk_posts", column: "komsiluk_post_id", on_delete: :nullify
  add_foreign_key "decidim_bih_platform_deliveries", "decidim_organizations", on_delete: :cascade
  add_foreign_key "decidim_bih_platform_deliveries", "decidim_users", on_delete: :cascade
  add_foreign_key "decidim_bih_privacy_retention_runs", "decidim_organizations"
  add_foreign_key "decidim_bih_project_donation_links", "decidim_budgets_projects", on_delete: :restrict
  add_foreign_key "decidim_bih_project_donation_links", "decidim_organizations"
  add_foreign_key "decidim_bih_race_events", "decidim_bih_race_editions", column: "edition_id"
  add_foreign_key "decidim_bih_race_memberships", "decidim_bih_race_editions", column: "edition_id"
  add_foreign_key "decidim_bih_report_collections", "decidim_organizations"
  add_foreign_key "decidim_bih_report_collections", "decidim_users", column: "assigned_to_id"
  add_foreign_key "decidim_bih_report_corroborations", "decidim_bih_reports", column: "original_report_id"
  add_foreign_key "decidim_bih_report_corroborations", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_corroborations", "decidim_organizations"
  add_foreign_key "decidim_bih_report_corroborations", "decidim_users"
  add_foreign_key "decidim_bih_report_dispatch_evidence", "decidim_bih_report_dispatches", column: "dispatch_id"
  add_foreign_key "decidim_bih_report_dispatch_evidence", "decidim_bih_report_evidence_items", column: "evidence_item_id"
  add_foreign_key "decidim_bih_report_dispatches", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_dispatches", "decidim_users", column: "approved_by_id"
  add_foreign_key "decidim_bih_report_dispatches", "decidim_users", column: "reconciled_by_id"
  add_foreign_key "decidim_bih_report_events", "decidim_bih_reports"
  add_foreign_key "decidim_bih_report_events", "decidim_organizations"
  add_foreign_key "decidim_bih_report_events", "decidim_users"
  add_foreign_key "decidim_bih_report_evidence_items", "active_storage_blobs", column: "blob_id"
  add_foreign_key "decidim_bih_report_evidence_items", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_evidence_shares", "decidim_bih_report_dispatches", column: "dispatch_id"
  add_foreign_key "decidim_bih_report_evidence_shares", "decidim_bih_report_evidence_items", column: "evidence_item_id"
  add_foreign_key "decidim_bih_report_messages", "decidim_bih_account_notifications", column: "account_notification_id", on_delete: :nullify
  add_foreign_key "decidim_bih_report_messages", "decidim_bih_report_messages", column: "answers_message_id"
  add_foreign_key "decidim_bih_report_messages", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_messages", "decidim_users", column: "actor_id"
  add_foreign_key "decidim_bih_report_obligations", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_photo_drafts", "decidim_bih_reports", column: "consumed_report_id"
  add_foreign_key "decidim_bih_report_photo_drafts", "decidim_organizations", column: "organization_id"
  add_foreign_key "decidim_bih_report_private_storage_cleanups", "decidim_organizations"
  add_foreign_key "decidim_bih_report_reply_capabilities", "decidim_bih_report_messages", column: "question_message_id"
  add_foreign_key "decidim_bih_report_reply_capabilities", "decidim_bih_reports"
  add_foreign_key "decidim_bih_report_reply_capabilities", "decidim_organizations"
  add_foreign_key "decidim_bih_report_review_proposals", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_review_proposals", "decidim_users", column: "decided_by_id"
  add_foreign_key "decidim_bih_report_routing_guides", "decidim_organizations"
  add_foreign_key "decidim_bih_report_routing_guides", "decidim_users", column: "approved_by_id"
  add_foreign_key "decidim_bih_report_second_reminders", "decidim_bih_account_notifications", column: "account_notification_id"
  add_foreign_key "decidim_bih_report_second_reminders", "decidim_bih_report_messages", column: "question_id"
  add_foreign_key "decidim_bih_report_second_reminders", "decidim_bih_reports", column: "report_id"
  add_foreign_key "decidim_bih_report_service_senders", "decidim_organizations"
  add_foreign_key "decidim_bih_reports", "decidim_bih_report_collections", column: "report_collection_id"
  add_foreign_key "decidim_bih_reports", "decidim_organizations"
  add_foreign_key "decidim_bih_reports", "decidim_users"
  add_foreign_key "decidim_bih_reports", "decidim_users", column: "assigned_to_id"
  add_foreign_key "decidim_bih_reports", "decidim_users", column: "location_reviewed_by_id"
  add_foreign_key "decidim_bih_reports", "decidim_users", column: "reviewed_by_id"
  add_foreign_key "decidim_bih_settings", "decidim_organizations"
  add_foreign_key "decidim_bih_viber_business_contacts", "decidim_organizations"
  add_foreign_key "decidim_bih_viber_business_contacts", "decidim_users"
  add_foreign_key "decidim_bih_viber_inbound_deliveries", "decidim_organizations"
  add_foreign_key "decidim_bih_viber_linkages", "decidim_organizations"
  add_foreign_key "decidim_bih_viber_linkages", "decidim_users", on_delete: :nullify
  add_foreign_key "decidim_bih_volunteer_attendances", "decidim_bih_volunteer_opportunities"
  add_foreign_key "decidim_bih_volunteer_attendances", "decidim_bih_volunteer_signups"
  add_foreign_key "decidim_bih_volunteer_attendances", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_attendances", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_attendances", "decidim_users", column: "confirmed_by_id"
  add_foreign_key "decidim_bih_volunteer_availabilities", "decidim_bih_local_areas", column: "local_area_id", name: "fk_bih_volunteer_avails_area"
  add_foreign_key "decidim_bih_volunteer_availabilities", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_availabilities", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_bonus_commitments", "decidim_bih_volunteer_logs", column: "volunteer_log_id"
  add_foreign_key "decidim_bih_volunteer_bonus_commitments", "decidim_bih_volunteer_opportunities", column: "volunteer_opportunity_id"
  add_foreign_key "decidim_bih_volunteer_bonus_commitments", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_bonus_commitments", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_daily_awards", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_daily_awards", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_logs", "decidim_bih_volunteer_opportunities"
  add_foreign_key "decidim_bih_volunteer_logs", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_logs", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_logs", "decidim_users", column: "verified_by_id"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_bih_local_areas", column: "komsiluk_id", name: "fk_bih_volunteer_opps_komsiluk"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_bih_partner_profiles", column: "partner_profile_id"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_budgets_projects", on_delete: :nullify
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_users", column: "cancelled_by_id"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_users", column: "decidim_author_id"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_users", column: "partner_confirmed_by_id"
  add_foreign_key "decidim_bih_volunteer_opportunities", "decidim_users", column: "reviewed_by_id"
  add_foreign_key "decidim_bih_volunteer_proposal_awards", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_signups", "decidim_bih_volunteer_opportunities"
  add_foreign_key "decidim_bih_volunteer_signups", "decidim_organizations"
  add_foreign_key "decidim_bih_volunteer_signups", "decidim_users"
  add_foreign_key "decidim_bih_volunteer_signups", "decidim_users", column: "attendance_confirmed_by_id"
  add_foreign_key "decidim_bih_volunteer_signups", "decidim_users", column: "reviewed_by_id"
  add_foreign_key "decidim_budgets_budgets", "decidim_scopes"
  add_foreign_key "decidim_budgets_orders", "decidim_budgets_budgets"
  add_foreign_key "decidim_budgets_projects", "decidim_budgets_budgets"
  add_foreign_key "decidim_categorizations", "decidim_categories"
  add_foreign_key "decidim_debates_debates", "decidim_scopes"
  add_foreign_key "decidim_editor_images", "decidim_organizations"
  add_foreign_key "decidim_editor_images", "decidim_users", column: "decidim_author_id"
  add_foreign_key "decidim_identities", "decidim_organizations"
  add_foreign_key "decidim_newsletters", "decidim_users", column: "author_id"
  add_foreign_key "decidim_participatory_process_steps", "decidim_participatory_processes"
  add_foreign_key "decidim_participatory_processes", "decidim_organizations"
  add_foreign_key "decidim_participatory_processes", "decidim_scope_types"
  add_foreign_key "decidim_proposals_proposals", "decidim_proposals_proposal_states"
  add_foreign_key "decidim_reminder_deliveries", "decidim_reminders"
  add_foreign_key "decidim_reminder_records", "decidim_reminders"
  add_foreign_key "decidim_reminders", "decidim_components"
  add_foreign_key "decidim_reminders", "decidim_users"
  add_foreign_key "decidim_scope_types", "decidim_organizations"
  add_foreign_key "decidim_scopes", "decidim_organizations"
  add_foreign_key "decidim_scopes", "decidim_scope_types", column: "scope_type_id"
  add_foreign_key "decidim_scopes", "decidim_scopes", column: "parent_id"
  add_foreign_key "decidim_static_pages", "decidim_organizations"
  add_foreign_key "decidim_taxonomy_filter_items", "decidim_taxonomies", column: "taxonomy_item_id"
  add_foreign_key "decidim_taxonomy_filters", "decidim_taxonomies", column: "root_taxonomy_id"
  add_foreign_key "decidim_user_blocks", "decidim_users"
  add_foreign_key "decidim_user_blocks", "decidim_users", column: "blocking_user_id"
  add_foreign_key "decidim_user_moderations", "decidim_users"
  add_foreign_key "decidim_user_reports", "decidim_user_moderations", column: "user_moderation_id"
  add_foreign_key "decidim_user_reports", "decidim_users", column: "user_id"
  add_foreign_key "decidim_users", "decidim_organizations"
  add_foreign_key "decidim_verifications_conflicts", "decidim_users", column: "current_user_id"
  add_foreign_key "decidim_verifications_conflicts", "decidim_users", column: "managed_user_id"
  add_foreign_key "decidim_verifications_csv_data", "decidim_organizations"
  add_foreign_key "oauth_access_grants", "decidim_users", column: "resource_owner_id"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "decidim_users", column: "resource_owner_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_applications", "decidim_organizations"
end
