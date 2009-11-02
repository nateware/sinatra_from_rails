# Sinatra::FromRails
require 'active_support/core_ext'
module Sinatra
  module FromRails
    DEFAULT_SETTINGS = {
      :debug  => false,
      :format => :html,
      :style  => :classic,
      :output_file => 'main.rb',
      :output_dir  => 'app/routes',
      :class_name  => 'Main',
      :controllers => nil,
      :ignore_routes => [],
      :ignore_actions => [],
      :any_request_method => :post,
      :render  => 'erb',
      :head_ok => 'halt 200',
      :head_error => 'halt 500'
    }
    mattr_accessor :settings
    @@settings = {}

    PLUGIN_URL = 'http://github.com/nateware/sinatra_from_rails'

    class << self
      def defaults
        puts "Available Sinatra::FromRails settings with their defaults:"
        puts
        DEFAULT_SETTINGS.each do |var,val|
          printf "    :%-20s  %-20s  %s\n", var, var.upcase, (val.nil? ? 'nil' : val)
        end
        puts
        puts "To use in a rake sinatra:from_rails task, use the ALLCAPS version:"
        puts
        puts "    rake sinatra:from_rails:classic OUTPUT_FILE=application.rb"
        puts "    rake sinatra:from_rails:modular FORMAT=xml IGNORE_ACTIONS=new,edit RENDER=builder"
        puts
      end

      def debug(options={})
        self.settings[:debug] = true
        convert(options)
      end

      def debug=(bool); self.settings[:debug] = bool; end
      def debug?; self.settings[:debug]; end

      # Convert a Rails application to a Sinatra application.  Takes the following options
      #   :format         format.xyz to convert (default: xml)
      #   :style          type of Sinatra app to generate, either :classic or :modular (default: :classic)
      #   :output_file    filename to write for classic apps (default: main.rb)
      #   :output_dir     directory to write to for modular apps (default: app/routes)
      #   :class_name     name of the class to generate for modular app (default: Main)
      #   :controllers    only convert controllers in this list, if defined
      # An environment variable named for each of those is also accepted
      def convert(options={})
        DEFAULT_SETTINGS.each do |var,val|
          env = var.to_s.upcase
          if ENV.has_key?(env)
            # Handle env_var=a,b,c => var => [a,b,c]
            if val.is_a?(Array)  # default
              self.settings[var] = ENV[env].split(',')
            else
              self.settings[var] = ENV[env]
            end
          elsif options.has_key?(var)
            self.settings[var] = options[var]
          else
            self.settings[var] = val
          end
        end

        # Nicety for testing mainly
        self.settings[:controllers] =
          ENV['CONTROLLER'] ? Array(ENV['CONTROLLER']) : ENV['CONTROLLERS'] ? ENV['CONTROLLERS'].split(',') : nil

        puts <<-EndBanner
