require File.dirname(__FILE__) + '/../lib/sinatra/from_rails'

namespace :sinatra do
  namespace :from_rails do
    task :load do
      require "#{RAILS_ROOT}/config/boot"
      Rails::Initializer.run do |config|
        config.frameworks = [:action_controller]
      end
    end

    desc "Generate a Sinatra classic application from Rails controllers/routes"
    task :classic => :load do
      Sinatra::FromRails.convert(:style => :classic)
    end

    desc "Generate a Sinatra modular application from Rails controllers/routes"
    task :modular => :load do
      Sinatra::FromRails.convert(:style => :modular)
    end

    desc "Print rake sinatra:from_rails settings and their defaults"
    task :defaults do
      Sinatra::FromRails.defaults
    end

    # For testing purposes only
    task :debug => :load do
      Sinatra::FromRails.debug(:style => :classic)
    end

    task :from_rails => 'sinatra:from_rails:generate'
  end
end
