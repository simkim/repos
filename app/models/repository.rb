class Repository < ApplicationRecord
  belongs_to :host
  counter_culture :host
  has_many :manifests, dependent: :destroy
  has_many :dependencies
  has_many :tags

  scope :owner, ->(owner) { where(owner: owner) }
  scope :language, ->(main_language) { where(main_language: main_main_language) }
  scope :fork, ->(fork) { where(fork: fork) }
  scope :archived, ->(archived) { where(archived: archived) }
  scope :active, -> { archived(false) }
  scope :source, -> { fork(false) }
  scope :no_topic, -> { where("topics = '{}'") }
  scope :topic, ->(topic) { where("topics @> ARRAY[?]::varchar[]", topic) }
  
  scope :with_manifests, -> { joins(:manifests).group(:id) }
  scope :without_manifests, -> { includes(:manifests).where(manifests: {repository_id: nil}) }

  def to_s
    full_name
  end

  def to_param
    full_name
  end

  def id_or_name
    uuid || full_name
  end

  def sync
    host.host_instance.update_from_host(self)
  end

  def sync_async
    host.sync_repository_async(full_name)
  end

  def html_url
    host.html_url(self)
  end

  def download_url(branch = default_branch)
    host.download_url(self, branch)
  end

  def avatar_url(size)
    host.avatar_url(self, size)
  end

  def blob_url(sha = nil)
    sha ||= default_branch
    host.blob_url(self, sha = nil)
  end

  def parse_dependencies_async
    ParseDependenciesWorker.perform_async(self.id)
  end

  def parse_dependencies
    connection = Faraday.new(url: "https://parser.ecosyste.ms") do |faraday|
      faraday.use Faraday::FollowRedirects::Middleware
    
      faraday.adapter Faraday.default_adapter
    end
    
    res = connection.post("/api/v1/jobs?url=#{CGI.escape(download_url)}")
    url = res.env.url.to_s
    p url
    while
      json = JSON.parse(res.body)
      status = json['status']
      break if ['complete', 'error'].include?(status)
      puts 'waiting'
      sleep 1
      res = Faraday.get(url)
    end

    if json['status'] == 'complete'
      new_manifests = json['results'].to_h.with_indifferent_access['manifests']
      
      if new_manifests.blank?
        manifests.each(&:destroy)
        return
      end
  
      new_manifests.each {|m| sync_manifest(m) }
  
      delete_old_manifests(new_manifests)

      update_column(:dependencies_parsed_at, Time.now)
    end
  end

  def download_manifests
    file_list = get_file_list
    return if file_list.blank?
    new_manifests = parse_manifests(file_list)

    if new_manifests.blank?
      manifests.each(&:destroy)
      return
    end

    new_manifests.each {|m| sync_manifest(m) }

    delete_old_manifests(new_manifests)

    update_column(:dependencies_parsed_at, Time.now)
  end

  def parse_manifests(file_list)
    manifest_paths = Bibliothecary.identify_manifests(file_list)

    manifest_paths.map do |manifest_path|
      file = get_file_contents(manifest_path)
      if file.present? && file[:content].present?
        begin
          manifest = Bibliothecary.analyse_file(manifest_path, file[:content]).first
          manifest.merge!(sha: file[:sha]) if manifest
          manifest
        rescue
          nil
        end
      end
    end.reject(&:blank?)
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


  # def update_file_list
  #   file_list = get_file_list
  #   return if file_list.nil?
  #   self.readme_path          = file_list.find{|file| file.match(/^README/i) }
  #   self.changelog_path       = file_list.find{|file| file.match(/^CHANGE|^HISTORY/i) }
  #   self.contributing_path    = file_list.find{|file| file.match(/^(docs\/)?(.github\/)?CONTRIBUTING/i) }
  #   self.license_path         = file_list.find{|file| file.match(/^LICENSE|^COPYING|^MIT-LICENSE/i) }
  #   self.code_of_conduct_path = file_list.find{|file| file.match(/^(docs\/)?(.github\/)?CODE[-_]OF[-_]CONDUCT/i) }

  #   save if self.changed?
  # end

  def get_file_contents(path)
    host.get_file_contents(self, path)
  end

  def get_file_list
    host.get_file_list(self)
  end

  def download_tags
    host.download_tags(self)
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
end