Generating #{settings[:style]} Sinatra application for Rails actions with format.#{self.settings[:format]}
EndBanner
        write convert_controllers parse_routes
      end

      def parse_routes
        saw_url = {} # avoid regen for dup routes
        controller_map = {}
        ActionController::Routing::Routes.routes.each do |route|
          controller_name = route.requirements[:controller].to_s

          # Handle Rails inflection bugs - "preferenceses" and "metricses"
          controller_name.sub!(/eses$/, 'es')
          controller_name.sub!(/cses$/, 'cs')

          next if controller_name =~ /\badmin\b/ # precaution
          next unless route.requirements[:action]  # map.connect
          action_name = route.requirements[:action].to_s
          puts "controller_name=#{controller_name}, singular=#{controller_name.singularize}, action_name=#{action_name} #{route.requirements.inspect}" if Sinatra::FromRails.debug?
          route_url   = "#{controller_name}/#{action_name}"

          # Env var we can set for quicker dev testing
          next if settings[:controllers] && !settings[:controllers].include?(controller_name.to_s)

          # dup catch - can happen frequently so silence output
          if saw_url[route_url]
            printf "        skip  %-40s (duplicate route)\n", route_url if debug?
            next
          end
          saw_url[route_url] = true

          # Ignore any explicit actions or routes
          if settings[:ignore_routes].include?(route_url) ||
             settings[:ignore_routes].include?(action_name.to_sym)
            printf "      ignore  %-40s\n", route_url
            next
          end

          # Next, pull out the method definition for this, which is the block of code to
          # the next def or ^end (end of the file).
          controller_file = nil
          controller_file_paths = ["#{RAILS_ROOT}/app/controllers/#{controller_name}_controller.rb"]
          if defined?(TitleDir) && TitleDir.exists?
            controller_file_paths.unshift File.join(TitleDir.dir, 'app', 'controllers', "#{controller_name}_controller.rb")
          end
          controller_file_paths.each do |controller_file_path|
            controller_file = controller_file_path if File.exists?(controller_file_path)
          end
          unless controller_file
            raise "Fatal: Missing controller for route: #{route_url}. Looked for #{controller_file_paths.join(', and ')}"
          end

          # Rails' routing internals are a bit convoluted
          request_url    = route.segments.join
          if settings[:format].to_sym == :html
            request_url.sub!(/\(?\.:format\)?\??/, '')
          else
            request_url.sub!(/\(?\.:format\)?\??/, ".#{settings[:format]}")
          end
          request_method = route.conditions[:method]
          unless request_method
            puts "  Warning: Route specified :any method for: #{controller_name}/#{action_name} (using :#{Sinatra::FromRails.any_request_method})"
            #raise("Must specify method of :get, :post, :put, or :delete for route: #{controller_name}/#{action_name} (#{route})")
            request_method = Sinatra::FromRails.any_request_method
          end

          controller_map[controller_file] ||= {}
          controller_map[controller_file][action_name] = [request_method, request_url]
        end
        controller_map
      end

      def convert_controllers(controller_map)
        new_files = []

        # We now re-loop over our controller_map, opening each controller.rb file in turn.
        # Then, we walk our controller file line-by-line, looking at each "def action"
        # method, and look for a match in our controller_map.  If a match is not found,
        # we fast-forward to the next "def action" and rinse/repeat
        controller_map.each do |controller_file,actions|
          input_file = File.read(controller_file)
          view_path  = File.basename(controller_file).sub(/_controller.*/,'')

          # output
          new_file = view_path + '.rb'
          new_buf = ''  # buffer

          # state machine
          f = ''
          indent = ''
          num_ends = 0
          linenum = 0
          action_name = nil
          in_respond_to = false
          in_format_do  = false # in format do rather than format {}
          format_do_buf = []
          format_do_ends = 0
          wrong_format_type = false
          found_correct_format = false
          skip_this_action = false

          input_file.lines.each do |line|
            # This error will be triggered if we aren't properly counting if/do/while nesting.
            # The usual culprits are format do .. end or respond_to do .. end with if/end in between.
            puts "[#{view_path}/#{action_name}:#{linenum}] (num_ends=#{num_ends}, in_respond_to=#{in_respond_to}, in_format_do=#{in_format_do}, format_do_ends=#{format_do_ends}) LINE:#{line.chomp}\$" if debug?
            raise "[#{view_path}/#{action_name}:#{linenum}] Parsing error: Somehow end block count went negative" if num_ends < 0

            linenum += 1
            next if skip_this_action
            puts "f={#{f}}" if debug?
            
            # Must explicitly check for these since Ruby uses #{} inside a string which SUCKS for us
            line.sub!(/^#.*|^\s+#.*|\s+#.*/,'')
            next if line =~ /^$|^\s*#/  # empty line or commented-out code
            puts "[#{view_path}/#{action_name}:#{linenum}] (indent='#{indent}') / LINE='#{line}'" if debug?
            case line
            when /^\s*class/
              next
            when /^\s*$/
              f << ''  # squish blank lines
            when /^\s*def\s+(\w+)\b/
              new_buf << f + "\n" if found_correct_format  # previous action
              f = ''
              puts "[#{view_path}/#{action_name}:#{linenum}] **** Appending f={#{f}}" if found_correct_format && debug?

              # reset state machine
              in_respond_to = false
              in_format_do  = false # in format do rather than format {}
              wrong_format_type = false
              found_correct_format = false
              format_do_buf = []
              format_do_ends = 0
              indent = settings[:style] == :classic ? '  ' : '    '
              num_ends = 1  # def index

              # lookup route in our map
              action_name = $1.to_s
              route_spec = actions[action_name]
              unless route_spec
                skip_this_action = true
                next
              end

              f << (settings[:style] == :classic ? '' : '  ') +  "#{route_spec.first} '#{route_spec.last}' do\n"
            when /^\s+respond_to\s+(?:do|\{)\s*\|\w+\|\s*\n/
              in_respond_to = true
              num_ends += 1
            when /^\s+format.(\w+)\s*(\{)(.+)\}/, /^\s+format.(\w+)\s*(do)\s+/
              wrong_format_type = $1.to_s != settings[:format].to_s # prune format.js/etc
              found_correct_format ||= !wrong_format_type
              puts "[#{view_path}/#{action_name}:#{linenum}] #{action_name} format? #{found_correct_format} ||= #{!wrong_format_type}" if debug?
              if in_format_do = $2.to_s == 'do'
                format_do_ends += 1
                indent += '  '
                next
              end
              next if wrong_format_type
              unless in_respond_to
                raise "Failed to parse format.#{settings[:format]} block in #{view_path}/#{action_name}: Not in respond_to"
              end
              f << parse_format_block([$3.to_s], view_path, action_name, indent)
            when /^\s+format.(\w+)\s*$/
              # empty format.xml, meaning all defaults
              wrong_format_type = $1.to_s != settings[:format].to_s # prune format.js/etc
              found_correct_format ||= !wrong_format_type
              next if wrong_format_type
              f << "#{indent}#{settings[:render]} :'#{view_path}/#{action_name}'\n"
            when /^\s+flash\[.*/
              next  # prune flash
            when /^end\s*$/
              #num_ends -= 1
              next  # final end in controller
            when /^\s+end\s*$/
              # other ends to close if/else/each
              if in_format_do
                format_do_ends -= 1
              else
                num_ends -= 1
              end
              indent = outdent(indent, true)
              if in_format_do && format_do_ends == 0 # if / format / else / if / format / format / ugh
                f << parse_format_block(format_do_buf, view_path, action_name, indent) unless wrong_format_type
                in_format_do = false
                format_do_buf = []
              elsif in_respond_to && num_ends == 0
                in_respond_to = false
              else
                if num_ends == 0  # special because controllers are different nesting
                  settings[:style] == :modular ? f << "  end\n" : "end\n"
                else
                  f << line.chomp.sub(/^\s+/, indent) + "\n"
                end
              end
              puts "[#{view_path}/#{action_name}:#{linenum}] end: in_respond_to=#{in_respond_to}, in_format_do=#{in_format_do}, num_ends=#{num_ends}" if debug?
            when /^\s+(else|elsif)\s*$/
              f << line.chomp.sub(/^\s+/, outdent(indent)) + "\n"
            else
              if in_format_do
                format_do_buf << line
              else
                f << line.chomp.sub(/^\s+/, indent) + "\n" # if/do/while/anything else Ruby
                puts "[#{view_path}/#{action_name}:#{linenum}] (indent='#{indent}') LINE='#{line.sub(/^\s+/, indent)}' / ENDS=#{num_ends}" if debug?
              end
              # This regex is ugly because "if blah; foo; end" is different than "foo if blah" 
              if line =~ /^\s*if\b|\beach\b|\bdo\b|^\s*while\b|^\s*for\b|^\s*unless\b|^\s*until\b|^\s*begin\b|^\s*case\b/
                if in_format_do
                  format_do_ends += 1
                else
                  indent += '  '
                  num_ends += 1
                end
                puts "[#{view_path}/#{action_name}:#{linenum}] indent++: #{line}" if debug?
              end
            end # case line
          end # lines
          new_buf << f if found_correct_format  # last action in file
          puts "[#{view_path}/#{action_name}:#{linenum}] ++++ Appending f={#{f}}" if found_correct_format && debug?
          new_files << [new_file, new_buf]
        end # files.each
        new_files
      end
      
      # Write the resultant Sinatra application, either as a single file (classic) or 
      # separate files per controller (modular)
      def write(new_files)
        case settings[:style]
        when :classic
          # Single file
          printf "Writing classic app to: %s\n", settings[:output_file]
          File.open(settings[:output_file], 'w') do |f|
            f << "##\n"
            f << "# Generated by \"rake #{ARGV * ' '}\"\n"
            f << "# Keep up to date: #{PLUGIN_URL}\n"
            f << "#\n"
            new_files.each do |file|
              f << "\n# #{file.first.sub(/\.rb$/,'').humanize}\n"
              f << file.last
            end
          end
        when :modular
          # Separate files
          new_files.each do |file|
            filename = "#{settings[:output_dir]}/#{file.first}"
            printf "       write  %-40s\n", filename
            File.open(filename, 'w') do |f|
              f << "##\n"
              f << "# Generated by \"rake #{ARGV * ' '}\"\n"
              f << "# Keep up to date: #{PLUGIN_URL}\n"
              f << "#\n"
              f << "class #{class_name}\n"
              f << file.last
              f << "end # class #{class_name}\n" 
            end
          end
        else
          raise "Invalid style for Sinatra::FromRails: #{settings[:style]} (must be :classic or :modular)"
        end
      end

    private

      def parse_format_block(format_block, view_path, action_name, indent='')
        r = format_block.pop
        f = format_block.map{|l| l.gsub(/^\s+/,indent)}.join
        case r
        when /^\s*head\s+:ok/
          f << "#{indent}#{settings[:head_ok]}\n"
        when /^\s*head\s+:error/
          f << "#{indent}#{settings[:head_error]}\n"
        when /^\s*render\s+:action\s*=>\s*[:'"](\w+)/
          puts "#{r} => render=#{view_path}/#{$1}" if debug?
          f << "#{indent}#{settings[:render]} :'#{view_path}/#{$1}'\n"
        when /^\s*render\s+:(\w+)\s*=>\s*(.+)/
          fmt = $1.to_s
          var = $2.to_s.chomp.strip
          var.sub!(/,\s+:status.*/,'')  # render :xml => @foo, :status => :error
          puts "var = '#{var}'" if debug?
          f << "#{indent}#{var}.to_#{fmt}\n"
        when /^\s*redirect_to\(?\s*@(\w+)/
          # Some BS Rails helper - try our best to fake it
          base = $1.to_s
          sing = base.singularize
          if base == sing
            # post_url(@post)
            f << "#{indent}redirect \"/#{base.pluralize}/#\{@#{$1}.to_param\}\"\n"
          else
            f << "#{indent}redirect '/#{base.pluralize}'\n"
          end
        when /^\s*redirect_to\(?\s*(\w+)_url(\(.+\))?/
          # Some BS Rails helper - try our best to fake it
          base = $1.to_s
          sing = base.singularize
          if base == sing
            # post_url(@post)
            f << "#{indent}redirect \"/#{base.pluralize}/#\{#{$2}.to_param\}\"\n"
          else
            f << "#{indent}redirect '/#{base.pluralize}'\n"
          end
        when /^\s*redirect_to\(?\s*(\S+)/
          url = $1.to_s.sub(/\)/,'')
          f << "#{indent}redirect '#{url}'\n"
        when /^\s*(raise.+)/
          # format.xml  { raise PlayerCreationError::CreationUploadFailed }
          f << "#{indent}#{$1}\n"
        when /^\s*(\@.+)/
          # format.xml { @servers_of_type = Server.find_by_type(params[:server][:server_type_id]) }
          f << "#{indent}#{r}\n"
          f << "#{indent}#{settings[:render]} :'#{view_path}/#{action_name}'\n"
        else
          raise "Failed to parse format.#{settings[:render]} block in #{view_path}:\n    #{format_block}"
        end
        f
      end

      # maintain minimum indent
      def outdent(indent, is_end=false)
        s = indent.sub(/^  /,'')
        l = settings[:style] == :classic ? 2 : 4
        l -= 2 if is_end
        s.length < l ? (' ' * l) : s
      end
    end
  end
end