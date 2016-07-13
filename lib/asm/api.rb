require 'rest-client'
require 'openssl'
require 'base64'
require 'json'

# ASM::Api::sign method to inject authentication headers into Rest requests expected by ASM
#
# usage:
#   ASM::Api::sign {
#     RestClient.post ...
#   }
#

module ASM
  class Api
  
  @@username = nil
  @@password = nil

  @@baseURI = nil
  @@debug = false

  @@auto_auth = false
  @@mutex = Mutex.new
  
  # Accessors so we can use thread locals
  def self.apiKey
    Thread.current[:apiKey]
  end
  def self.apiKey=(key)
    Thread.current[:apiKey]=key
  end
  def self.apiSecret
    Thread.current[:apiSecret]
  end
  def self.apiSecret=(secret)
    Thread.current[:apiSecret]=secret
  end
  def self.inLogin
    Thread.current[:inLogin]
  end
  def self.inLogin=(val)
    Thread.current[:inLogin]=val
  end
  
  @@sslVerify = true

  def self.sslVerify
    @@sslVerify
  end
  def self.sslVerify=(torf)
    @@sslVerify=torf
  end

  def self.userName=(username)
    @@username = username
  end

  def self.password=(password)
    @@password = password
  end

  def self.debug=(value)
    @@debug = value
  end

  def self.generateAuthHeaders( uriPath, httpMethod, userAgent, apiKey=nil, apiSecret=nil )
    headers = {}
    apiKey = apiKey || self.apiKey
    apiSecret = apiSecret || self.apiSecret

    timestamp = Time.now.to_i.to_s
    requestString = "%s:%s:%s:%s:%s" % [apiKey,httpMethod,uriPath,userAgent,timestamp]
    hash_str = OpenSSL::HMAC.digest('sha256',apiSecret,requestString)
    signature = Base64.strict_encode64(hash_str)
    
    if @@debug
      print "request string: %s\n" % requestString
      print "signature: %s\n" % signature
      print "apiKey: %s\n" % apiKey
      print "apiSecret: %s\n" % apiSecret
      print "timestamp: %s\n" % timestamp
    end

    headers['x-dell-auth-key'] = apiKey
    headers['x-dell-auth-signature'] = signature
    headers['x-dell-auth-timestamp'] = timestamp
    headers
  end
  
  def self.injectAuthHeaders( request )

    if apiSecret.nil? and apiKey.nil?
      self.getSecretAndKey(@@username,@@password)
    end

    userAgent = request['user-agent']
    httpMethod = request.method
    
    # Strip query string from path, which is really a uri
    uri = URI::parse(request.path)
    uriPath = uri.path
    
    auth_headers = self.generateAuthHeaders( uriPath, httpMethod, userAgent, apiKey, apiSecret)

    # Add headers to request
    auth_headers.keys.each do |key|
      request[key] = auth_headers[key]
    end

  end

  def self.login(user, pass)
    # Login
    self.apiSecret = 'in progress'
    json = "{\"domain\": \"ASMLOCAL\", \"userName\": \"%s\", \"password\": \"%s\"}" % [user,pass]
    self.inLogin = true
    response = RestClient.post "#{@@baseURI}/admin/authenticate", json, :content_type => :json, :accept => :json
    self.inLogin = false
    h = JSON.parse( response.body )
    self.apiKey = h['apiKey']
    self.apiSecret = h['apiSecret']
  end

  def self.getSecretAndKey(user=nil, pass=nil)
    unless user.to_s.empty? or pass.to_s.empty? or user == 'system'
      self.login(user,pass)
    else
      # Get creds from DB
      require 'asm'
      h = ASM::api_info
      self.apiKey = h[:apikey]
      self.apiSecret = h[:api_secret]
    end
  end

  def self.logout
    # Invalidate creds
    self.apiSecret = nil
    self.apiKey = nil
  end

  def self.sign(user=nil,pass=nil)
    @@username = user unless user.nil?
    @@password = pass unless pass.nil?

    # Install handler first time this is called
    unless @@auto_auth
      self.enableAutoAuth
    end
    
    Thread.current[:enable_auth] = true
    begin
      result = yield
    rescue RestClient::Exception => e
      # Assuming creds have timed out
      print "Caught 401, reset auth creds\n"
      if e.response.code == 401
        # invalidate creds
        self.logout
        # try again
        result = yield
      end
    ensure
      Thread.current[:enable_auth] = nil
    end
    return result
  end

  # Set a base URI so that calls to URI below will prepend it
  def self.baseURI=(url)
    @@baseURI = url
  end

  def self.baseURI
    @@baseURI ||= ASM.config.url.asm || 'http://localhost:9080'
  end

  # Return an absolute URI if baseURI was set
  def self.URI(path)
    "%s%s" % [@@baseURI,path]
  end

  def self.disableAutoAuth
    @@auto_auth = false
    RestClient.reset_before_execution_procs
  end

  # Install a thread-safe call-back to RestClient
  def self.enableAutoAuth
    @@mutex.synchronize do        
      unless @@auto_auth
        RestClient.add_before_execution_proc do |request, params|
          unless Thread.current[:enable_auth].nil?          
            injectAuthHeaders(request) unless inLogin
          end
        end
      end
      @@auto_auth = true        
    end
  end

end

end
