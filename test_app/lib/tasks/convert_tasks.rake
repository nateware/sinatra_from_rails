namespace :sinatra do
  namespace :from_rails do
    desc "Convert my Rails app to a Sinatra app"
    task :convert => :load do
      Sinatra::FromRails.convert(
        :style => :classic,
        :format => :html,
        :render => 'erb',
      )
    end
  end
end