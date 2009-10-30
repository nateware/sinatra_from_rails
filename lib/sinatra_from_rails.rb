# Sinatra::FromRails
require 'active_support/core_ext'
module Sinatra
  module FromRails
    # Settings
    mattr_accessor :debug
    @@debug = false

    mattr_accessor :format
    @@format = :xml
    
    mattr_accessor :output_file
    @@output_file = 'main.rb'

    mattr_accessor :output_dir
    @@output_dir = 'app/routes'

    mattr_accessor :style
    @@style = :classic  # or :modular

    mattr_accessor :class_name
    @@class_name = 'Main'  # for :modular
    
    mattr_accessor :ignore_routes
    @@ignore_routes = []

    mattr_accessor :controllers
    @@controllers = nil
    
    mattr_accessor :ignore_actions
    @@ignore_actions = [:new, :edit]
    
    mattr_accessor :any_request_method
    @@any_request_method = :post
    
    # What to use to render
    mattr_accessor :render_method
    @@render_method = 'xml'  #'builder'

    # How to translate head :ok from Rails
    mattr_accessor :head_ok_method
    @@head_ok_method = 'halt 200'

    # How to translate head :error from Rails
    mattr_accessor :head_error_method
    @@head_error_method = 'halt 500'

    mattr_accessor :format, :output_file

    class << self
      def debug(options={})
        @@debug = true
        convert(options)
      end

      def debug=(bool); @@debug = bool; end
      def debug?; @@debug; end

      # Convert a Rails application to a Sinatra application.  Takes the following options
      #   :format         format.xyz to convert (default: xml)
      #   :style          type of Sinatra app to generate, either :classic or :modular (default: :classic)
      #   :output_file    filename to write for classic apps (default: main.rb)
      #   :output_dir     directory to write to for modular apps (default: app/routes)
      #   :class_name     name of the class to generate for modular app (default: Main)
      #   :controllers    only convert controllers in this list, if defined
      def convert(options={})
        self.format = options[:format] || Sinatra::FromRails.format
        self.output_file  = options[:output_file]  || Sinatra::FromRails.output_file
        self.output_dir   = options[:output_dir]   || Sinatra::FromRails.output_dir
        self.style = options[:style] || Sinatra::FromRails.style
        self.class_name   = options[:class_name] || Sinatra::FromRails.class_name
        self.controllers  = options[:controllers] || Sinatra::FromRails.controllers

        puts "Generating Sinatra application for all routes (format = #{format})"
        write convert_controllers parse_routes
      end

      def parse_routes
        saw_url = {} # avoid regen for dup routes
        controller_map = {}
        ActionController::Routing::Routes.routes.each do |route|
          controller_name = route.requirements[:controller].to_s

          # Handle Rails inflection bugs
          controller_name =
            case controller_name
            when 'rss_preferenceses' then 'rss_preferences'
            when 'player_metricses' then 'player_metrics'
            when 'match_preferenceses' then 'match_preferences'
            when 'preferenceses' then 'preferences'
            else controller_name
            end

          next if controller_name =~ /\badmin\b/ # precaution
          next unless route.requirements[:action]  # map.connect
          action_name = route.requirements[:action].to_s
          puts "controller_name=#{controller_name}, singular=#{controller_name.singularize}, action_name=#{action_name} #{route.requirements.inspect}" if Sinatra::FromRails.debug?
          route_url   = "#{controller_name}/#{action_name}"

          # Env var we can set for quicker dev testing
          next if self.controllers && !self.controllers.include?(controller_name.to_s)

          # dup catch - can happen frequently so silence output
          if saw_url[route_url]
            printf "        skip  %-40s (duplicate route)\n", route_url if Sinatra::FromRails.debug?
            next
          end
          saw_url[route_url] = true

          # Ignore any explicit actions or routes
          if Sinatra::FromRails.ignore_routes.include?(route_url) ||
             Sinatra::FromRails.ignore_actions.include?(action_name.to_sym)
            printf "      ignore  %-40s\n", route_url
            next
          end

          # Next, pull out the method definition for this, which is the block of code to
          # the next def or ^end (end of the file).
          controller_file = nil
          controller_file_paths = ["#{RAILS_ROOT}/app/controllers/#{controller_name}_controller.rb"]
          if TitleDir.exists?
            controller_file_paths.unshift File.join(TitleDir.dir, 'app', 'controllers', "#{controller_name}_controller.rb")
          end
          controller_file_paths.each do |controller_file_path|
            controller_file = controller_file_path if File.exists?(controller_file_path)
          end
          unless controller_file
            raise "Fatal: Missing controller for route: #{route_url}. Looked for #{controller_file_paths.join(', and ')}"
          end

          # Rails' routing internals are a bit convoluted
          request_url    = route.segments.join.sub(/\(?\.:format\)?\??/, ".#{self.format}")
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
          format_do_buf = ''
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
              format_do_buf = ''
              format_do_ends = 0
              indent = self.style == :classic ? '  ' : '    '
              num_ends = 1  # def index

              # lookup route in our map
              action_name = $1.to_s
              route_spec = actions[action_name]
              unless route_spec
                skip_this_action = true
                next
              end

              f << (self.style == :classic ? '' : '  ') +  "#{route_spec.first} '#{route_spec.last}' do\n"
            when /^\s+respond_to\s+(?:do|\{)\s*\|\w+\|\s*\n/
              in_respond_to = true
              num_ends += 1
            when /^\s+format.(\w+)\s*(\{)(.+)\}/, /^\s+format.(\w+)\s*(do)\s+/
              wrong_format_type = $1.to_s != self.format.to_s # prune format.js/etc
              found_correct_format ||= !wrong_format_type
              puts "[#{view_path}/#{action_name}:#{linenum}] #{action_name} format? #{found_correct_format} ||= #{!wrong_format_type}" if debug?
              if in_format_do = $2.to_s == 'do'
                format_do_ends += 1
                next
              end
              next if wrong_format_type
              unless in_respond_to
                raise "Failed to parse format.#{self.format} block in #{view_path}/#{action_name}: Not in respond_to"
              end
              f << parse_format_block($3.to_s, view_path, action_name, indent)
            when /^\s+format.(\w+)\s*$/
              # empty format.xml, meaning all defaults
              wrong_format_type = $1.to_s != self.format.to_s # prune format.js/etc
              found_correct_format ||= !wrong_format_type
              next if wrong_format_type
              f << "#{indent}#{render_method} :'#{view_path}/#{action_name}'\n"
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
                format_do_buf = ''
              elsif in_respond_to && num_ends == 0
                in_respond_to = false
              else
                if num_ends == 0  # special because controllers are different nesting
                  style == :modular ? f << "  end\n" : "end\n"
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
        case self.style
        when :classic
          # Single file
          printf "       write  %-40s\n", self.output_file
          File.open(self.output_file, 'w') do |f|
            f << "##\n"
            f << "# Generated by rake #{ARGV * ' '}\n"
            f << "#\n"
            new_files.each do |file|
              f << "\n# #{file.first.sub(/\.rb$/,'').humanize}\n"
              f << file.last
            end
          end
        when :modular
          # Separate files
          new_files.each do |file|
            filename = "#{self.output_dir}/#{file.first}"
            printf "       write  %-40s\n", filename
            File.open(filename, 'w') do |f|
              f << "##\n"
              f << "# Generated by rake #{ARGV * ' '}\n"
              f << "#\n"
              f << "class #{class_name}\n"
              f << file.last
              f << "end # class #{class_name}\n" 
            end
          end
        else
          raise "Invalid style for Sinatra::FromRails: #{self.style} (must be :classic or :modular)"
        end
      end

      def parse_format_block(format_block, view_path, action_name, indent='')
        f = ''
        case format_block
        when /^\s*head\s+:ok/
          f << "#{indent}#{head_ok_method}  # no response\n"
        when /^\s*head\s+:error/
          f << "#{indent}#{head_error_method}\n"
        when /^\s*render\s+:action\s*=>\s*[:'"](\w+)/
          puts "#{format_block} => render=#{view_path}/#{$1}" if debug?
          f << "#{indent}#{render_method} :'#{view_path}/#{$1}'\n"
        when /^\s*render\s+:(\w+)\s*=>\s*(.+)/
          fmt = $1.to_s
          var = $2.to_s.chomp.strip
          var.sub!(/,\s+:status.*/,'')  # render :xml => @foo, :status => :error
          puts "var = '#{var}'" if debug?
          f << "#{indent}#{var}.to_#{fmt}\n"
        when /^\s*(raise.+)/
          # format.xml  { raise PlayerCreationError::CreationUploadFailed }
          f << "#{indent}#{$1}\n"
        when /^\s*(\@.+)/
          # format.xml { @servers_of_type = Server.find_by_type(params[:server][:server_type_id]) }
          f << "#{indent}#{format_block}\n"
          f << "#{indent}#{render_method} :'#{view_path}/#{action_name}'\n"
        else
          raise "Failed to parse format.#{self.format} block in #{view_path}:\n    #{format_block}"
        end
        f
      end

    private
      # maintain minimum indent
      def outdent(indent, is_end=false)
        s = indent.sub(/^  /,'')
        l = style == :classic ? 2 : 4
        l -= 2 if is_end
        s.length < l ? (' ' * l) : s
      end
    
      def path_minus_rails_root(path)
        path.sub(/^#{File.dirname(RAILS_ROOT)}\//,'')
      end

      # ensure the "name=xyz" attribute is always first on a line by line basis
      def name_first(str)
        str.gsub(/^(\s*)(<\w+)(.*)(\s+name="[\w.]+")/, '\1\2\4\3')
      end
    end
  end
end