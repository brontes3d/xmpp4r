require 'base64'

module Jabber
  module Helpers
    ##
    # In-Band Bytestreams (JEP-0047) implementation
    #
    # Don't use directly, use IBBInitiator and IBBTarget
    #
    # In-Band Bytestreams should only be used when transferring
    # very small amounts of binary data, because it is slow and
    # increases server load drastically.
    #
    # Note that the constructor takes a lot of arguments. In-Band
    # Bytestreams do not specify a way to initiate the stream,
    # this should be done via Stream Initiation.
    class IBB
      NS_IBB = 'http://jabber.org/protocol/ibb'

      ##
      # Create a new bytestream
      #
      # Will register a <message/> callback to intercept data
      # of this stream. This data will be buffered, you can retrieve
      # it with receive
      def initialize(stream, session_id, my_jid, peer_jid)
        @stream = stream
        @session_id = session_id
        @my_jid = (my_jid.kind_of?(String) ? JID.new(my_jid) : my_jid)
        @peer_jid = (peer_jid.kind_of?(String) ? JID.new(peer_jid) : peer_jid)

        @seq_send = 0
        @seq_recv = 0
        @queue = []
        @queue_lock = Mutex.new
        @pending = Mutex.new
        @pending.lock

        @block_size = 4096  # Recommended by JEP0047
      end

      ##
      # Send data
      # buf:: [String]
      def send(buf)
        msg = Message.new
        msg.from = @my_jid
        msg.to = @peer_jid
        
        data = msg.add REXML::Element.new('data')
        data.add_namespace NS_IBB
        data.attributes['sid'] = @session_id
        data.attributes['seq'] = @seq_send.to_s
        data.text = Base64::encode64 buf

        # TODO: Implement AMP correctly
        amp = msg.add REXML::Element.new('amp')
        amp.add_namespace 'http://jabber.org/protocol/amp'
        deliver_at = amp.add REXML::Element.new('rule')
        deliver_at.attributes['condition'] = 'deliver-at'
        deliver_at.attributes['value'] = 'stored'
        deliver_at.attributes['action'] = 'error'
        match_resource = amp.add REXML::Element.new('rule')
        match_resource.attributes['condition'] = 'match-resource'
        match_resource.attributes['value'] = 'exact'
        match_resource.attributes['action'] = 'error'
 
        @stream.send(msg)

        @seq_send += 1
        @seq_send = 0 if @seq_send > 65535
      end

      ##
      # Receive data
      #
      # Will wait until the Message with the next sequence number
      # is in the stanza queue.
      def receive
        res = nil

        while res.nil?
          @queue_lock.synchronize {
            @queue.each { |item|
              # Find next data
              if item.type == :data and item.seq == @seq_recv.to_s
                res = item
                break
              # No data? Find close
              elsif item.type == :close and res.nil?
                res = item
              end
            }

            @queue.delete_if { |item| item == res }
          }

          # No data? Wait for next to arrive...
          @pending.lock unless res
        end

        if res.type == :data
          @seq_recv += 1
          @seq_recv = 0 if @seq_recv > 65535
          res.data
        elsif res.type == :close
          nil # Closed
        end
      end

      ##
      # Close the stream
      #
      # Waits for acknowledge from peer,
      # may throw ErrorException
      def close
        deactivate

        iq = Iq.new(:set, @peer_jid)
        close = iq.add REXML::Element.new('close')
        close.add_namespace IBB::NS_IBB
        close.attributes['sid'] = @session_id

        @stream.send_with_id(iq) { |answer|
          answer.type == :result
        }
      end

      private

      def activate
        @stream.add_message_callback(200, callback_ref) { |msg|
          data = msg.first_element('data')
          if msg.from == @peer_jid and msg.to == @my_jid and data and data.attributes['sid'] == @session_id
            if msg.type == nil
              @queue_lock.synchronize {
                @queue.push IBBQueueItem.new(:data, data.attributes['seq'], data.text.to_s)
                @pending.unlock
              }
            elsif msg.type == :error
              @queue_lock.synchronize {
                @queue << IBBQueueItem.new(:close)
                @pending.unlock
              }
            end
            true
          else
            false
          end
        }

        @stream.add_iq_callback(200, callback_ref) { |iq|
          close = iq.first_element('close')
          if close and close.attributes['sid'] == @session_id
            answer = iq.answer(false)
            answer.type = :result
            @stream.send(answer)

            @queue_lock.synchronize {
              @queue << IBBQueueItem.new(:close)
              @pending.unlock
            }
            true
          else
            false
          end
        }
      end

      def deactivate
        @stream.delete_message_callback(callback_ref)
        @stream.delete_iq_callback(callback_ref)
      end

      def callback_ref
        "Jabber::Helpers::IBB #{@session_id} #{@initiator_jid} #{@target_jid}"
      end
    end

    ##
    # Represents an item in the internal data queue
    class IBBQueueItem
      attr_reader :type, :seq
      def initialize(type, seq=nil, data_text='')
        unless [:data, :close].include? type
          raise "Unknown IBBQueueItem type: #{type}"
        end

        @type = type
        @seq = seq
        @data = data_text
      end

      ##
      # Return the Base64-*decoded* data
      #
      # There's no need to catch Exceptions here,
      # as none are thrown.
      def data
        Base64::decode64(@data)
      end
    end
  end
end
