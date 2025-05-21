# encoding: ascii-8bit
gem 'ffi', '< 1.15'  # Prevent trying to install the newer, incompatible musl version
source 'https://rubygems.org'
gem 'qtbindings', git: 'https://github.com/thesamprice/qtbindings.git', branch: 'master' # or your branch name
gem 'ruby-termios', '>= 0.9' if RbConfig::CONFIG['target_os'] !~ /mswin|mingw|cygwin/i and RUBY_ENGINE == 'ruby'
# This is commented out because wdm does not currently support Ruby 2.2
#group :development do
#  gem 'wdm', '>= 0.1.0', :platforms => [:mswin, :mingw]
#end
gemspec
instance_eval File.read(File.join(__dir__, 'install/config/dart/Gemfile')) unless ENV['CI']
