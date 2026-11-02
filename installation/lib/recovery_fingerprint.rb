# frozen_string_literal: true

require "digest"
require "find"
require "json"

# Read-only fingerprints; rows, file names, passwords and keys are never output.
class MiRecoveryFingerprint
  def initialize(storage: Rails.root.join("storage"))
    @storage = Pathname.new(storage)
    @connection = ActiveRecord::Base.connection
  end

  def call
    { format: 1, database: database_fingerprints, sequences: sequence_values,
      extensions: @connection.select_rows("SELECT extname, extversion FROM pg_extension ORDER BY extname"), storage: storage_fingerprint }
  end

  private

  def database_fingerprints
    @connection.tables.sort.to_h do |table|
      quoted = @connection.quote_table_name(table)
      hash = Digest::SHA256.new
      count = 0
      raw = @connection.raw_connection
      raw.send_query("SELECT row_to_json(t)::text FROM #{quoted} AS t ORDER BY row_to_json(t)::text COLLATE \"C\"")
      raw.set_single_row_mode
      while (result = raw.get_result)
        result.check
        result.each_row do |row|
          hash.update(row.fetch(0))
          hash.update("\n")
          count += 1
        end
        result.clear
      end
      [table, { count:, sha256: hash.hexdigest }]
    end
  end

  def sequence_values
    @connection.select_values("SELECT sequencename FROM pg_sequences WHERE schemaname = current_schema() ORDER BY sequencename").index_with do |name|
      @connection.select_one("SELECT last_value, is_called FROM #{@connection.quote_table_name(name)}")
    end
  end

  def storage_fingerprint
    raise "Storage volume is unavailable" unless @storage.directory? && !@storage.symlink?

    files = []
    Find.find(@storage.to_s) do |path|
      raise "Storage symlinks/special files require separate reviewed backup support" if File.symlink?(path) || (!File.directory?(path) && !File.file?(path))

      files << path if File.file?(path)
    end
    hash = Digest::SHA256.new
    bytes = 0
    files.sort.each do |path|
      name = Pathname.new(path).relative_path_from(@storage).to_s
      size = File.size(path)
      hash.update("#{name}\0#{size}\0#{Digest::SHA256.file(path).hexdigest}\n")
      bytes += size
    end
    { files: files.length, bytes:, sha256: hash.hexdigest }
  end
end
