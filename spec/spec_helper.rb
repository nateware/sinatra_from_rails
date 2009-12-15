require 'sinatra/from_rails'

COMPARISON_FILE_DIR = File.expand_path(File.dirname(__FILE__) + '/compare')
OUTPUT_FILE_DIR = File.expand_path(File.dirname(__FILE__) + '/output')
FileUtils.mkdir_p OUTPUT_FILE_DIR

def comparison_file_path(file)
  path_to_some_test_file(COMPARISON_FILE_DIR, file)
end

def output_file_path(file)
  path_to_some_test_file(OUTPUT_FILE_DIR, file)
end

def path_to_some_test_file(dir, file)
  file = "#{file}.rb" if file.is_a? Symbol
  File.join(dir, File.basename(file))
end

def verify_sinatra_from_rails_file(output_file, comparison_file=nil)
  comparison_file = output_file if comparison_file.nil?
  compare = comparison_file_path comparison_file
  a = File.read(output_file)
  b = File.read(compare)
  # weirdness to generate diff
  if a == b
    a.should == b
  else
    system "diff -u #{compare} #{output_file}"
    "Text in #{output_file}".should == "Text in #{compare}"
  end
end