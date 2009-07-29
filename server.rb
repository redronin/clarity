require 'rubygems'
require 'eventmachine'
require 'evma_httpserver'
require 'erb'
require 'cgi'
require 'yaml'
require 'base64'
require 'socket'
require 'lib/pid_handling'
require 'lib/basic_auth'
require 'lib/string_ext'


CONFIG    = YAML.load(open('./config/config.yml').read)
LOG_FILES = CONFIG['log_files'] rescue [] 
USERNAME  = CONFIG['username'] rescue 'admin'
PASSWORD  = CONFIG['password'] rescue 'admin'

# sample log output
# Jul 24 14:58:21 app3 rails.shopify[9855]: [wadedemt.myshopify.com]   Processing ShopController#products (for 192.168.1.230 at 2009-07-24 14:58:21) [GET] 

module GrepRenderer  
  attr_accessor :response, :key, :logger
  
  # once download is complete, send it to client
  def receive_data(data)
    Handler.add_pid(get_status.pid, key)
    response.chunk ERB::Util.h(data).gsub(/\n/, '<br/>')
    response.send_chunks
  end

  def unbind
    Handler.remove_pid(get_status.pid)
    response.chunk '<hr><p id="done">Done</p><script>$("spinner").hide();</script></body></html>'
    response.chunk ''
    response.send_chunks
    puts 'Done'
  end
  
end

class RailsLineParser
  
  def modify(line)
    line + '<br/>'
    
    if line =~ /([\w\/\.])\:(\s*\d\d\:\d\d:\d\d)\s*(.*)/
      "#{File.basename($1)} #{Time.parse($2)} #{$3}"
    end
  end
end


class Handler < EventMachine::Connection
  include EventMachine::HttpServer
  include BasicAuth
  extend PidHandling
  
  LeadIn = ' ' * 1024  
  MimeTypes = {
    '.jpg'  =>  'image/jpg', 
    '.jpeg' =>  'image/jpeg',
    '.gif'  =>  'image/gif', 
    '.png'  =>  'image/png',
    '.bmp'  =>  'image/bmp',
    '.bitmap' =>  'image/x-ms-bmp'
  }
  
  def logger(msg)
    puts msg
  end
  
  def logfiles
    @@logfiles = LOG_FILES.map {|f| Dir[f] }.flatten.compact.uniq
  end
  
  def parse_params
    params = ENV['QUERY_STRING'].split('&').inject({}) {|p, s| k,v=s.split('=');p[k.to_s]=CGI.unescape(v.to_s);p}
    logger "params #{params.inspect}"
    params
  end

  def welcome_page
    @@welcome_page ||= ERB.new(open('./views/index.html.erb').read).result(binding)
  end
  
  def results_page
    @@results_page = ERB.new(open('./views/results.html.erb').read).result(binding)
  end
 
  # tool - zgrep, bzgrep or grep
  # base query
  # shop filter
  # ..additional filters
  def build_grep_request(params)
    tool = case
      when @params['file'].include?('.gz') then 'zgrep'
      when @params['file'].include?('.bz2') then 'bzgrep'
      else 'grep'
    end
    
    queries = []
    queries << (@params['shop'].blank? ? nil : sanitize_query(@params['shop']))
    if @params['q'].blank?
      raise InvalidParameterError, "Query cannot be blank"
    else
      queries << sanitize_query(@params['q'])
    end
    
    logfile = @params['file']
    queries.compact!

    # get shop name (future)
    # raise error if attempt unauthorized file
    raise InvalidParameterError, "invalid log file #{params['file']}" unless logfiles.include?(params['file'])
    raise InvalidParameterError, "Both Shop URL and Query cannot be blank" if queries.empty?
    
    cmd  = "#{tool} -e #{queries.shift.inspect} #{logfile} "
    if !queries.empty?
      cmd << query_filter(queries.shift)
    end
    cmd.strip
    %[sh -c '#{cmd}']
  end
 
  def query_filter(query)
    "| grep -e #{query.inspect}"
  end
  
  def sanitize_query(query_string)
    query = Regexp.escape(query_string).gsub(/'/, "").gsub(/"/, "")
  end
 
  def process_http_request
    logger "== request: #{ENV['PATH_INFO']}"
    connection_key = Socket.unpack_sockaddr_in(get_peername).last
    
    response = EventMachine::DelegatedHttpResponse.new( self )
    response.headers['Content-Type'] = 'text/html'
    response.status = 200
    
    
    case ENV["PATH_INFO"]
    when '/'
      raise NotAuthenticatedError unless authenticate(@http_headers)
      Handler.kill_existing_process(connection_key)

      response.headers['Content-Type'] = 'text/html'
      response.content = welcome_page
      response.send_response
      
    when '/search'
      raise NotAuthenticatedError unless authenticate(@http_headers)
      Handler.kill_existing_process(connection_key)

      @params = parse_params || {}
      if @params['q'].nil? || @params['file'].nil?
        response.content = welcome_page
        response.send_response
      else
        # Safari only starts rendering chunked data after it gets 1kb of data. 
        # So we sent it 1kb of whitespace
        response.chunk LeadIn
        response.chunk results_page # display page header
        
        cmd = build_grep_request(@params)
        logger "Running: #{cmd}"
        
        EventMachine::popen(cmd, GrepRenderer) do |grepper|
          grepper.key = connection_key
          grepper.response = response
        end
      end
      
    when '/test'
      response.chunk LeadIn
      EventMachine::add_periodic_timer(1) do 
        response.chunk "Hello chunked world <br/>"        
        response.send_chunks
      end
    
    when /\/images\/.*/
      img = File.join('./public/', ENV["PATH_INFO"])
      if File.exists?(img)
        response.status = 200
        response.content = File.open(img).read
        response.headers['Content-Type'] = MimeTypes[File.extname(img)]
        response.send_response
      else
        raise NotFoundError
      end
      
    else
      raise NotFoundError # default
    end
    
  rescue InvalidParameterError => e
    response.status = 500
    @error = e    
    response.content = ERB.new(open('./views/error.html.erb').read).result(binding)
    response.headers['Content-Type'] = 'text/html'
    response.send_response
    
  rescue NotFoundError => e
    response.status = 404
    response.content = "<h1>Not Found</h1>"
    response.headers['Content-Type'] = 'text/html'
    response.send_response      
    
  rescue NotAuthenticatedError => e
    puts "Could not authenticate user"
    response.headers["WWW-Authenticate"] = %(Basic realm="Application")
    response.content = "HTTP Basic: Access denied.\n"
    response.headers["Content-Type"] = 'text/plain'
    response.status = 401
    response.send_response
  end
end


class InvalidParameterError < StandardError; end
class NotFoundError < StandardError; end
class NotAuthenticatedError < StandardError; end


EventMachine::run {
  EventMachine.epoll
  EventMachine::start_server("0.0.0.0", 8080, Handler)
  puts "Listening..."
  puts "Valid log files are #{LOG_FILES.inspect}"
}
