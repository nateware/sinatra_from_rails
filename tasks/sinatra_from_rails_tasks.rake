# desc "Explaining what the task does"
# task :sinatra_from_rails do
#   # Task goes here
# end
require File.dirname(__FILE__) + '/../lib/sinatra_from_rails'
def parse_controllers_env_var_for_task
  ENV['CONTROLLER'] ? Array(ENV['CONTROLLER']) : ENV['CONTROLLERS'] ? ENV['CONTROLLERS'].split(',') : nil
end
namespace :sinatra do
  namespace :from_rails do
    task :load do
      require "#{RAILS_ROOT}/config/environment"
    end

    desc "Generate Sinatra classic application from Rails controllers/routes"
    task :classic => :load do
      Sinatra::FromRails.convert(:style => :classic, :format => ENV['FORMAT'],
                                 :output_file => ENV['OUTPUT_FILE'],
                                 :controllers => parse_controllers_env_var_for_task)
    end

    desc "Generate Sinatra modular application from Rails controllers/routes"
    task :modular => :load do
      Sinatra::FromRails.convert(:style => :modular, :format => ENV['FORMAT'],
                                 :output_dir => ENV['OUTPUT_DIR'],
                                 :class_name => ENV['CLASS_NAME'],
                                 :controllers => parse_controllers_env_var_for_task)
    end

    # For testing purposes only
    task :debug => :load do
      Sinatra::FromRails.debug(:format => :xml)
    end

    task :from_rails => 'sinatra:from_rails:generate'
  end
end
