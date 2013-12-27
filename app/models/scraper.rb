class Scraper < ActiveRecord::Base
  belongs_to :owner, class_name: User
  has_many :runs

  extend FriendlyId
  friendly_id :full_name, use: :finders

  def owned_by?(user)
    owner == user
  end

  def synchronise_repo
    # Set git timeout to 1 minute
    # TODO Move this to a configuration
    Grit::Git.git_timeout = 60
    gritty = Grit::Git.new(repo_path)
    if gritty.exist?
      puts "Pulling git repo #{repo_path}..."
      gritty.pull({:verbose => true, :progress => true})
    else
      puts "Cloning git repo #{git_url}..."
      gritty.clone({:verbose => true, :progress => true}, git_url, repo_path)
    end
  end

  def destroy_repo_and_data
    FileUtils::rm_rf repo_path
    FileUtils::rm_rf data_path
  end

  def repo_path
    "db/scrapers/repos/#{full_name}"
  end

  def data_path
    "db/scrapers/data/#{full_name}"
  end

  def self.docker_image_name
    "scraper"
  end

  def self.build_docker_image!
    # TODO On Linux we'll have access to the "docker" command line which can show standard out which
    # would be very helpful. As far as I can tell this is not currently possible with the docker api gem.

    # TODO Move these Docker setup bits to an initializer
    Docker.validate_version!
    # Set read timeout to a silly 30 minutes (we'll need a bit of time to build an image)
    Docker.options[:read_timeout] = 1800

    puts "Building docker image (this is likely to take a while)..."
    image = Docker::Image.build_from_dir("lib/build_docker_image") {|c| puts c}
    image.tag(repo: docker_image_name, force: true)
  end

  # TODO Should only return the time of the last completed run
  def last_run
    runs.order(started_at: :desc).first
  end

  def last_run_at
    last_run.started_at
  end

  def go
    run = runs.create(started_at: Time.now)
    synchronise_repo
    FileUtils.mkdir_p data_path

    c = Docker::Container.create("Cmd" => ['/bin/bash','-l','-c','ruby /repo/scraper.rb'], "Image" => Scraper.docker_image_name)
    # TODO the local path will be different if docker isn't running through Vagrant (i.e. locally)
    local_root_path = "/vagrant"
    # TODO Run this in the background
    # TODO Capture output to console
    c.start("Binds" => [
      "#{local_root_path}/#{repo_path}:/repo:ro",
      "#{local_root_path}/#{data_path}:/data"
    ])
    puts "Running docker container..."
    p c.attach(stream: true, stdout: true, stderr: true, logs: true) {|s,c| puts c}
    run.update_attribute(:finished_at, Time.now)
  end

  def sqlite_db_path
    "#{data_path}/scraperwiki.sqlite"
  end

  def sql_query(query)
    db = SQLite3::Database.new(sqlite_db_path, results_as_hash: true, type_translation: true, readonly: true)
    db.execute(query)
  end

  def sql_query_safe(query)
    begin
      sql_query(query)
    rescue SQLite3::CantOpenException, SQLite3::SQLException
      nil
    end
  end  
end
