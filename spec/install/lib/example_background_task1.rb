require 'cosmos/tools/cmd_tlm_server/background_task'
module Cosmos
  class ExampleBackgroundTask1 < BackgroundTask
    def initialize
      super()
      @name = 'Example Background Task1'
      @status = "This is example one"
      @sleeper = Sleeper.new
    end
    def call
      return if @sleeper.sleep(0.3)
    end
    def stop
      @sleeper.cancel
    end
  end
end
