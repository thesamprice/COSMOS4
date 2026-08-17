# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

module Cosmos
  # Formerly backed by a C extension which reimplemented Ruby 1.9 Array
  # internals to avoid heap fragmentation. Modern Ruby manages array memory
  # in size-pooled slots with GC compaction, so the internals hack is both
  # invalid and unnecessary.
  class LowFragmentationArray < Array
    # The C extension's constructor argument was an initial *capacity*, not a
    # length: every caller passes a size hint (DataObject::DEFAULT_ARRAY_SIZE,
    # max_points_plotted + 1) and then pushes into an empty array.
    # Array.new(n) instead yields n nils, which made every data object start
    # life holding 100000 nil samples.
    def initialize(_initial_capacity = 0)
      super()
    end

    # Removes values before the given index, shifting remaining values down
    def remove_before!(index)
      index += length if index < 0
      return self if index < 0
      slice!(0, index) if index > 0
      self
    end
  end
end
