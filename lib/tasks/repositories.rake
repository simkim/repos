namespace :repositories do
  desc 'sync least recently synced repos'
  task sync_least_recent: :environment do 
    Repository.order('last_synced_at ASC').limit(5_000).select('id').each(&:sync_async)
  end

  desc 'sync repos that have been recently active'
  task sync_recently_active: :environment do 
    Host.all.each do |host|
      host.sync_recently_changed_repos_async
    end
  end

  desc 'parse missing dependencies'
  task parse_missing_dependencies: :environment do 
    Repository.parse_dependencies_async
  end

  desc 'download tags'
  task download_tags: :environment do 
    host = Host.find_by_name('GitHub')
    host.host_instance.sync_repos_with_tags
  end

  desc 'crawl repositories'
  task crawl: :environment do
    Host.all.each do |host|
      host.crawl_repositories_async
    end
  end
end