require 'mkmf'

# Buffered C++ I/O backends. C++17 for std::thread / std::atomic / chrono.
$CXXFLAGS << ' -std=c++17'

unless $CFLAGS.gsub!(/ -O[\dsz]?/, ' -O3')
  $CFLAGS << ' -O3'
end
unless $CXXFLAGS.gsub!(/ -O[\dsz]?/, ' -O3')
  $CXXFLAGS << ' -O3'
end
if CONFIG['CC'] =~ /gcc|clang/
  $CXXFLAGS << ' -Wall'
  if $DEBUG && !$CXXFLAGS.gsub!(/ -O[\dsz]?/, ' -O0 -ggdb')
    $CXXFLAGS << ' -O0 -ggdb'
  end
end

create_makefile 'cosmos/ext/buffered_io'
