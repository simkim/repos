class Repository < ApplicationRecord
  belongs_to :host

  has_many :manifests, dependent: :destroy
  has_many :dependencies
  has_many :tags

  scope :owner, ->(owner) { where(owner: owner) }
  scope :subgroup, ->(owner, subgroup) { where(owner: owner).where('lower(full_name) ilike ?', "#{owner}/#{subgroup}/%") }
  scope :language, ->(language) { where(language: language) }
  scope :fork, ->(fork) { where(fork: fork) }
  scope :archived, ->(archived) { where(archived: archived) }
  scope :active, -> { archived(false) }
  scope :source, -> { fork(false) }
  scope :no_topic, -> { where("topics = '{}'") }
  scope :topic, ->(topic) { where("topics @> ARRAY[?]::varchar[]", topic) }
  
  scope :created_after, ->(date) { where('created_at > ?', date) }
  scope :updated_after, ->(date) { where('updated_at > ?', date) }

  scope :with_manifests, -> { joins(:manifests).group(:id) }
  scope :without_manifests, -> { includes(:manifests).where(manifests: {repository_id: nil}) }

  def self.parse_dependencies_async
    Repository.where.not(dependency_job_id: nil).limit(2000).select('id, dependencies_parsed_at').each(&:parse_dependencies_async)
    return if Sidekiq::Queue.new('dependencies').size > 2_000
    Repository.where(status: nil)
              .where(fork: false)
              .where(dependencies_parsed_at: nil, dependency_job_id: nil)
              .select('id, dependencies_parsed_at')
              .limit(2000).each(&:parse_dependencies_async)
  end

  def self.download_tags_async
    return if Sidekiq::Queue.new('tags').size > 5_000
    Repository.where(fork: false, status: nil)
              .order('tags_last_synced_at ASC nulls first')
              .limit(5_000)
              .select('id')
              .each(&:download_tags_async)
  end

  def self.update_package_usages_async
    return if Sidekiq::Queue.new('usage').size > 2_000
    Repository.where(fork: false, status: nil).order('usage_updated_at ASC nulls first').limit(2_000).select('id').each do |repo|
      PackageUsageWorker.perform_async(repo.id)
    end
  end

  def self.update_metadata_files_async
    return if Sidekiq::Queue.new('default').size > 10_000
    Repository.where(status: nil, fork: false)
              .where('length(metadata::text) = 2')
              .limit(5_000)
              .select('id')
              .each(&:update_metadata_files_async)
  end

  def sync_owner
    host.sync_owner(owner) if owner_record.nil?
  end

  def sync_owner_async
    host.sync_owner_async(owner) if owner_record.nil?
  end

  def owner_record
    host.owners.find_by('lower(login) = ?', owner.downcase)
  end

  def owner
    read_attribute(:owner) || full_name.split('/').first
  end

  def to_s
    full_name
  end

  def to_param
    full_name
  end

  def id_or_name
    uuid || full_name
  end

  def subgroups
    return [] if full_name.split('/').size < 3
    full_name.split('/')[1..-2]
  end

  def project_slug
    full_name.split('/').last
  end

  def project_name
    full_name.split('/')[1..-1].join('/')
  end

  def sync
    host.host_instance.update_from_host(self)
  end

  def sync_async
    UpdateRepositoryWorker.perform_async(self.id)
  end

  def html_url
    host.html_url(self)
  end

  def download_url(branch = default_branch, kind = 'branch')
    host.download_url(self, branch, kind)
  end

  def avatar_url(size)
    host.avatar_url(self, size)
  end

  def blob_url(sha = nil)
    sha ||= default_branch
    host.blob_url(self, sha = nil)
  end

  def parse_dependencies_async
    return if dependencies_parsed_at.present? # temp whilst backfilling db
    ParseDependenciesWorker.perform_async(self.id)
  end

  def parse_dependencies
    connection = Faraday.new(url: "https://parser.ecosyste.ms") do |faraday|
      faraday.use Faraday::FollowRedirects::Middleware
    
      faraday.adapter Faraday.default_adapter
    end

    if dependency_job_id
      res = connection.get("/api/v1/jobs/#{dependency_job_id}")
    else  
      res = connection.post("/api/v1/jobs?url=#{CGI.escape(download_url)}")
    end
    if res.success?
      json = Oj.load(res.body)
      record_dependency_parsing(json)
    end
  end

  def record_dependency_parsing(json)
    if ['complete', 'error'].include?(json['status'])
      if json['status'] == 'complete'
        new_manifests = json['results'].to_h.with_indifferent_access['manifests']
        
        if new_manifests.blank?
          manifests.each(&:destroy)
        else
          new_manifests.each {|m| sync_manifest(m) }
          delete_old_manifests(new_manifests)
        end
      end

      update_columns(dependencies_parsed_at: Time.now, dependency_job_id: nil)
    else
      update_column(:dependency_job_id, json["id"]) if dependency_job_id != json["id"]
    end
  end

  def sync_manifest(m)
    args = {ecosystem: (m[:platform] || m[:ecosystem]), kind: m[:kind], filepath: m[:path], sha: m[:sha]}

    unless manifests.find_by(args)
      return unless m[:dependencies].present? && m[:dependencies].any?
      manifest = manifests.create(args)
      dependencies = m[:dependencies].map(&:with_indifferent_access).uniq{|dep| [dep[:name].try(:strip), dep[:requirement], dep[:type]]}

      deps = dependencies.map do |dep|
        ecosystem = manifest.ecosystem
        next unless dep.is_a?(Hash)

        {
          manifest_id: manifest.id,
          package_name: dep[:name].try(:strip),
          ecosystem: ecosystem,
          requirements: dep[:requirement],
          kind: dep[:type],
          repository_id: self.id,
          direct: manifest.kind == 'manifest',
          created_at: Time.now,
          updated_at: Time.now
        }
      end.compact

      Dependency.insert_all(deps)
    end
  end

  def delete_old_manifests(new_manifests)
    existing_manifests = manifests.map{|m| [m.ecosystem, m.filepath] }
    to_be_removed = existing_manifests - new_manifests.map{|m| [(m[:platform] || m[:ecosystem]), m[:path]] }
    to_be_removed.each do |m|
      manifests.where(ecosystem: m[0], filepath: m[1]).each(&:destroy)
    end
    manifests.where.not(id: manifests.latest.map(&:id)).each(&:destroy)
  end

  def get_file_contents(path)
    host.get_file_contents(self, path)
  end

  def get_file_list
    host.get_file_list(self)
  end

  def download_tags
    host.download_tags(self)
  end

  def download_tags_async
    DownloadTagsWorker.perform_async(self.id)
  end

  def archive_list
    begin
      Oj.load(Faraday.get(archive_list_url).body)
    rescue
      []
    end
  end

  def archive_contents(path)
    begin
      Oj.load(Faraday.get(archive_contents_url(path)).body)
    rescue
      {}
    end
  end

  def archive_list_url
    "https://archives.ecosyste.ms/api/v1/archives/list?url=#{CGI.escape(download_url)}"
  end

  def archive_contents_url(path)
    "https://archives.ecosyste.ms/api/v1/archives/contents?url=#{CGI.escape(download_url)}&path=#{path}"
  end

  def archive_basename
    default_branch
  end

  def package_usages
    PackageUsage.host(host.name).repo_uuid(uuid)
  end

  def fetch_metadata_files_list
    file_list = get_file_list
    return if file_list.blank?
    {
      readme:           file_list.find{|file| file.match(/^README/i) },
      changelog:        file_list.find{|file| file.match(/^CHANGE|^HISTORY/i) },
      contributing:     file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?CONTRIBUTING/i) },
      funding:          file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?FUNDING.yml/i) },
      license:          file_list.find{|file| file.match(/^LICENSE|^COPYING|^MIT-LICENSE/i) },
      code_of_conduct:  file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?CODE[-_]OF[-_]CONDUCT/i) },
      threat_model:     file_list.find{|file| file.match(/^THREAT[-_]MODEL/i) },
      audit:            file_list.find{|file| file.match(/^AUDIT/i) },
      citation:         file_list.find{|file| file.match(/^CITATION/i) },
      codeowners:       file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?CODEOWNERS/i) },
      security:         file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?SECURITY/i) },
      support:          file_list.find{|file| file.match(/^(docs\/)?(.github\/)?(.gitlab\/)?SUPPORT$/i) },
    }
  end

  def update_metadata_files_async
    UpdateMetadataFilesWorker.perform_async(self.id)
  end

  def update_metadata_files
    metadata_files = fetch_metadata_files_list
    return if metadata_files.nil?
    metadata['files'] = metadata_files
    save
    parse_funding
  end

  def parse_funding
    if related_dot_github_repo.present? && related_dot_github_repo.metadata['funding'].present?
      metadata['funding'] = related_dot_github_repo.metadata['funding']
    else
      return if metadata['files']['funding'].blank?
      file = get_file_contents(metadata['files']['funding'])
      return if file.blank?
      metadata['funding'] = YAML.load(file[:content])
    end
    save
  rescue
    nil # invalid yaml
  end

  def related_dot_github_repo
    return nil if project_name == '.github'
    host.repositories.find_by('lower(full_name) = ?', "#{owner}/.github")
  end

  def funding_links
    (owner_funding_links + repo_funding_links).uniq
  end

  def owner_funding_links
    owner_record.try(:funding_links) || []
  end

  def repo_funding_links
    return [] if metadata.blank? ||  metadata["funding"].blank?
    return [] unless metadata["funding"].is_a?(Hash)
    metadata["funding"].map do |key,v|
      next if v.blank?
      case key
      when "github"
        Array(v).map{|username| "https://github.com/sponsors/#{username}" }
      when "tidelift"
        "https://tidelift.com/funding/github/#{v}"
      when "community_bridge"
        "https://funding.communitybridge.org/projects/#{v}"
      when "issuehunt"
        "https://issuehunt.io/r/#{v}"
      when "open_collective"
        "https://opencollective.com/#{v}"
      when "ko_fi"
        "https://ko-fi.com/#{v}"
      when "liberapay"
        "https://liberapay.com/#{v}"
      when "custom"
        v
      when "otechie"
        "https://otechie.com/#{v}"
      when "patreon"
        "https://patreon.com/#{v}"
      else
        v
      end
    end.flatten.compact
  end
end
