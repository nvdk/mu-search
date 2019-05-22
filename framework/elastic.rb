# A quick as-needed Elastic API, for use until
# the conflict with Sinatra::Utils is resolved
# * does not follow the standard API
# * see: https://github.com/mu-semtech/mu-ruby-template/issues/16
class Elastic
  include SinatraTemplate::Utils

  # Sets up the ElasticSearch instance
  def initialize(host: 'localhost', port: 9200)
    @host = host
    @port = port
    @port_s = port.to_s
  end

  # Sends a raw request to ElasticSearch
  #
  #   - uri: URI instance representing the elasticSearch host
  #   - req: The request object
  #
  # Responds with the body on success, or the failure value on
  # failure.
  def run(uri, req)
    req['content-type'] = 'application/json'

    res = Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(req)
    end

    case res
    when Net::HTTPSuccess, Net::HTTPRedirection
      res.body
    else
      res.value
    end
  end

  # Checks mhether or not ElasticSearch is up
  #
  # Executes a health check and accepts either "green" or "yellow".
  # Yields false on anything else.
  def up
    uri = URI("http://#{@host}:#{@port_s}/_cluster/health")
    req = Net::HTTP::Get.new(uri)

    begin
      result = JSON.parse run(uri, req)
      result["status"] == "yellow" or
        result["status"] == "green"
    rescue
      false
    end
  end

  # Checks whether or not the supplied index exists.
  #
  # Executes a HEAD request.  If that succeeds we can assume the index
  # exists.
  #
  #   - index: string name of the index
  def index_exists index
    uri = URI("http://#{@host}:#{@port_s}/#{index}")
    req = Net::HTTP::Head.new(uri)

    begin
      run(uri, req)
      true
    rescue
      false
    end
  end

  # Creates an index in the elasticSearch instance..
  #
  #   - index: Index to be created
  #   - mappings: currently not used
  #
  # TODO: the settings for creating the index have been hardwired for
  # now.  We should move them to the configuration.
  #
  # TODO: describe and add support for the mappings argument
  def create_index index, mappings = nil
    uri = URI("http://#{@host}:#{@port_s}/#{index}")
    req = Net::HTTP::Put.new(uri)

    req.body = {
      settings: {
        analysis: {
          analyzer: {
            dutchanalyzer: {
              tokenizer: "standard",
              filter: ["lowercase", "dutchstemmer"] } },
          filter: {
            dutchstemmer: {
              type: "stemmer",
              name: "dutch" } } } }
    }.to_json

    result = run(uri, req)
  end

  # Deletes an index from ElasticSearch
  #
  #   - index: Name of the index to be removed
  #
  # Throws an error if the index exists but could not be removed.
  def delete_index index
    uri = URI("http://#{@host}:#{@port_s}/#{index}")
    req = Net::HTTP::Delete.new(uri)
    begin
      run(uri, req)
      log.info "Deleted #{index}"
      log.info "Status: #{index_exists index}"
    rescue
      if !client.index_exists index
        log.info "Index not deleted, does not exist: #{index}"
      else
        raise "Error deleting index: #{index}"
      end
    end
  end

  # Refreshes an ElasticSearch index, making documents available for
  # search.
  #
  # When we store documents in ElasticSearch, they are not necessarily
  # available immediately.  It requires a refresh of the index.  This
  # operation happens once every second.  When we build an index to
  # query it immediately, we should ensure to refresh the index before
  # querying.
  #
  #   - index: Name of the index which will be refreshed.
  def refresh_index index
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_refresh")
    req = Net::HTTP::Post.new(uri)
    run(uri, req)
  end

  # Gets a single document from an index, based on its ElasticSearch
  # id.
  #
  #   - index: Index to retrieve the document from.
  #   - id: ElasticSearch ID of the document.
  def get_document index, id
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/#{id}")
    req = Net::HTTP::Get.new(uri)
    run(uri, req)
  end

  # Puts a new document in an index.
  #
  #   - index: Index to store the document in.
  #   - id: ElasticSearch identifier to store the document under.
  #   - document: Document contents (as a ruby json object) to be
  #     stored.
  def put_document index, id, document
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/#{id}")
    req = Net::HTTP::Put.new(uri)
    req.body = document.to_json
    run(uri, req)
  end

  # Updates a document in ElasticSearch by id
  #
  #   - index: Index to update the document in
  #   - id: ElasticSearch identifier of the document
  #   - document: New document contents
  #
  # TODO: describe if this is a full replace, or if this updates the
  # document partially.
  def update_document index, id, document
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/#{id}/_update")
    req = Net::HTTP::Post.new(uri)
    req.body = { "doc": document }.to_json
    run(uri, req)
  end

  # Bulk updates a set of documents
  #
  #   - index: Index to update the documents in.
  #   - data: An array of json/hashes, ordered according to
  # https://www.elastic.co/guide/en/elasticsearch/reference/6.4/docs-bulk.html
  def bulk_update_document index, data
    Parallel.each( data.each_slice(4), in_threads: ENV['NUMBER_OF_THREADS'] ) do |data|
      begin
        uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/_bulk")
        req = Net::HTTP::Post.new(uri)
        body = ""
        data.each do |datum|
          body += datum.to_json + "\n"
        end
        req.body = body

        req["Content-Type"] = "application/x-ndjson"

        run(uri, req)
      rescue StandardError => e
        id = data[0] && data[0][:index] && data[0][:index][:_id]
        log.warn( e )
        log.warn( "Failed to upload document #{id} with length #{body.length}" )
        log.warn( "Falied document #{id} is not ginormous" ) if body.length < 100_000_000
      end
    end
  end

  # Deletes a document from ElasticSearch
  #
  #   - index: Index to remove the document from
  #   - id: ElasticSearch identifier of the document
  def delete_document index, id
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/#{id}")
    req = Net::HTTP::Delete.new(uri)
    run(uri, req)
  end

  # Deletes all documents which match a certain query
  #
  #   - index: Index to delete the documents from
  #   - query: ElasticSearch query used for selecting documents
  #   - conflicts_proceed: boolean indicating we should delete if
  #     other operations are occurring on the same document or not.
  #
  # TODO: Verify description of conflicts_proceed.
  #
  # TODO: Provide reference to query format.
  def delete_by_query index, query, conflicts_proceed
    conflicts = conflicts_proceed ? 'conflicts=proceed' : ''
    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/_delete_by_query?#{conflicts}")

    req = Net::HTTP::Post.new(uri)
    req.body = query.to_json
    run(uri, req)
  end

  # Searches for documents in an index
  #
  #   - index: Index to be searched
  #   - query_string: ElasticSearch query string in a URL-escaped
  #     manner
  #   - query: ElasticSearch query JSON object in ruby format (used
  #     only when no query_string is supplied)
  #   - sort: ElasticSearch sort string in URL-escaped manner (used
  #     only when query_string is provided)
  def search index:, query_string: nil, query: nil, sort: nil
    if query_string
      log.info "Searching elastic search for #{query_string} on #{index}"
      uri = URI("http://#{@host}:#{@port_s}/#{index}/_search?q=#{query_string}&sort=#{sort}")
      req = Net::HTTP::Post.new(uri)
    else
      log.debug "Searching elastic search index #{index} for body #{query}"
      uri = URI("http://#{@host}:#{@port_s}/#{index}/_search")
      req = Net::HTTP::Post.new(uri)
      req.body = query.to_json
    end

    run(uri, req)
  end

  # Uploads an attachment to the index to be processed by a specific
  # pipeline and updates the full document.
  #
  #   - index: Index to which the attachment should be stored.
  #   - id: id of the document to which the attachment will be stored.
  #   - pipeline: Name of the pipeline which should run for the
  #     attachment.
  #   - document: JSON body representing the attachment.
  #
  # TODO: Describe the value of the pipeline and/or where to find
  # reasonable values.
  #
  # TODO: Describe the format of the document's body.
  def upload_attachment index, id, pipeline, document
    document_for_reporting = document.clone
    document_for_reporting["data"] = document_for_reporting["data"] ? "[...#{document_for_reporting["data"].length} characters long]" : "none"

    es_uri = "http://#{@host}:#{@port_s}/#{index}/_doc/#{id}?pipeline=#{pipeline}"

    log.debug("Uploading attachment through call: #{es_uri}")
    log.debug("Uploading approximate body: #{document_for_reporting}")

    uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/#{id}?pipeline=#{pipeline}")
    req = Net::HTTP::Put.new(uri)
    req.body = document.to_json
    run(uri, req)
  end

  # Creates an attachment pipeline and configures it to operate on a
  # specific field.
  #
  #   - pipeline: name of the new attachment pipeline.
  #   - field: Field on which to operate.
  #
  # Creates a new attachment pipeline, scanning all characters of the
  # supplied field (no character limit).
  def create_attachment_pipeline pipeline, field
    uri = URI("http://#{@host}:#{@port_s}/_ingest/pipeline/#{pipeline}")
    req = Net::HTTP::Put.new(uri)
    req.body = {
      description: "Extract attachment information",
      processors: [
        {
          attachment: {
            field: field,
            indexed_chars: -1
          }
        },
        {
          remove: {
            field: field
          }
        }
      ]
    }.to_json
    run(uri, req)
  end

  # Executes a count query for a particular string
  #
  # Arguments behave similarly to Elastic#search
  #
  #   - index: Index on which to execute the count qurey.
  #   - query_string: ElasticSearch query string in a URL-escaped
  #     manner
  #   - query: ElasticSearch query JSON object in ruby format (used
  #     only when no query_string is supplied)
  #   - sort: ElasticSearch sort string in URL-escaped manner (used
  #     only when query_string is provided)
  #
  # TODO: why do we have a sort here?
  def count index:, query_string: nil, query: nil, sort: nil
    if query_string
      log.debug "Counting query on #{index}, being #{query_string}"
      uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/_count?q=#{query_string}&sort=#{sort}")
      req = Net::HTTP::Get.new(uri)
    else
      log.debug "Counting query on #{index}, with body #{query}"
      uri = URI("http://#{@host}:#{@port_s}/#{index}/_doc/_count")
      req = Net::HTTP::Get.new(uri)
      req.body = query.to_json
    end

    run(uri, req)
  end
end
