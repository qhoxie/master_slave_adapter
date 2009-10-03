module ActiveRecord

  module ConnectionAdapters

    class MasterSlaveAdapter

      SELECT_METHODS = [ :select_all, :select_one, :select_rows, :select_value, :select_values ]
      HOOK_POINTS = [ :after_error ]

      include ActiveSupport::Callbacks
      define_callbacks :checkout, :checkin

      checkout :test_connections

      attr_accessor :connections
      attr_accessor :master_config
      attr_accessor :slave_config
      attr_accessor :disable_connection_test


      delegate :select_all, :select_one, :select_rows, :select_value, :select_values, :to => :slave_connection

      def initialize( config )
        if config[:master].blank?
          raise "There is no :master config in the database configuration provided -> #{config.inspect} "
        end
        self.slave_config = config.symbolize_keys
        self.master_config = self.slave_config.delete(:master).symbolize_keys
        self.slave_config[:adapter] = self.slave_config.delete(:master_slave_adapter)
        self.master_config[ :adapter ] ||= self.slave_config[:adapter]
        self.disable_connection_test = self.slave_config.delete( :disable_connection_test ) == 'true'
        self.connections = []
        if self.slave_config.delete( :eager_load_connections ) == 'true'
          connect_to_master
          connect_to_slave
        end

        @hooks = HOOK_POINTS.inject({}) do |_, point|
          _[point] = []
          _
        end
      end

      def register_hook(point, &block)
        raise "Unknown hook point: #{point}" unless valid_hook_point point
        @hooks[point] << block
      end

      HOOK_POINTS.each do |point|
        define_method(point) do
          @hooks[point].each { |blk| blk.call }
        end
      end

      def slave_connection
        if ActiveRecord::ConnectionAdapters::MasterSlaveAdapter.master_enabled?
          master_connection
        elsif @master_connection && @master_connection.open_transactions > 0
          master_connection
        else
          connect_to_slave
        end
      rescue Exception => e
        after_error
        raise e
      end

      def reconnect!
        @active = true
        self.connections.each { |c| c.reconnect! }
      end

      def disconnect!
        @active = false
        self.connections.each { |c| c.disconnect! }
      end

      def reset!
        self.connections.each { |c| c.reset! }
      end

      def method_missing( name, *args, &block )
        self.master_connection.send( name.to_sym, *args, &block )
      end

      def master_connection
        connect_to_master
      rescue Exception => e
        after_error
        raise e
      end

      def connections
        [ @master_connection, @slave_connection ].compact
      end

      def test_connections
        return if self.disable_connection_test
        self.connections.each do |c|
          begin
            c.select_value( 'SELECT 1', 'test select' )
          rescue
            c.reconnect!
          end
        end
      end

      class << self

        def with_master
          enable_master
          begin
            yield
          ensure
            disable_master
          end
        end

        def master_enabled?
          Thread.current[ :master_slave_enabled ]
        end

        def enable_master
          Thread.current[ :master_slave_enabled ] = true
        end

        def disable_master
          Thread.current[ :master_slave_enabled ] = nil
        end

      end

      private

      def valid_hook_point(point)
        HOOK_POINTS.include? point
      end

      def connect_to_master
        @master_connection ||= ActiveRecord::Base.send( "#{self.master_config[:adapter]}_connection", self.master_config )
      end

      def connect_to_slave
        @slave_connection ||= ActiveRecord::Base.send( "#{self.slave_config[:adapter]}_connection", self.slave_config)
      end

    end

  end

end
