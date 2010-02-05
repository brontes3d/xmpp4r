#!/usr/bin/ruby

$:.unshift "#{File.dirname(__FILE__)}/../../lib"

require 'test/unit'
require 'xmpp4r'

# Jabber::debug = true

class ReliableListenerTest < Test::Unit::TestCase
  class << self
    attr_accessor :connection
    attr_accessor :connection_attempts
  end
  
  class TestListener < Jabber::Reliable::Listener
    attr_accessor :received_messages
    
    def on_message(got_message)
      self.received_messages ||= []
      self.received_messages << got_message
    end
    
  end
  
  def setup
    ReliableListenerTest.connection_attempts = 0
    Jabber::Stream.class_eval do
      alias_method :send_data_original, :send_data
      def send_data(dat)
        true
      end
    end
    Jabber::Reliable::Connection.class_eval do
      alias_method :connect_original, :connect
      def connect
        ReliableListenerTest.connection_attempts += 1
        @status = Jabber::Stream::CONNECTED
        true
      end
      alias_method :auth_original, :auth
      def auth(pass)
        ReliableListenerTest.connection = self
        true
      end
    end
  end
  def teardown
    Jabber::Stream.class_eval do
      alias_method :send_data, :send_data_original
    end
    Jabber::Reliable::Connection.class_eval do
      alias_method :connect, :connect_original
      alias_method :auth, :auth_original      
    end
  end
      
  def test_listener_stop_and_start
    listener = TestListener.new("listener1@localhost/hi", "test", {:servers => ["localhost"], :presence_message => "hi"})
    listener.start
    
    reconnection_thread = listener.instance_eval{
      @reconnection_thread
    }
    assert reconnection_thread.alive?
    connection = listener.instance_eval{
      @connection
    }
    assert connection.is_connected?
    
    #as originally implemented listener reconnect would grow the stack on every reconnect
    #and thus reach stack overflow, hence the 20.times run here
    20.times do |n|
      assert_equal(n+1, ReliableListenerTest.connection_attempts)
      raise_a_parse_exception
      sleep(0.2)
      assert_equal(n+2, ReliableListenerTest.connection_attempts)
    end
    
    listener.stop
    
    raise_a_parse_exception
    
    reconnection_thread = listener.instance_eval{
      @reconnection_thread
    }
    assert !reconnection_thread.alive?
    connection = listener.instance_eval{
      @connection
    }
    assert !connection
  end
  
  def raise_a_parse_exception
    begin
      raise REXML::ParseException.new("test")
    rescue => e
      ReliableListenerTest.connection.parse_failure(e)
    end    
  end
  
end