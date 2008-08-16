# Implements git-recieve-pack in ruby, so I can understand the damn thing
require 'socket'
require 'pp'

class GitServer
  
  NULL_SHA = '0000000000000000000000000000000000000000'
  CAPABILITIES = " report-status delete-refs "
  
  def initialize
    @capabilities_sent = false
  end
  
  def do_action
    header_data = read_header
    case header_data[1]
    when 'git-receive-pack':
      receive_pack(header_data[2])
    when 'git-upload-pack':
      upload_pack(header_data[2])
    else
      @session.print 'error: wrong thingy'
    end
    @session.close
  end
  
  def receive_pack(path)
    puts "REC PACK: #{path}"
    send_refs
    packet_flush
    read_refs
    read_pack
  end

  def read_refs
    while( line = read_until_null ) do
      puts line
      puts line.size
    end
    puts line = read_until_null(true)
    puts line.size
    puts '--'
  end
  
  def read_pack
    puts @session.recv(1000)
    puts @session.recv(1000)
    puts @session.recv(1000)
    puts @session.recv(1000)
  end
  
  def packet_flush
    @session.send('0000', 0)
  end
  
  def refs
    []
  end
  
  def send_refs
    refs.each do |ref|
      puts ref
      send_ref(ref[1], ref[0])
    end
    send_ref("capabilities^{}", NULL_SHA) if !@capabiliies_sent
  end
  
  def send_ref(path, sha)
    if (@capabilities_sent)
      packet = "%s %s\n" % [sha, path]
  	else
  		packet = "%s %s%c%s\n" % [sha, path, 0, CAPABILITIES]
  	end
  	write_server(packet)
  	@capabilities_sent = true
  end
    
  def write_server(data)
		string = '000' + sprintf("%x", data.length + 4)
  	string = string[string.length - 4, 4]
    	
  	@session.send(string, 0)
  	@session.send(data, 0)
  end
  
  def upload_pack(path)
    puts "UPL PACK"
  end
  
  def read_header()
    len = @session.recv( 4 ).hex
		return false if (len == 0)
		command, directory = read_until_null().strip.split(' ')
		stuff = read_until_null()
		# verify header length?
		[len, command, directory, stuff]
	end
	
	def read_until_null(debug = false)
	  data = ''
	  while c = @session.recv(1)
	    puts "read: #{c}:#{c[0]}" if debug
	    if c[0] == 0
	      return data
	    else
	      data += c
	    end
		end
		data
	end
	
  def self.start_server
    server = self.new
    server.listen
  end

  def listen
    server = TCPServer.new('127.0.0.1', 9418)
    while (@session = server.accept)
      do_action
      return
    end
  end
  
end

GitServer.start_server

