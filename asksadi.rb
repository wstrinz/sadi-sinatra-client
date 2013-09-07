require 'open-uri'
require 'rdf/rdfxml'
require 'rdf/turtle'
require 'sinatra'
require 'rest_client'
require 'pygments'
require 'htmlentities'
require 'cgi'
require "sinatra/streaming"
require "sinatra/reloader" if development?

helpers Sinatra::Streaming

enable :sessions

set :server, 'thin'

helpers do
  
  def turtle_prefixes
    {
       :foaf => "http://xmlns.com/foaf/0.1/",
       :rdfs => "http://www.w3.org/2000/01/rdf-schema#",
       :moby => "http://www.mygrid.org.uk/mygrid-moby-service#",
       :owl => "http://www.w3.org/2002/07/owl#",
       :protege_owl => "http://protege.stanford.edu/plugins/owl/dc/protege-dc.owl#"
     }
  end

  def remove_prefixes(str,prefixes=turtle_prefixes())
    newstr = str.dup
    prefixes.each{|k,v| newstr.gsub!("@prefix #{k.to_s}: <#{v}> .\n",'') }
    newstr
  end

  def poll(url)
    resp = RestClient.get(url, accept: 'text/rdf+n3'){ |response, request, result, &block|
      if [301, 302, 307].include? response.code

        wait = response.headers[:retry_after]
        
        if wait
          return wait.to_i
        else
          response.follow_redirection(request, result, &block)
        end

      else
        response.return!(request, result, &block)
      end
    }
    resp.body
  end

  def retrieve_async(poll_url)
    poll_url = poll_url.to_s
    puts "opening #{poll_url}"
    begin
      loop do
        result = poll(poll_url)
        if result.is_a? Fixnum
          yield "Response not ready, waiting #{result}"
          sleep(result)
        else
          return result
        end
      end
    rescue => details
      "Request Error: #{details.inspect}\n" + details.backtrace.join("\n")
    end
  end

  # Return poll url or nil
  def is_async(post_response)
    gr = RDF::Repository.new
    RDF::Turtle::Reader.new(post_response) do |reader|
      reader.each_statement do |statement|
        gr << statement
      end
    end

    rdfs = RDF::Vocabulary.new("http://www.w3.org/2000/01/rdf-schema#")

    polls = RDF::Query.execute(gr) do
      pattern [:obj, rdfs.isDefinedBy, :def]
    end

    polls.map(&:def).select{|res| res.to_s["?poll="]}
  end

  def post_turtle(service,turtle)
    response = RestClient.post(service, turtle, content_type: 'text/rdf+n3', accept: 'text/rdf+n3').gsub('^^<http://www.w3.org/2001/XMLSchema#string>','')
  end

  def sadi_turtle(service_url="http://sadiframework.org/examples/hello")

    # Load service description

    service_cache_file = service_url.to_s.gsub(%r{/|\.|:},'_') + ".ttl"
    unless File.exist?(service_cache_file)
      open(service_cache_file,'w'){|f| f.write RestClient.get(service_url, accept: 'text/rdf+n3').body }
    end

    str = IO.read(service_cache_file)

    repo = RDF::Repository.new

    RDF::Turtle::Reader.new(str) do |reader|
      reader.each_statement do |statement|
        repo << statement
      end
    end

    # Query

    moby = RDF::Vocabulary.new("http://www.mygrid.org.uk/mygrid-moby-service#")
    hello = RDF::Vocabulary.new("http://sadiframework.org/examples/hello.owl#")

    inputs = RDF::Query.execute(repo) do
      pattern [:obj, moby.hasOperation, :op]
      pattern [:op, moby.inputParameter, :input]
      pattern [:input, moby.objectType, :in_obj]
    end

    example_in = RDF::Query.execute(repo) do
      pattern [:obj, moby.exampleInput, :in_obj]
    end

    example_out = RDF::Query.execute(repo) do
      pattern [:obj, moby.exampleOutput, :out_obj]
    end

    # Load service OWL
    
    service_owl = inputs.map(&:in_obj).first.to_s.split('#').first;
    ex_in = example_in.map(&:in_obj).first.to_s;
    ex_out = example_out.map(&:out_obj).first.to_s;


    in_obj_file = service_owl.to_s.gsub(%r{/|\.|:},'_') + ".rdfxml"
    unless File.exist?(in_obj_file)
      open(in_obj_file,'w'){|f| f.write open(service_owl).read }
    end


    RDF::RDFXML::Reader.new(IO.read(in_obj_file)) do |reader|
      reader.each_statement do |statement|
        repo << statement
      end
    end

    # Write service turtle

    turtle_string =  IO.read(service_cache_file)

    # Write example files
    if ex_in.size > 0
      exin_file = ex_in.to_s.gsub(%r{/|\.|:},'_') + ".rdfxml"
      unless File.exist?(exin_file)
        open(exin_file,'w'){|f| f.write open(ex_in).read }
      end

      exin_repo = RDF::Repository.new
      RDF::RDFXML::Reader.new(IO.read(exin_file)) do |reader|
        reader.each_statement do |statement|
          exin_repo << statement
        end
      end

      exin_str = <<-EOF

