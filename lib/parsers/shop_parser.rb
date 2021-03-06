class ShopParser
  
  # given a string in format:
  #
  # [wadedemt.myshopify.com]   Processing ShopController#products (for 192.168.1.230 at 2009-07-24 14:58:21) [GET] 
  #
  # strips out the shop name
  #
  # result => :shop => wadedemt.myshopify.com
  #           :line => Processing ShopController#products (for 192.168.1.230 at 2009-07-24 14:58:21) [GET] 


  LineRegexp   = /^\s*\[([a-zA-Z0-9\-.]+)\]\s*(.*)/
  
  attr_accessor :elements
  
  def initialize(next_renderer = nil)
    @next_renderer = next_renderer
  end
  
  def parse(line, elements = {})
    @elements = elements
    # parse line into elements and put into element
    next_line = parse_line(line)
    if @next_renderer && next_line
      @elements = @next_renderer.parse(next_line, @elements)
    end
    @elements
  end
  
  # parse line and break into pieces
  def parse_line(line)
    results = LineRegexp.match(line)
    if results
      if results[1] =~ /\./
        @elements[:shop] = results[1]
        @elements[:line] = results[-1]
        results[-1]
      else
        @elements[:line] = line
        line
      end
    else
      @elements[:line] = line
      line
    end
  end
end