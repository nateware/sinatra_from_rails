require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

describe Sinatra::FromRails do
  before :all do
    Dir.chdir(File.dirname(__FILE__) + '/../test_app')
  end
  
  it "should convert HTML controllers to a classic style app" do
    outfile = output_file_path :main_html
    system "rake sinatra:from_rails:classic OUTPUT_FILE=#{outfile}"
    verify_sinatra_from_rails_file(outfile)
  end

  it "should convert XML controllers to a classic style app" do
    outfile = output_file_path :main_xml
    system "rake sinatra:from_rails:classic OUTPUT_FILE=#{outfile} FORMAT=xml RENDER=builder"
    verify_sinatra_from_rails_file(outfile)
  end
end
