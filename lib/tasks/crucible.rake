namespace :crucible do

  namespace :db do
    desc 'Reset DB; by default pulls from a local dump under the db directory.'
    task :reset, [:source] => :environment do |t, args|
      source = "_#{args.source}" if args.source
      dump_archive = File.join('db', "crucible_reset#{source}.tar.gz")
      dump_extract = File.join('tmp', 'crucible_reset')
      target_db = Mongoid.default_session.options[:database]
      puts "Resetting #{target_db} from #{dump_archive}"
      Mongoid.default_session.with(database: target_db) { |db| db.drop }
      system "tar xf #{dump_archive} -C tmp"
      system "mongorestore -d #{target_db} --batchSize=1 #{dump_extract}"
      FileUtils.rm_r dump_extract
    end
  end


  desc "Execute all tests against all servers"
  task :test_all => [:environment] do

    Server.all.each_with_index do |s, i|
      puts "\tStarting Server #{i+1} of #{Server.all.length}"

      test_run = TestRun.new({server: s})
      test_run.add_tests(Test.where({multiserver: false}).sort {|l,r| l.name <=> r.name})
      test_run.execute() do |result, j, total|
        puts "\tCompleted test #{j+1} of #{total} on Server #{i+1} of #{Server.all.length}"
      end

      puts "\tCompleted Server #{i+1} of #{Server.all.length}"

    end
  end

  desc "schedule a job for all servers"
  task :nightly_run => [:environment] do

    # currently we exclude servers tagged argonaut from the nightly run
    excluded_tags = ['argonaut']

    servers = Server.all.select {|s| (s.tags & excluded_tags).empty?}.sort {|l,r| (r.percent_passing||0) <=> (l.percent_passing||0)}

    servers.each_with_index do |s, i|

      if TestRun.where(:server => s, :status.in => ['pending', 'running']).length == 0

        tests = Test.where({multiserver: false}).sort {|l,r| l.name <=> r.name}
        tests.select! { |t| s.supported_suites.include? t.id }

        if tests.length > 0
          test_run = TestRun.new({server: s, date: Time.now, nightly: true, supported_only: true})
          test_run.add_tests(tests)
          test_run.save!
          RunTestsJob.perform_later(test_run.id.to_s)
          puts "\tStarted Testing Server #{i+1} of #{servers.length}"
        else
          puts "\tNo supported test suites for server #{s.id}"
        end
      else
        puts "\tServer #{i+1} of #{servers.length} is already under test"
      end

    end

  end

  desc "identify stalled tasks and rerun"
  task :restart_stalled_runs => [:environment] do

    TestRun.where(:status=> 'running', :last_updated.lte => 10.minutes.ago).each do |test_run|

      test_run.status = 'stalled'
      test_run.save

      RunTestsJob.perform_later(test_run.id.to_s)
      
    end

  end

  desc "back fill blank names"
  task :guess_server_names => [:environment] do
    Server.all.select {|s| s.name.blank?}.each {|s| s.guess_name}
  end

  desc "remove duplicate servers"
  task :remove_duplicate_servers, [:delete] => :environment do |t, args|
    servers = Server.all
    servers_by_url = {}

    servers.each do |server|
      url = PostRank::URI.normalize(server.url).to_s
      url = url.chop if url[-1] == '/'
      servers_by_url[url] ||= []
      servers_by_url[url] << server
    end

    servers_by_url.values.each do |list|
      next if list.length <= 1
      list.sort! do |l,r|
        if (l.name_guessed != r.name_guessed)
          (l.name_guessed ? 0 : 1) <=> (r.name_guessed ? 0 : 1)
        else
          (l.summary.try(:generated_at)||Time.new(0)) <=> (r.summary.try(:generated_at)||Time.new(0))
        end
      end
      keep = list.pop
      puts "Keeping 1 of #{list.length+1}: #{keep.name} => #{keep.url}"
      list.each do |server|
        puts "\tDeleting: #{server.name} => #{server.url}"
        server.delete() if args.delete
      end
    end

  end

  desc "cleanup bad servers"
  task :servers_cleanup, [:delete] => :environment do |t, args|
    print 'checking'
    bad = Server.all.select do |s|
      print '.'
      $stdout.flush
      s.summary.nil? && s.name_guessed && s.client_id.nil? && s.tags.blank? && !s.available?
    end
    bad.each do |server|
      puts "Deleting: #{server.name}: #{server.url}"
      server.delete() if args.delete
    end
  end

  desc "cleanup orphaned test runs"
  task :test_runs_cleanup, [:age] => :environment do |t, args|
    age = args.age.nil? ? (Time.now - 1.day).to_s : DateTime.parse(args.age).to_s
    TestRun.where(:date.lte => age, :status.in => ["pending", "running"]).update_all(status: 'cancelled')
  end

  desc "upgrade db to store generated_at from summary at the server level"
  task :copy_generated_at_to_server => [:environment] do

    Server.each do |server|
      server.last_run_at = server.summary.generated_at unless server.summary.nil?
      server.save
    end

  end

end