#
# Example Input
#

      EOF
      exin_str +=  RDF::Turtle::Writer.buffer(:prefixes => turtle_prefixes) do |writer|
        exin_repo.each_statement do |statement|
          writer << statement
        end
      end

      # exin_str = remove_prefixes(exin_str)
    end

  if ex_out.size > 0
    exout_file = ex_out.to_s.gsub(%r{/|\.|:},'_') + ".rdfxml"
    unless File.exist?(exout_file)
      open(exout_file,'w'){|f| f.write open(ex_out).read }
    end

    exout_repo = RDF::Repository.new
    RDF::RDFXML::Reader.new(IO.read(exout_file)) do |reader|
      reader.each_statement do |statement|
        exout_repo << statement
      end
    end

    exout_str = <<-EOF


#
# Example Output
#

      EOF
    exout_str +=  RDF::Turtle::Writer.buffer(:prefixes => turtle_prefixes) do |writer|
      exout_repo.each_statement do |statement|
        writer << statement
      end
    end

    # exout_str = remove_prefixes(exout_str)


    end

  ("#{turtle_string} #{exin_str} #{exout_str}").gsub('^^<http://www.w3.org/2001/XMLSchema#string>','')
  end
end

get '/service' do
  session.clear
  @service = "http://sadiframework.org/examples/hello"
  @output = sadi_turtle(@service)

  haml :service
end

post '/service' do
  @service = params[:service]
  @output = sadi_turtle(@service)

  haml :service
end

get '/query' do
  if params[:service] && params[:query]
    @service = params[:service]
    @query = params[:query]
    # raise "#{@service.first} #{@query}"
    # @sadi_response =post_turtle(@service,@query)

  else
  @service = "http://sadiframework.org/examples/hello"
  @query = <<-EOF
@prefix foaf: <http://xmlns.com/foaf/0.1/> .

<http://sadiframework.org/examples/hello-input.rdf#1> a <http://sadiframework.org/examples/hello.owl#NamedIndividual>;
  foaf:name "Guy Incognito" .
  
  EOF
  end
  
  haml :query
end

post '/query' do
  @service = params[:service]
  @query = params[:query]
  @sadi_response = post_turtle(@service,@query)

  poll_url = is_async(@sadi_response)
  if poll_url
    session['poll_url'] = poll_url.map(&:to_s)
    redirect('/stream_async')
  end   
  
  haml :query
end

get '/stream_async' do
  raise "no poll url given!" unless session['poll_url']
  
  poll_urls = session['poll_url']
  puts "#{poll_urls}"
  stream do |out|
    poll_urls.each{|poll_url|
      out.puts "waiting for #{poll_url}... <br><br>"

      coder = HTMLEntities.new

      result = retrieve_async(poll_url){|msg|
        out.puts "#{coder.encode(msg)} <br><br>"
      }

      coded = coder.encode(result).gsub("\n","<br>").gsub("\t","&nbsp;&nbsp;")
      out.puts "<pre>" + coded + "</pre>"
      
      out.flush    
    }
  end
end