# frozen_string_literal: true

require "json"
require "securerandom"
require "tempfile"

# Database and filesystem commits are deliberately reconciled, not described
# as one atomic transaction. Password intent is durable before account writes;
# a retry proves that exact account/password rather than resetting an account.
class MiDemoProvisioner
  SYSTEM_EMAIL = "system-admin@example.org"
  ADMIN_EMAIL = "admin@example.org"
  LOCALES = %w(sr sr-Cyrl bs hr).freeze
  DISCLAIMER = {
    "sr" => "IZMIŠLJENI LOKALNI TEST. Bez pravnog dejstva i bez stvarnih usluga.",
    "sr-Cyrl" => "ИЗМИШЉЕНИ ЛОКАЛНИ ТЕСТ. Без правног дејства и без стварних услуга.",
    "bs" => "IZMIŠLJENI LOKALNI TEST. Bez pravnog dejstva i bez stvarnih usluga.",
    "hr" => "IZMIŠLJENI LOKALNI TEST. Bez pravnog učinka i bez stvarnih usluga."
  }.freeze

  def initialize(private_dir: Rails.root.join("installation-private"))
    @directory = Pathname.new(private_dir)
    @identity = ENV.fetch("MI_INSTALL_ID")
  end

  def call(action)
    guard!
    flags = File::RDWR | File::CREAT | File::NOFOLLOW
    File.open(@directory.join(".provision.lock"), flags, 0o600) do |lock|
      raise "Another demo provisioning command is running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      action == "system" ? system_account : content
    end
    puts "Demo provisioning completed. Credentials remain in the private provisioning directory; no values printed."
  end

  def persist(record)
    Tempfile.create([".credentials-", ".json"], @directory) do |file|
      file.chmod(0o600)
      file.write(JSON.generate(record))
      file.flush
      file.fsync
      File.rename(file.path, journal_path)
      File.open(@directory, &:fsync)
    end
  end

  private

  def guard!
    raise "Explicit local demo required" unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true" && @identity.match?(/\Ami-[0-9a-f]{16}\z/)
    raise "Database is not owned by this installation" unless ActiveRecord::Base.connection_pool.internal_metadata["mi_installation_id"] == @identity

    stat = @directory.lstat
    raise "Private directory must be owned and mode 0700" unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && stat.mode.nobits?(0o077)
  end

  def journal_path = @directory.join("credentials.json")

  def journal
    return nil unless journal_path.exist? || journal_path.symlink?

    File.open(journal_path, File::RDONLY | File::NOFOLLOW) do |file|
      stat = file.stat
      raise "Unsafe demo credential file" unless stat.file? && stat.uid == Process.uid && stat.mode.nobits?(0o077)

      record = JSON.parse(file.read)
      raise "Private journal belongs to another installation" unless record.fetch("installation_id") == @identity

      record
    end
  end

  def system_account
    record = journal
    admin = nil
    Decidim::System::Admin.transaction do
      connection = Decidim::System::Admin.connection
      connection.execute("LOCK TABLE #{connection.quote_table_name(Decidim::System::Admin.table_name)} IN SHARE ROW EXCLUSIVE MODE")
      validate_initial_system_setup!(record)

      record ||= { "installation_id" => @identity, "system_email" => SYSTEM_EMAIL, "system_password" => "Mi1!#{SecureRandom.hex(24)}", "system_state" => "planned" }
      raise "Unexpected system account identity" unless record.fetch("system_email") == SYSTEM_EMAIL

      admin = Decidim::System::Admin.find_by(email: SYSTEM_EMAIL)
      if admin
        validate_system_account!(admin, record)
      else
        raise "Refusing to modify another system administrator" if Decidim::System::Admin.exists?

        persist(record)
        admin = Decidim::System::Admin.create!(email: SYSTEM_EMAIL, password: record.fetch("system_password"), password_confirmation: record.fetch("system_password"))
      end
    end
    complete = record.merge("system_state" => "done", "system_id" => admin.id)
    persist(complete) unless complete == record
  end

  def validate_initial_system_setup!(record)
    return if record

    raise "Refusing to adopt existing system administrators" if Decidim::System::Admin.exists?
    raise "Refusing to create a demo administrator for an existing community" if Decidim::Organization.exists?
  end

  def validate_system_account!(admin, record)
    raise "Existing system account does not match private intent" unless admin.valid_password?(record.fetch("system_password")) && Decidim::System::Admin.count == 1
  end

  def content
    record = journal
    raise "Prepare the system demo account first" unless record && record["system_state"] == "done"

    organization = Decidim::Organization.find_by!(host: "127.0.0.1")
    user = Decidim::User.find_by!(organization:, email: ADMIN_EMAIL)
    return if completed_content?(record, organization, user)

    validate_empty_demo!(organization, user)
    record = plan_content(record, organization, user)
    write_content(record, organization, user)
    persist(record.merge("content_state" => "done"))
  end

  def completed_content?(record, organization, user)
    marker = Decidim::Bih::Setting.namespace_for(organization, "mi_demo")["installation_id"]
    return false unless marker

    valid = marker == @identity && record["organization_id"] == organization.id && record["organization_user_id"] == user.id
    raise "Demo belongs to another installation" unless valid && user.valid_password?(record.fetch("organization_password"))

    persist(record.merge("content_state" => "done")) unless record["content_state"] == "done"
    true
  end

  def plan_content(record, organization, user)
    if record["content_state"] == "planned"
      raise "Pending setup belongs to another organization" unless record["organization_id"] == organization.id && record["organization_user_id"] == user.id
    else
      record = record.merge("content_state" => "planned", "organization_id" => organization.id, "organization_user_id" => user.id,
                            "organization_email" => ADMIN_EMAIL, "organization_password" => "Mi1!#{SecureRandom.hex(24)}")
      persist(record)
    end
    record
  end

  def write_content(record, organization, user)
    Decidim::Organization.transaction do
      organization.lock!
      user.lock!
      validate_empty_demo!(organization, user)
      organization.description = DISCLAIMER if organization.description.blank?
      organization.admin_terms_of_service_body = DISCLAIMER if organization.admin_terms_of_service_body.blank?
      organization.save!
      topic = Decidim::StaticPageTopic.create!(organization:, title: LOCALES.index_with { "Demo — primjer" }, description: DISCLAIMER, weight: 100, show_in_footer: true)
      %w(terms-of-service privacy-policy cookie-policy data-processing).each_with_index do |slug, index|
        page = Decidim::StaticPage.find_or_initialize_by(organization:, slug:)
        page.assign_attributes(title: LOCALES.index_with { "Demo — #{slug}" }, content: DISCLAIMER.transform_values do |text|
          "<p>#{text}</p>"
        end, topic:, weight: index * 10, allow_public_access: true)
        page.save!
      end
      user.password = record.fetch("organization_password")
      user.password_confirmation = record.fetch("organization_password")
      user.accept_invitation!
      raise "Invitation was not accepted" if user.errors.any? || user.invitation_accepted_at.nil?

      Decidim::Bih::Setting.put(organization, "mi_demo", "installation_id", @identity)
    end
  end

  def validate_empty_demo!(organization, user)
    unless organization.users.count == 1 && user.admin? && user.invitation_created_at.present? && user.invitation_accepted_at.nil?
      raise "Expected only the invited demo administrator"
    end
    raise "Expected one new demo organization" unless Decidim::Organization.count == 1
    raise "Existing community content must not be modified" if existing_spaces?(organization) || Decidim::Bih::Report.exists?(organization:)

    validate_terms!(organization)
  end

  def existing_spaces?(organization)
    Decidim.participatory_space_manifests.any? { |manifest| manifest.model_class_name.constantize.exists?(organization:) }
  end

  # System creation also adds informational help pages and the DQ page.
  # Only exact upstream-generated title/content pairs are accepted; never
  # discard custom/reviewed pages or edit these informational pages.
  def validate_default_information_pages!(organization)
    builder = Decidim::System::CreateDefaultHelpPages.new(organization)
    expected = {
      "help" => {
        title: builder.multi_translation("decidim.help.main_topic.default_page.title", organization: builder.organization_name),
        content: builder.multi_translation("decidim.help.main_topic.default_page.content", organization: builder.organization_name)
      }
    }
    Decidim.participatory_space_manifests.each do |manifest|
      scope = "decidim.help.participatory_spaces.#{manifest.name}"
      next unless I18n.exists?(scope)

      expected[manifest.name.to_s] = { title: builder.multi_translation("#{scope}.title"), content: builder.multi_translation("#{scope}.page") }
    end
    scope = "decidim.participatory_processes.static_pages.democratic_quality_indicators"
    expected["democratic-quality-indicators"] = {
      title: organization.available_locales.index_with { |locale| I18n.t("#{scope}.title", locale:) },
      content: organization.available_locales.index_with { |locale| I18n.t("#{scope}.content", locale:) }
    }
    organization.static_pages.where.not(slug: "terms-of-service").find_each do |page|
      attributes = expected[page.slug]
      valid = attributes && page.title == attributes.fetch(:title).stringify_keys && page.content == attributes.fetch(:content).stringify_keys
      raise "Existing reviewed legal or custom pages must not be replaced" unless valid
    end
  end

  def validate_terms!(organization)
    legal_pages = organization.static_pages
    validate_default_information_pages!(organization)

    terms = legal_pages.find_by(slug: "terms-of-service")
    return unless terms

    untouched = (Decidim.available_locales.map(&:to_s) + ["en"]).uniq.any? do |title_locale|
      title = I18n.t("terms-of-service", scope: "decidim.system.default_pages", locale: title_locale)
      terms.content.all? do |locale, body|
        body == I18n.t(:content, scope: "decidim.system.default_pages.placeholders", locale:, page: title)
      end
    end
    raise "Existing terms were edited; demo setup refuses to overwrite them" unless untouched
  end
end
