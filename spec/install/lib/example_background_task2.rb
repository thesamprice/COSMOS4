require 'cosmos/tools/cmd_tlm_server/background_task'
module Cosmos
  class ExampleBackgroundTask2 < BackgroundTask
    def initialize
      super()
      @name = 'Example Background Task2'
      @status = "This is example two"
      @sleeper = Sleeper.new
    end
    def call
      loop do
        return if @sleeper.sleep(1)
      end
    end
    def stop
      @sleeper.cancel
    end
  end
end
