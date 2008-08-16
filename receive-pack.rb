# Implements git-recieve-pack in ruby, so I can understand the damn thing
require 'socket'
require 'pp'
require 'zlib'

class GitServer

  NULL_SHA = '0000000000000000000000000000000000000000'
  #CAPABILITIES = " report-status delete-refs "
  CAPABILITIES = " "

  OBJ_NONE = 0
  OBJ_COMMIT = 1
  OBJ_TREE = 2
  OBJ_BLOB = 3
  OBJ_TAG = 4
  OBJ_OFS_DELTA = 6
  OBJ_REF_DELTA = 7

  OBJ_TYPES = [nil, :commit, :tree, :blob, :tag, nil, :ofs_delta, :ref_delta].freeze

  def self.start_server
    server = self.new
    server.listen
  end

  def listen
    server = TCPServer.new('127.0.0.1', 9418)
    while (session = server.accept)
      t = GitServerThread.new(session)
      t.do_action
      return
    end
  end

  class GitServerThread
  
    def initialize(session)
      @session = session
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
      headers = []
      while(data = packet_read_line) do
        sha_old, sha_new, path = data.split(' ')
        headers << [sha_old, sha_new, path]
      end
      pp headers
    end
  
    def read_pack
      (sig, ver, entries) = read_pack_header
    
      puts "SIG: #{sig}"
      puts "VER: #{ver}"
      puts "ENT: #{entries}"
      puts
    
      unpack_all(entries)
    end
  
    def unpack_all(entries)
      1.upto(entries) do |number|
        unpack_object(number)
      end
    end
  
    def unpack_object(number)
      c = @session.recv(1)[0]
      size = c & 0xf
      type = (c >> 4) & 7
      shift = 4
      while c & 0x80 != 0
        c = @session.recv(1)[0]
        size |= ((c & 0x7f) << shift)
        shift += 7
      end
          
      case type
      when OBJ_OFS_DELTA, OBJ_REF_DELTA
        puts "WRITE " + OBJ_TYPES[type].to_s
        unpack_deltified(type, size)
        return
      when OBJ_COMMIT, OBJ_TREE, OBJ_BLOB, OBJ_TAG
        puts "WRITE " + OBJ_TYPES[type].to_s    
        unpack_compressed(type, size)
        return
      else
        puts "invalid type #{type}"
      end
    end

    def unpack_compressed(type, size)
      object_data = get_data(size)
    end

    def unpack_deltified(type, size)
      if type == OBJ_REF_DELTA
        base_sha = @session.recv(20)
        object_data = get_data(size)
      else
        i = 0
        c = data[i]
        base_offset = c & 0x7f
        while c & 0x80 != 0
          c = data[i += 1]
          base_offset += 1
          base_offset <<= 7
          base_offset |= c & 0x7f
        end
        offset += i + 1
      end
      
      return false
      
      base, type = unpack_object(packfile, base_offset)    
      [patch_delta(base, delta), type]
    end
  
    def get_data(size)
    	stream = Zlib::Inflate.new
      buf = ''
    	while(true) do
    	  buf += stream.inflate(@session.recv(1))
    		if (stream.total_out == size && stream.finished?)
    			break;
    		end
    	end
    	stream.close
    	buf
    end
  
    def patch_delta(base, delta)
      src_size, pos = patch_delta_header_size(delta, 0)
      if src_size != base.size
        raise PackFormatError, 'invalid delta data'
      end

      dest_size, pos = patch_delta_header_size(delta, pos)
      dest = ""
      while pos < delta.size
        c = delta[pos]
        pos += 1
        if c & 0x80 != 0
          pos -= 1
          cp_off = cp_size = 0
          cp_off = delta[pos += 1] if c & 0x01 != 0
          cp_off |= delta[pos += 1] << 8 if c & 0x02 != 0
          cp_off |= delta[pos += 1] << 16 if c & 0x04 != 0
          cp_off |= delta[pos += 1] << 24 if c & 0x08 != 0
          cp_size = delta[pos += 1] if c & 0x10 != 0
          cp_size |= delta[pos += 1] << 8 if c & 0x20 != 0
          cp_size |= delta[pos += 1] << 16 if c & 0x40 != 0
          cp_size = 0x10000 if cp_size == 0
          pos += 1
          dest += base[cp_off,cp_size]
        elsif c != 0
          dest += delta[pos,c]
          pos += c
        else
          raise PackFormatError, 'invalid delta data'
        end
      end
      dest
    end

    def patch_delta_header_size(delta, pos)
      size = 0
      shift = 0
      begin
        c = delta[pos]
        if c == nil
          raise PackFormatError, 'invalid delta header'
        end
        pos += 1
        size |= (c & 0x7f) << shift
        shift += 7
      end while c & 0x80 != 0
      [size, pos]
    end
  
    def read_pack_header
      sig = @session.recv(4)
      ver = @session.recv(4).unpack("N")[0]
      entries = @session.recv(4).unpack("N")[0]
      [sig, ver, entries]
    end
  
    def packet_read_line
      size = @session.recv(4)
      hsize = size.hex
      if hsize > 0
        @session.recv(hsize - 4)
      else
        false
      end
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
	
  
  end
end

GitServer.start_server

