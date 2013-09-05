require 'open-uri'
require 'rest_client'
require 'rdf/rdfxml'
require 'rdf/turtle'


def ask_sadi(service,turtle)
  RestClient.post service, turtle, content_type: 'text/rdf+n3', accept: 'text/rdf+n3'
end

service = "http://sadiframework.org/examples/entrezGene2Uniprot"

turtle = "<http://lsrn.org/GeneID:7157> a <http://purl.oclc.org/SADI/LSRN/GeneID_Record> ."

# service = "http://sadiframework.org/examples/hello"

# turtle = <<-EOF
# @prefix foaf: <http://xmlns.com/foaf/0.1/> .

# <http://sadiframework.org/examples/hello-input.rdf#1> a <http://sadiframework.org/examples/hello.owl#NamedIndividual>;
#    foaf:name "Guy Incognito" .
# EOF

puts ask_sadi(service,turtle)