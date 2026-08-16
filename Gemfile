# encoding: ascii-8bit
source 'https://rubygems.org'

# The legacy qtbindings gem only builds against Qt 4.8 and Ruby <= 2.x.
# It is opt-in while the GUI layer migrates to the new libclang-generated
# Qt 6 bindings. Set COSMOS_QT4=1 to install it (requires a Qt 4.8 toolchain).
if ENV['COSMOS_QT4']
  gem 'ffi', '< 1.15' # Prevent trying to install the newer, incompatible musl version
  gem 'qtbindings', git: 'https://github.com/thesamprice/qtbindings.git', branch: 'master'
end

gem 'ruby-termios', '>= 0.9' if RbConfig::CONFIG['target_os'] !~ /mswin|mingw|cygwin/i and RUBY_ENGINE == 'ruby'

gemspec

# DART depends on Rails 5.1 which does not support modern Ruby.
# Set COSMOS_DART=1 to include it (requires an older Ruby).
instance_eval File.read(File.join(__dir__, 'install/config/dart/Gemfile')) if ENV['COSMOS_DART'] && !ENV['CI']
