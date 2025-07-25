import exception
import gleam/bit_array
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/application
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http.{type Method}
import gleam/http/cookie
import gleam/http/request.{type Request as HttpRequest}
import gleam/http/response.{
  type Response as HttpResponse, Response as HttpResponse,
}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import gleam/uri
import houdini
import logging
import marceau
import simplifile
import wisp/internal

//
// Responses
//

/// The body of a HTTP response, to be sent to the client.
///
pub type Body(state, message, data) {
  /// A body of unicode text.
  ///
  /// The body is represented using a `StringTree`. If you have a `String`
  /// you can use the `string_tree.from_string` function to convert it.
  ///
  Text(StringTree)
  /// A body of binary data.
  ///
  /// The body is represented using a `BytesTree`. If you have a `BitArray`
  /// you can use the `bytes_tree.from_bit_array` function to convert it.
  ///
  Bytes(BytesTree)
  /// A body of the contents of a file.
  ///
  /// This will be sent efficiently using the `send_file` function of the
  /// underlying HTTP server. The file will not be read into memory so it is
  /// safe to send large files this way.
  ///
  File(path: String)
  /// A body which is a stream of server-sent events.
  ///
  /// The body is a function which will be called to start the stream. The
  /// function returns an `actor.Started` or `actor.StartError` result.
  ///
  ServerSentEvent(init: Init(state, message, data), loop: Loop(state, message))
  /// functions in the event of a failure, invalid request, or other situation
  /// in which the request cannot be processed.
  ///
  /// Your application may wish to use a middleware to provide default responses
  /// in place of any with an empty body.
  ///
  Empty
}

pub type Response(a, b, c) =
  HttpResponse(Body(a, b, c))

/// Create an empty response with the given status code.
///
/// # Examples
///
/// ```gleam
/// response(200)
/// // -> Response(200, [], Empty)
/// ```
///
pub fn response(status: Int) -> Response(state, message, data) {
  HttpResponse(status, [], Empty)
}

/// Set the body of a response.
///
/// # Examples
///
/// ```gleam
/// response(200)
/// |> set_body(File("/tmp/myfile.txt"))
/// // -> Response(200, [], File("/tmp/myfile.txt"))
/// ```
///
pub fn set_body(
  response: Response(state, message, data),
  body: Body(state, message, data),
) -> Response(state, message, data) {
  response
  |> response.set_body(body)
}

/// Send a file from the disc as a file download.
///
/// The operating system `send_file` function is used to efficiently send the
/// file over the network socket without reading the entire file into memory.
///
/// The `content-disposition` header will be set to `attachment;
/// filename="name"` to ensure the file is downloaded by the browser. This is
/// especially good for files that the browser would otherwise attempt to open
/// as this can result in cross-site scripting vulnerabilities.
///
/// If you wish to not set the `content-disposition` header you could use the
/// `set_body` function with the `File` body variant.
///
/// # Examples
///
/// ```gleam
/// response(200)
/// |> file_download(named: "myfile.txt", from: "/tmp/myfile.txt")
/// // -> Response(
/// //   200,
/// //   [#("content-disposition", "attachment; filename=\"myfile.txt\"")],
/// //   File("/tmp/myfile.txt"),
/// // )
/// ```
///
pub fn file_download(
  response: Response(state, message, data),
  named name: String,
  from path: String,
) -> Response(state, message, data) {
  let name = uri.percent_encode(name)
  response
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"" <> name <> "\"",
  )
  |> response.set_body(File(path))
}

/// Send a file from memory as a file download.
///
/// If your file is already on the disc use `file_download` instead, to avoid
/// having to read the file into memory to send it.
///
/// The `content-disposition` header will be set to `attachment;
/// filename="name"` to ensure the file is downloaded by the browser. This is
/// especially good for files that the browser would otherwise attempt to open
/// as this can result in cross-site scripting vulnerabilities.
///
/// # Examples
///
/// ```gleam
/// let content = bytes_tree.from_string("Hello, Joe!")
/// response(200)
/// |> file_download_from_memory(named: "myfile.txt", containing: content)
/// // -> Response(
/// //   200,
/// //   [#("content-disposition", "attachment; filename=\"myfile.txt\"")],
/// //   File("/tmp/myfile.txt"),
/// // )
/// ```
///
pub fn file_download_from_memory(
  response: Response(state, message, data),
  named name: String,
  containing data: BytesTree,
) -> Response(state, message, data) {
  let name = uri.percent_encode(name)
  response
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"" <> name <> "\"",
  )
  |> response.set_body(Bytes(data))
}

/// Create a HTML response.
///
/// The body is expected to be valid HTML, though this is not validated.
/// The `content-type` header will be set to `text/html; charset=utf-8`.
///
/// # Examples
///
/// ```gleam
/// let body = string_tree.from_string("<h1>Hello, Joe!</h1>")
/// html_response(body, 200)
/// // -> Response(200, [#("content-type", "text/html; charset=utf-8")], Text(body))
/// ```
///
pub fn html_response(html: StringTree, status: Int) -> Response(state, message, data) {
  HttpResponse(
    status,
    [#("content-type", "text/html; charset=utf-8")],
    Text(html),
  )
}

/// Create a JSON response.
///
/// The body is expected to be valid JSON, though this is not validated.
/// The `content-type` header will be set to `application/json`.
///
/// # Examples
///
/// ```gleam
/// let body = string_tree.from_string("{\"name\": \"Joe\"}")
/// json_response(body, 200)
/// // -> Response(200, [#("content-type", "application/json")], Text(body))
/// ```
///
pub fn json_response(json: StringTree, status: Int) -> Response(state, message, data) {
  HttpResponse(
    status,
    [#("content-type", "application/json; charset=utf-8")],
    Text(json),
  )
}

/// Set the body of a response to a given HTML document, and set the
/// `content-type` header to `text/html`.
///
/// The body is expected to be valid HTML, though this is not validated.
///
/// # Examples
///
/// ```gleam
/// let body = string_tree.from_string("<h1>Hello, Joe!</h1>")
/// response(201)
/// |> html_body(body)
/// // -> Response(201, [#("content-type", "text/html; charset=utf-8")], Text(body))
/// ```
///
pub fn html_body(
  response: Response(state, message, data),
  html: StringTree,
) -> Response(state, message, data) {
  response
  |> response.set_body(Text(html))
  |> response.set_header("content-type", "text/html; charset=utf-8")
}

/// Set the body of a response to a given JSON document, and set the
/// `content-type` header to `application/json`.
///
/// The body is expected to be valid JSON, though this is not validated.
///
/// # Examples
///
/// ```gleam
/// let body = string_tree.from_string("{\"name\": \"Joe\"}")
/// response(201)
/// |> json_body(body)
/// // -> Response(201, [#("content-type", "application/json; charset=utf-8")], Text(body))
/// ```
///
pub fn json_body(
  response: Response(state, message, data),
  json: StringTree,
) -> Response(state, message, data) {
  response
  |> response.set_body(Text(json))
  |> response.set_header("content-type", "application/json; charset=utf-8")
}

/// Set the body of a response to a given string tree.
///
/// You likely want to also set the request `content-type` header to an
/// appropriate value for the format of the content.
///
/// # Examples
///
/// ```gleam
/// let body = string_tree.from_string("Hello, Joe!")
/// response(201)
/// |> string_tree_body(body)
/// // -> Response(201, [], Text(body))
/// ```
///
pub fn string_tree_body(
  response: Response(state, message, data),
  content: StringTree,
) -> Response(state, message, data) {
  response
  |> response.set_body(Text(content))
}

/// Set the body of a response to a given string.
///
/// You likely want to also set the request `content-type` header to an
/// appropriate value for the format of the content.
///
/// # Examples
///
/// ```gleam
/// let body =
/// response(201)
/// |> string_body("Hello, Joe!")
/// // -> Response(
/// //   201,
/// //   [],
/// //   Text(string_tree.from_string("Hello, Joe"))
/// // )
/// ```
///
pub fn string_body(
  response: Response(state, message, data),
  content: String,
) -> Response(state, message, data) {
  response
  |> response.set_body(Text(string_tree.from_string(content)))
}

/// Escape a string so that it can be safely included in a HTML document.
///
/// Any content provided by the user should be escaped before being included in
/// a HTML document to prevent cross-site scripting attacks.
///
/// # Examples
///
/// ```gleam
/// escape_html("<h1>Hello, Joe!</h1>")
/// // -> "&lt;h1&gt;Hello, Joe!&lt;/h1&gt;"
/// ```
///
pub fn escape_html(content: String) -> String {
  houdini.escape(content)
}

/// Create an empty response with status code 405: Method Not Allowed. Use this
/// when a request does not have an appropriate method to be handled.
///
/// The `allow` header will be set to a comma separated list of the permitted
/// methods.
///
/// # Examples
///
/// ```gleam
/// method_not_allowed(allowed: [Get, Post])
/// // -> Response(405, [#("allow", "GET, POST")], Empty)
/// ```
///
pub fn method_not_allowed(
  allowed methods: List(Method),
) -> Response(state, message, data) {
  let allowed =
    methods
    |> list.map(http.method_to_string)
    |> list.sort(string.compare)
    |> string.join(", ")
    |> string.uppercase
  HttpResponse(405, [#("allow", allowed)], Empty)
}

/// Create an empty response with status code 200: OK.
///
/// # Examples
///
/// ```gleam
/// ok()
/// // -> Response(200, [], Empty)
/// ```
///
pub fn ok() -> Response(state, message, data) {
  HttpResponse(200, [], Empty)
}

/// Create an empty response with status code 201: Created.
///
/// # Examples
///
/// ```gleam
/// created()
/// // -> Response(201, [], Empty)
/// ```
///
pub fn created() -> Response(state, message, data) {
  HttpResponse(201, [], Empty)
}

/// Create an empty response with status code 202: Accepted.
///
/// # Examples
///
/// ```gleam
/// accepted()
/// // -> Response(202, [], Empty)
/// ```
///
pub fn accepted() -> Response(state, message, data) {
  HttpResponse(202, [], Empty)
}

/// Create an empty response with status code 303: See Other, and the `location`
/// header set to the given URL. Used to redirect the client to another page.
///
/// # Examples
///
/// ```gleam
/// redirect(to: "https://example.com")
/// // -> Response(303, [#("location", "https://example.com")], Empty)
/// ```
///
pub fn redirect(to url: String) -> Response(state, message, data) {
  HttpResponse(303, [#("location", url)], Empty)
}

/// Create an empty response with status code 308: Moved Permanently, and the
/// `location` header set to the given URL. Used to redirect the client to
/// another page.
///
/// This redirect is permanent and the client is expected to cache the new
/// location, using it for future requests.
///
/// # Examples
///
/// ```gleam
/// moved_permanently(to: "https://example.com")
/// // -> Response(308, [#("location", "https://example.com")], Empty)
/// ```
///
pub fn moved_permanently(to url: String) -> Response(state, message, data) {
  HttpResponse(308, [#("location", url)], Empty)
}

/// Create an empty response with status code 204: No content.
///
/// # Examples
///
/// ```gleam
/// no_content()
/// // -> Response(204, [], Empty)
/// ```
///
pub fn no_content() -> Response(state, message, data) {
  HttpResponse(204, [], Empty)
}

/// Create an empty response with status code 404: No content.
///
/// # Examples
///
/// ```gleam
/// not_found()
/// // -> Response(404, [], Empty)
/// ```
///
pub fn not_found() -> Response(state, message, data) {
  HttpResponse(404, [], Empty)
}

/// Create an empty response with status code 400: Bad request.
///
/// # Examples
///
/// ```gleam
/// bad_request()
/// // -> Response(400, [], Empty)
/// ```
///
pub fn bad_request() -> Response(state, message, data) {
  HttpResponse(400, [], Empty)
}

/// Create an empty response with status code 413: Entity too large.
///
/// # Examples
///
/// ```gleam
/// entity_too_large()
/// // -> Response(413, [], Empty)
/// ```
///
pub fn entity_too_large() -> Response(state, message, data) {
  HttpResponse(413, [], Empty)
}

/// Create an empty response with status code 415: Unsupported media type.
///
/// The `allow` header will be set to a comma separated list of the permitted
/// content-types.
///
/// # Examples
///
/// ```gleam
/// unsupported_media_type(accept: ["application/json", "text/plain"])
/// // -> Response(415, [#("allow", "application/json, text/plain")], Empty)
/// ```
///
pub fn unsupported_media_type(
  accept acceptable: List(String),
) -> Response(state, message, data) {
  let acceptable = string.join(acceptable, ", ")
  HttpResponse(415, [#("accept", acceptable)], Empty)
}

/// Create an empty response with status code 422: Unprocessable entity.
///
/// # Examples
///
/// ```gleam
/// unprocessable_entity()
/// // -> Response(422, [], Empty)
/// ```
///
pub fn unprocessable_entity() -> Response(state, message, data) {
  HttpResponse(422, [], Empty)
}

/// Create an empty response with status code 500: Internal server error.
///
/// # Examples
///
/// ```gleam
/// internal_server_error()
/// // -> Response(500, [], Empty)
/// ```
///
pub fn internal_server_error() -> Response(state, message, data) {
  HttpResponse(500, [], Empty)
}

//
// Requests
//

/// The connection to the client for a HTTP request.
///
/// The body of the request can be read from this connection using functions
/// such as `require_multipart_body`.
///
pub type Connection =
  internal.Connection

pub type SSEEnabled =
  internal.SSECapability

type BufferedReader {
  BufferedReader(reader: internal.Reader, buffer: BitArray)
}

type Quotas {
  Quotas(body: Int, files: Int)
}

fn decrement_body_quota(
  quotas: Quotas,
  size: Int,
) -> Result(Quotas, Response(state, message, data)) {
  let quotas = Quotas(..quotas, body: quotas.body - size)
  case quotas.body < 0 {
    True -> Error(entity_too_large())
    False -> Ok(quotas)
  }
}

fn decrement_quota(
  quota: Int,
  size: Int,
) -> Result(Int, Response(state, message, data)) {
  case quota - size {
    quota if quota < 0 -> Error(entity_too_large())
    quota -> Ok(quota)
  }
}

fn buffered_read(
  reader: BufferedReader,
  chunk_size: Int,
) -> Result(internal.Read, Nil) {
  case reader.buffer {
    <<>> -> reader.reader(chunk_size)
    _ -> Ok(internal.Chunk(reader.buffer, reader.reader))
  }
}

/// Set the maximum permitted size of a request body of the request in bytes.
///
/// If a body is larger than this size attempting to read the body will result
/// in a response with status code 413: Entity too large will be returned to the
/// client.
///
/// This limit only applies for headers and bodies that get read into memory.
/// Part of a multipart body that contain files and so are streamed to disc
/// instead use the `max_files_size` limit.
///
pub fn set_max_body_size(request: Request, size: Int) -> Request {
  internal.Connection(..request.body, max_body_size: size)
  |> request.set_body(request, _)
}

/// Get the maximum permitted size of a request body of the request in bytes.
///
pub fn get_max_body_size(request: Request) -> Int {
  request.body.max_body_size
}

/// Set the secret key base used to sign cookies and other sensitive data.
///
/// This key must be at least 64 bytes long and should be kept secret. Anyone
/// with this secret will be able to manipulate signed cookies and other sensitive
/// data.
///
/// # Panics
///
/// This function will panic if the key is less than 64 bytes long.
///
pub fn set_secret_key_base(request: Request, key: String) -> Request {
  case string.byte_size(key) < 64 {
    True -> panic as "Secret key base must be at least 64 bytes long"
    False ->
      internal.Connection(..request.body, secret_key_base: key)
      |> request.set_body(request, _)
  }
}

/// Get the secret key base used to sign cookies and other sensitive data.
///
pub fn get_secret_key_base(request: Request) -> String {
  request.body.secret_key_base
}

/// Set the maximum permitted size of all files uploaded by a request, in bytes.
///
/// If a request contains fails which are larger in total than this size
/// then attempting to read the body will result in a response with status code
/// 413: Entity too large will be returned to the client.
///
/// This limit only applies for files in a multipart body that get streamed to
/// disc. For headers and other content that gets read into memory use the
/// `max_body_size` limit.
///
pub fn set_max_files_size(request: Request, size: Int) -> Request {
  internal.Connection(..request.body, max_files_size: size)
  |> request.set_body(request, _)
}

/// Get the maximum permitted total size of a files uploaded by a request in
/// bytes.
///
pub fn get_max_files_size(request: Request) -> Int {
  request.body.max_files_size
}

/// The the size limit for each chunk of the request body when read from the
/// client.
///
/// This value is passed to the underlying web server when reading the body and
/// the exact size of chunks read depends on the server implementation. It most
/// likely will read chunks smaller than this size if not yet enough data has
/// been received from the client.
///
pub fn set_read_chunk_size(request: Request, size: Int) -> Request {
  internal.Connection(..request.body, read_chunk_size: size)
  |> request.set_body(request, _)
}

/// Get the size limit for each chunk of the request body when read from the
/// client.
///
pub fn get_read_chunk_size(request: Request) -> Int {
  request.body.read_chunk_size
}

/// A convenient alias for a HTTP request with a Wisp connection as the body.
///
pub type Request =
  HttpRequest(internal.Connection)

/// This middleware function ensures that the request has a specific HTTP
/// method, returning an empty response with status code 405: Method not allowed
/// if the method is not correct.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use <- wisp.require_method(request, http.Patch)
///   // ...
/// }
/// ```
///
pub fn require_method(
  request: HttpRequest(t),
  method: Method,
  next: fn() -> Response(state, message, data),
) -> Response(state, message, data) {
  case request.method == method {
    True -> next()
    False -> method_not_allowed(allowed: [method])
  }
}

// TODO: re-export once Gleam has a syntax for that
/// Return the non-empty segments of a request path.
///
/// # Examples
///
/// ```gleam
/// > request.new()
/// > |> request.set_path("/one/two/three")
/// > |> wisp.path_segments
/// ["one", "two", "three"]
/// ```
///
pub const path_segments = request.path_segments

// TODO: re-export once Gleam has a syntax for that
/// Set a given header to a given value, replacing any existing value.
///
/// # Examples
///
/// ```gleam
/// > wisp.ok()
/// > |> wisp.set_header("content-type", "application/json")
/// Request(200, [#("content-type", "application/json")], Empty)
/// ```
///
pub const set_header = response.set_header

/// Parse the query parameters of a request into a list of key-value pairs. The
/// `key_find` function in the `gleam/list` stdlib module may be useful for
/// finding values in the list.
///
/// Query parameter names do not have to be unique and so may appear multiple
/// times in the list.
///
pub fn get_query(request: Request) -> List(#(String, String)) {
  request.get_query(request)
  |> result.unwrap([])
}

/// This function overrides an incoming POST request with a method given in
/// the request's `_method` query paramerter. This is useful as web browsers
/// typically only support GET and POST requests, but our application may
/// expect other HTTP methods that are more semantically correct.
///
/// The methods PUT, PATCH, and DELETE are accepted for overriding, all others
/// are ignored.
///
/// The `_method` query paramerter can be specified in a HTML form like so:
///
///    <form method="POST" action="/item/1?_method=DELETE">
///      <button type="submit">Delete item</button>
///    </form>
///
/// # Examples
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   let request = wisp.method_override(request)
///   // The method has now been overridden if appropriate
/// }
/// ```
///
pub fn method_override(request: HttpRequest(a)) -> HttpRequest(a) {
  use <- bool.guard(when: request.method != http.Post, return: request)
  {
    use query <- result.try(request.get_query(request))
    use value <- result.try(list.key_find(query, "_method"))
    use method <- result.map(http.parse_method(value))

    case method {
      http.Put | http.Patch | http.Delete -> request.set_method(request, method)
      _ -> request
    }
  }
  |> result.unwrap(request)
}

// TODO: don't always return entity too large. Other errors are possible, such as
// network errors.
/// A middleware function which reads the entire body of the request as a string.
///
/// This function does not cache the body in any way, so if you call this
/// function (or any other body reading function) more than once it may hang or
/// return an incorrect value, depending on the underlying web server. It is the
/// responsibility of the caller to cache the body if it is needed multiple
/// times.
///
/// If the body is larger than the `max_body_size` limit then an empty response
/// with status code 413: Entity too large will be returned to the client.
///
/// If the body is found not to be valid UTF-8 then an empty response with
/// status code 400: Bad request will be returned to the client.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use body <- wisp.require_string_body(request)
///   // ...
/// }
/// ```
///
pub fn require_string_body(
  request: Request,
  next: fn(String) -> Response(state, message, data),
) -> Response(state, message, data) {
  case read_body_to_bitstring(request) {
    Ok(body) -> or_400(bit_array.to_string(body), next)
    Error(_) -> entity_too_large()
  }
}

// TODO: don't always return entity too large. Other errors are possible, such as
// network errors.
/// A middleware function which reads the entire body of the request as a bit
/// string.
///
/// This function does not cache the body in any way, so if you call this
/// function (or any other body reading function) more than once it may hang or
/// return an incorrect value, depending on the underlying web server. It is the
/// responsibility of the caller to cache the body if it is needed multiple
/// times.
///
/// If the body is larger than the `max_body_size` limit then an empty response
/// with status code 413: Entity too large will be returned to the client.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use body <- wisp.require_string_body(request)
///   // ...
/// }
/// ```
///
pub fn require_bit_array_body(
  request: Request,
  next: fn(BitArray) -> Response(state, message, data),
) -> Response(state, message, data) {
  case read_body_to_bitstring(request) {
    Ok(body) -> next(body)
    Error(_) -> entity_too_large()
  }
}

// TODO: don't always return entity to large. Other errors are possible, such as
// network errors.
/// Read the entire body of the request as a bit string.
///
/// You may instead wish to use the `require_bit_array_body` or the
/// `require_string_body` middleware functions instead.
///
/// This function does not cache the body in any way, so if you call this
/// function (or any other body reading function) more than once it may hang or
/// return an incorrect value, depending on the underlying web server. It is the
/// responsibility of the caller to cache the body if it is needed multiple
/// times.
///
/// If the body is larger than the `max_body_size` limit then an empty response
/// with status code 413: Entity too large will be returned to the client.
///
pub fn read_body_to_bitstring(request: Request) -> Result(BitArray, Nil) {
  let connection = request.body
  read_body_loop(
    connection.reader,
    connection.read_chunk_size,
    connection.max_body_size,
    <<>>,
  )
}

fn read_body_loop(
  reader: internal.Reader,
  read_chunk_size: Int,
  max_body_size: Int,
  accumulator: BitArray,
) -> Result(BitArray, Nil) {
  use chunk <- result.try(reader(read_chunk_size))
  case chunk {
    internal.ReadingFinished -> Ok(accumulator)
    internal.Chunk(chunk, next) -> {
      let accumulator = bit_array.append(accumulator, chunk)
      case bit_array.byte_size(accumulator) > max_body_size {
        True -> Error(Nil)
        False ->
          read_body_loop(next, read_chunk_size, max_body_size, accumulator)
      }
    }
  }
}

/// A middleware which extracts form data from the body of a request that is
/// encoded as either `application/x-www-form-urlencoded` or
/// `multipart/form-data`.
///
/// Extracted fields are sorted into alphabetical order by key, so if you wish
/// to use pattern matching the order can be relied upon.
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use form <- wisp.require_form(request)
///   case form.values {
///     [#("password", pass), #("username", username)] -> // ...
///     _ -> // ...
///   }
/// }
/// ```
///
/// The `set_max_body_size`, `set_max_files_size`, and `set_read_chunk_size` can
/// be used to configure the reading of the request body.
///
/// Any file uploads will streamed into temporary files on disc. These files are
/// automatically deleted when the request handler returns, so if you wish to
/// use them after the request has completed you will need to move them to a new
/// location.
///
/// If the request does not have a recognised `content-type` header then an
/// empty response with status code 415: Unsupported media type will be returned
/// to the client.
///
/// If the request body is larger than the `max_body_size` or `max_files_size`
/// limits then an empty response with status code 413: Entity too large will be
/// returned to the client.
///
/// If the body cannot be parsed successfully then an empty response with status
/// code 400: Bad request will be returned to the client.
///
pub fn require_form(
  request: Request,
  next: fn(FormData) -> Response(state, message, data),
) -> Response(state, message, data) {
  case list.key_find(request.headers, "content-type") {
    Ok("application/x-www-form-urlencoded")
    | Ok("application/x-www-form-urlencoded;" <> _) ->
      require_urlencoded_form(request, next)

    Ok("multipart/form-data; boundary=" <> boundary) ->
      require_multipart_form(request, boundary, next)

    Ok("multipart/form-data") -> bad_request()

    _ ->
      unsupported_media_type([
        "application/x-www-form-urlencoded", "multipart/form-data",
      ])
  }
}

/// This middleware function ensures that the request has a value for the
/// `content-type` header, returning an empty response with status code 415:
/// Unsupported media type if the header is not the expected value
///
/// # Examples
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use <- wisp.require_content_type(request, "application/json")
///   // ...
/// }
/// ```
///
pub fn require_content_type(
  request: Request,
  expected: String,
  next: fn() -> Response(state, message, data),
) -> Response(state, message, data) {
  case list.key_find(request.headers, "content-type") {
    Ok(content_type) ->
      // This header may have further such as `; charset=utf-8`, so discard
      // that if it exists.
      case string.split_once(content_type, ";") {
        Ok(#(content_type, _)) if content_type == expected -> next()
        _ if content_type == expected -> next()
        _ -> unsupported_media_type([expected])
      }

    _ -> unsupported_media_type([expected])
  }
}

/// A middleware which extracts JSON from the body of a request.
///
/// ```gleam
/// fn handle_request(request: Request) -> Response {
///   use json <- wisp.require_json(request)
///   // decode and use JSON here...
/// }
/// ```
///
/// The `set_max_body_size` and `set_read_chunk_size` can be used to configure
/// the reading of the request body.
///
/// If the request does not have the `content-type` set to `application/json` an
/// empty response with status code 415: Unsupported media type will be returned
/// to the client.
///
/// If the request body is larger than the `max_body_size` or `max_files_size`
/// limits then an empty response with status code 413: Entity too large will be
/// returned to the client.
///
/// If the body cannot be parsed successfully then an empty response with status
/// code 400: Bad request will be returned to the client.
///
pub fn require_json(
  request: Request,
  next: fn(Dynamic) -> Response(state, message, data),
) -> Response(state, message, data) {
  use <- require_content_type(request, "application/json")
  use body <- require_string_body(request)
  use json <- or_400(json.parse(body, decode.dynamic))
  next(json)
}

fn require_urlencoded_form(
  request: Request,
  next: fn(FormData) -> Response(state, message, data),
) -> Response(state, message, data) {
  use body <- require_string_body(request)
  use pairs <- or_400(uri.parse_query(body))
  let pairs = sort_keys(pairs)
  next(FormData(values: pairs, files: []))
}

fn require_multipart_form(
  request: Request,
  boundary: String,
  next: fn(FormData) -> Response(state, message, data),
) -> Response(state, message, data) {
  let quotas =
    Quotas(files: request.body.max_files_size, body: request.body.max_body_size)
  let reader = BufferedReader(request.body.reader, <<>>)

  let result =
    read_multipart(request, reader, boundary, quotas, FormData([], []))
  case result {
    Ok(form_data) -> next(form_data)
    Error(response) -> response
  }
}

fn read_multipart(
  request: Request,
  reader: BufferedReader,
  boundary: String,
  quotas: Quotas,
  data: FormData,
) -> Result(FormData, Response(state, message, data)) {
  let read_size = request.body.read_chunk_size

  // First we read the headers of the multipart part.
  let header_parser =
    fn_with_bad_request_error(http.parse_multipart_headers(_, boundary))
  let result = multipart_headers(reader, header_parser, read_size, quotas)
  use #(headers, reader, quotas) <- result.try(result)
  use #(name, filename) <- result.try(multipart_content_disposition(headers))

  // Then we read the body of the part.
  let parse = fn_with_bad_request_error(http.parse_multipart_body(_, boundary))
  use #(data, reader, quotas) <- result.try(case filename {
    // There is a file name, so we treat this as a file upload, streaming the
    // contents to a temporary file and using the dedicated files size quota.
    option.Some(file_name) -> {
      use path <- result.try(or_500(new_temporary_file(request)))
      let append = multipart_file_append
      let q = quotas.files
      let result =
        multipart_body(reader, parse, boundary, read_size, q, append, path)
      use #(reader, quota, _) <- result.map(result)
      let quotas = Quotas(..quotas, files: quota)
      let file = UploadedFile(path: path, file_name: file_name)
      let data = FormData(..data, files: [#(name, file), ..data.files])
      #(data, reader, quotas)
    }

    // No file name, this is a regular form value that we hold in memory.
    option.None -> {
      let append = fn(data, chunk) { Ok(bit_array.append(data, chunk)) }
      let q = quotas.body
      let result =
        multipart_body(reader, parse, boundary, read_size, q, append, <<>>)
      use #(reader, quota, value) <- result.try(result)
      let quotas = Quotas(..quotas, body: quota)
      use value <- result.map(bit_array_to_string(value))
      let data = FormData(..data, values: [#(name, value), ..data.values])
      #(data, reader, quotas)
    }
  })

  case reader {
    // There's at least one more part, read it.
    option.Some(reader) ->
      read_multipart(request, reader, boundary, quotas, data)
    // There are no more parts, we're done.
    option.None -> Ok(FormData(sort_keys(data.values), sort_keys(data.files)))
  }
}

fn bit_array_to_string(
  bits: BitArray,
) -> Result(String, Response(state, message, data)) {
  bit_array.to_string(bits)
  |> result.replace_error(bad_request())
}

fn multipart_file_append(
  path: String,
  chunk: BitArray,
) -> Result(String, Response(state, message, data)) {
  simplifile.append_bits(path, chunk)
  |> or_500
  |> result.replace(path)
}

fn or_500(result: Result(a, b)) -> Result(a, Response(state, message, data)) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> {
      log_error(string.inspect(error))
      Error(internal_server_error())
    }
  }
}

fn multipart_body(
  reader: BufferedReader,
  parse: fn(BitArray) -> Result(http.MultipartBody, Response(state, message, data)),
  boundary: String,
  chunk_size: Int,
  quota: Int,
  append: fn(t, BitArray) -> Result(t, Response(state, message, data)),
  data: t,
) -> Result(#(Option(BufferedReader), Int, t), Response(state, message, data)) {
  use #(chunk, reader) <- result.try(read_chunk(reader, chunk_size))
  let size_read = bit_array.byte_size(chunk)
  use output <- result.try(parse(chunk))

  case output {
    http.MultipartBody(parsed, done, remaining) -> {
      // Decrement the quota by the number of bytes consumed.
      let used = size_read - bit_array.byte_size(remaining) - 2
      let used = case done {
        // If this is the last chunk, we need to account for the boundary.
        True -> used - 4 - string.byte_size(boundary)
        False -> used
      }
      use quota <- result.try(decrement_quota(quota, used))

      let reader = BufferedReader(reader, remaining)
      let reader = case done {
        True -> option.None
        False -> option.Some(reader)
      }
      use value <- result.map(append(data, parsed))
      #(reader, quota, value)
    }

    http.MoreRequiredForBody(chunk, parse) -> {
      let parse = fn_with_bad_request_error(parse)
      let reader = BufferedReader(reader, <<>>)
      use data <- result.try(append(data, chunk))
      multipart_body(reader, parse, boundary, chunk_size, quota, append, data)
    }
  }
}

fn fn_with_bad_request_error(
  f: fn(a) -> Result(b, c),
) -> fn(a) -> Result(b, Response(state, message, data)) {
  fn(a) {
    f(a)
    |> result.replace_error(bad_request())
  }
}

fn multipart_content_disposition(
  headers: List(http.Header),
) -> Result(#(String, Option(String)), Response(state, message, data)) {
  {
    use header <- result.try(list.key_find(headers, "content-disposition"))
    use header <- result.try(http.parse_content_disposition(header))
    use name <- result.map(list.key_find(header.parameters, "name"))
    let filename =
      option.from_result(list.key_find(header.parameters, "filename"))
    #(name, filename)
  }
  |> result.replace_error(bad_request())
}

fn read_chunk(
  reader: BufferedReader,
  chunk_size: Int,
) -> Result(#(BitArray, internal.Reader), Response(state, message, data)) {
  buffered_read(reader, chunk_size)
  |> result.replace_error(bad_request())
  |> result.try(fn(chunk) {
    case chunk {
      internal.Chunk(chunk, next) -> Ok(#(chunk, next))
      internal.ReadingFinished -> Error(bad_request())
    }
  })
}

fn multipart_headers(
  reader: BufferedReader,
  parse: fn(BitArray) -> Result(http.MultipartHeaders, Response(state, message, data)),
  chunk_size: Int,
  quotas: Quotas,
) -> Result(
  #(List(http.Header), BufferedReader, Quotas),
  Response(state, message, data),
) {
  use #(chunk, reader) <- result.try(read_chunk(reader, chunk_size))
  use headers <- result.try(parse(chunk))

  case headers {
    http.MultipartHeaders(headers, remaining) -> {
      let used = bit_array.byte_size(chunk) - bit_array.byte_size(remaining)
      use quotas <- result.map(decrement_body_quota(quotas, used))
      let reader = BufferedReader(reader, remaining)
      #(headers, reader, quotas)
    }
    http.MoreRequiredForHeaders(parse) -> {
      let parse = fn(chunk) {
        parse(chunk)
        |> result.replace_error(bad_request())
      }
      let reader = BufferedReader(reader, <<>>)
      multipart_headers(reader, parse, chunk_size, quotas)
    }
  }
}

fn sort_keys(pairs: List(#(String, t))) -> List(#(String, t)) {
  list.sort(pairs, fn(a, b) { string.compare(a.0, b.0) })
}

fn or_400(
  result: Result(value, error),
  next: fn(value) -> Response(state, message, data),
) -> Response(state, message, data) {
  case result {
    Ok(value) -> next(value)
    Error(_) -> bad_request()
  }
}

/// Data parsed from form sent in a request's body.
///
pub type FormData {
  FormData(
    /// String values of the form's fields.
    values: List(#(String, String)),
    /// Uploaded files.
    files: List(#(String, UploadedFile)),
  )
}

pub type UploadedFile {
  UploadedFile(
    /// The name that was given to the file in the form.
    /// This is user input and should not be trusted.
    file_name: String,
    /// The location of the file on the server.
    /// This is a temporary file and will be deleted when the request has
    /// finished being handled.
    path: String,
  )
}

//
// Middleware
//

/// A middleware function that rescues crashes and returns an empty response
/// with status code 500: Internal server error.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(req: Request) -> Response {
///   use <- wisp.rescue_crashes
///   // ...
/// }
/// ```
///
pub fn rescue_crashes(
  handler: fn() -> Response(state, message, data),
) -> Response(state, message, data) {
  case exception.rescue(handler) {
    Ok(response) -> response
    Error(error) -> {
      let #(kind, detail) = case error {
        exception.Errored(detail) -> #(Errored, detail)
        exception.Thrown(detail) -> #(Thrown, detail)
        exception.Exited(detail) -> #(Exited, detail)
      }
      case decode.run(detail, atom_dict_decoder()) {
        Ok(details) -> {
          let c = atom.create("class")
          log_error_dict(dict.insert(details, c, error_kind_to_dynamic(kind)))
          Nil
        }
        Error(_) -> log_error(string.inspect(error))
      }
      internal_server_error()
    }
  }
}

@external(erlang, "gleam@function", "identity")
fn error_kind_to_dynamic(kind: ErrorKind) -> Dynamic

fn atom_dict_decoder() -> decode.Decoder(Dict(Atom, Dynamic)) {
  let atom =
    decode.new_primitive_decoder("Atom", fn(data) {
      case atom_from_dynamic(data) {
        Ok(atom) -> Ok(atom)
        Error(_) -> Error(atom.create("nil"))
      }
    })
  decode.dict(atom, decode.dynamic)
}

@external(erlang, "wisp_ffi", "atom_from_dynamic")
fn atom_from_dynamic(data: Dynamic) -> Result(Atom, Nil)

type DoNotLeak

@external(erlang, "logger", "error")
fn log_error_dict(o: Dict(Atom, Dynamic)) -> DoNotLeak

type ErrorKind {
  Errored
  Thrown
  Exited
}

// TODO: test, somehow.
/// A middleware function that logs details about the request and response.
///
/// The format used logged by this middleware may change in future versions of
/// Wisp.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(req: Request) -> Response {
///   use <- wisp.log_request(req)
///   // ...
/// }
/// ```
///
pub fn log_request(
  req: Request,
  handler: fn() -> Response(state, message, data),
) -> Response(state, message, data) {
  let response = handler()
  [
    int.to_string(response.status),
    " ",
    string.uppercase(http.method_to_string(req.method)),
    " ",
    req.path,
  ]
  |> string.concat
  |> log_info
  response
}

/// A middleware function that serves files from a directory, along with a
/// suitable `content-type` header for known file extensions.
///
/// Files are sent using the `File` response body type, so they will be sent
/// directly to the client from the disc, without being read into memory.
///
/// The `under` parameter is the request path prefix that must match for the
/// file to be served.
///
/// | `under`   | `from`  | `request.path`     | `file`                  |
/// |-----------|---------|--------------------|-------------------------|
/// | `/static` | `/data` | `/static/file.txt` | `/data/file.txt`        |
/// | ``        | `/data` | `/static/file.txt` | `/data/static/file.txt` |
/// | `/static` | ``      | `/static/file.txt` | `file.txt`              |
///
/// This middleware will discard any `..` path segments in the request path to
/// prevent the client from accessing files outside of the directory. It is
/// advised not to serve a directory that contains your source code, application
/// configuration, database, or other private files.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(req: Request) -> Response {
///   use <- wisp.serve_static(req, under: "/static", from: "/public")
///   // ...
/// }
/// ```
///
/// Typically you static assets may be kept in your project in a directory
/// called `priv`. The `priv_directory` function can be used to get a path to
/// this directory.
///
/// ```gleam
/// fn handle_request(req: Request) -> Response {
///   let assert Ok(priv) = priv_directory("my_application")
///   use <- wisp.serve_static(req, under: "/static", from: priv)
///   // ...
/// }
/// ```
///
pub fn serve_static(
  req: Request,
  under prefix: String,
  from directory: String,
  next handler: fn() -> Response(state, message, data),
) -> Response(state, message, data) {
  let path = internal.remove_preceeding_slashes(req.path)
  let prefix = internal.remove_preceeding_slashes(prefix)
  case req.method, string.starts_with(path, prefix) {
    http.Get, True -> {
      let path =
        path
        |> string.drop_start(string.length(prefix))
        |> string.replace(each: "..", with: "")
        |> internal.join_path(directory, _)

      let file_type =
        req.path
        |> string.split(on: ".")
        |> list.last
        |> result.unwrap("")

      let mime_type = marceau.extension_to_mime_type(file_type)
      let content_type = case mime_type {
        "application/json" | "text/" <> _ -> mime_type <> "; charset=utf-8"
        _ -> mime_type
      }

      case simplifile.file_info(path) {
        Ok(file_info) ->
          case simplifile.file_info_type(file_info) {
            simplifile.File -> {
              response.new(200)
              |> response.set_header("content-type", content_type)
              |> response.set_body(File(path))
              |> handle_etag(req, file_info)
            }
            _ -> handler()
          }
        _ -> handler()
      }
    }
    _, _ -> handler()
  }
}

/// Calculates etag for requested file and then checks for the request header `if-none-match`.
///
/// If the header isn't present or the value doesn't match the newly generated etag, it returns the file with the newly generated etag.
/// Otherwise if the etag matches, it returns status 304 without the file, allowing the browser to use the cached version.
///
fn handle_etag(
  resp: Response(state, message, data),
  req: Request,
  file_info: simplifile.FileInfo,
) -> Response(state, message, data) {
  let etag = internal.generate_etag(file_info.size, file_info.mtime_seconds)

  case request.get_header(req, "if-none-match") {
    Ok(old_etag) if old_etag == etag ->
      response(304)
      |> set_header("etag", etag)
    _ -> response.set_header(resp, "etag", etag)
  }
}

/// A middleware function that converts `HEAD` requests to `GET` requests,
/// handles the request, and then discards the response body. This is useful so
/// that your application can handle `HEAD` requests without having to implement
/// handlers for them.
///
/// The `x-original-method` header is set to `"HEAD"` for requests that were
/// originally `HEAD` requests.
///
/// # Examples
///
/// ```gleam
/// fn handle_request(req: Request) -> Response {
///   use req <- wisp.handle_head(req)
///   // ...
/// }
/// ```
///
pub fn handle_head(
  req: Request,
  next handler: fn(Request) -> Response(state, message, data),
) -> Response(state, message, data) {
  case req.method {
    http.Head ->
      req
      |> request.set_method(http.Get)
      |> request.prepend_header("x-original-method", "HEAD")
      |> handler
    _ -> handler(req)
  }
}

//
// File uploads
//

/// Create a new temporary directory for the given request.
///
/// If you are using the Mist adapter or another compliant web server
/// adapter then this file will be deleted for you when the request is complete.
/// Otherwise you will need to call the `delete_temporary_files` function
/// yourself.
///
pub fn new_temporary_file(
  request: Request,
) -> Result(String, simplifile.FileError) {
  let directory = request.body.temporary_directory
  use _ <- result.try(simplifile.create_directory_all(directory))
  let path = internal.join_path(directory, internal.random_slug())
  use _ <- result.map(simplifile.create_file(path))
  path
}

/// Delete any temporary files created for the given request.
///
/// If you are using the Mist adapter or another compliant web server
/// adapter then this file will be deleted for you when the request is complete.
/// Otherwise you will need to call this function yourself.
///
pub fn delete_temporary_files(
  request: Request,
) -> Result(Nil, simplifile.FileError) {
  case simplifile.delete(request.body.temporary_directory) {
    Error(simplifile.Enoent) -> Ok(Nil)
    other -> other
  }
}

/// Returns the path of a package's `priv` directory, where extra non-Gleam
/// or Erlang files are typically kept.
///
/// Returns an error if no package was found with the given name.
///
/// # Example
///
/// ```gleam
/// > erlang.priv_directory("my_app")
/// // -> Ok("/some/location/my_app/priv")
/// ```
///
pub const priv_directory = application.priv_directory

//
// Logging
//

/// Configure the Erlang logger, setting the minimum log level to `info`, to be
/// called when your application starts.
///
/// You may wish to use an alternative for this such as one provided by a more
/// sophisticated logging library.
///
/// In future this function may be extended to change the output format.
///
pub fn configure_logger() -> Nil {
  logging.configure()
}

/// Type to set the log level of the Erlang's logger
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub type LogLevel {
  EmergencyLevel
  AlertLevel
  CriticalLevel
  ErrorLevel
  WarningLevel
  NoticeLevel
  InfoLevel
  DebugLevel
}

fn log_level_to_logging_log_level(log_level: LogLevel) -> logging.LogLevel {
  case log_level {
    EmergencyLevel -> logging.Emergency
    AlertLevel -> logging.Alert
    CriticalLevel -> logging.Critical
    ErrorLevel -> logging.Error
    WarningLevel -> logging.Warning
    NoticeLevel -> logging.Notice
    InfoLevel -> logging.Info
    DebugLevel -> logging.Debug
  }
}

/// Set the log level of the Erlang logger to `log_level`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn set_logger_level(log_level: LogLevel) -> Nil {
  logging.set_level(log_level_to_logging_log_level(log_level))
}

/// Log a message to the Erlang logger with the level of `emergency`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_emergency(message: String) -> Nil {
  logging.log(logging.Emergency, message)
}

/// Log a message to the Erlang logger with the level of `alert`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_alert(message: String) -> Nil {
  logging.log(logging.Alert, message)
}

/// Log a message to the Erlang logger with the level of `critical`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_critical(message: String) -> Nil {
  logging.log(logging.Critical, message)
}

/// Log a message to the Erlang logger with the level of `error`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_error(message: String) -> Nil {
  logging.log(logging.Error, message)
}

/// Log a message to the Erlang logger with the level of `warning`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_warning(message: String) -> Nil {
  logging.log(logging.Warning, message)
}

/// Log a message to the Erlang logger with the level of `notice`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_notice(message: String) -> Nil {
  logging.log(logging.Notice, message)
}

/// Log a message to the Erlang logger with the level of `info`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_info(message: String) -> Nil {
  logging.log(logging.Info, message)
}

/// Log a message to the Erlang logger with the level of `debug`.
///
/// See the [Erlang logger documentation][1] for more information.
///
/// [1]: https://www.erlang.org/doc/man/logger
///
pub fn log_debug(message: String) -> Nil {
  logging.log(logging.Debug, message)
}

//
// Cryptography
//

/// Generate a random string of the given length.
///
pub fn random_string(length: Int) -> String {
  internal.random_string(length)
}

/// Sign a message which can later be verified using the `verify_signed_message`
/// function to detect if the message has been tampered with.
///
/// Signed messages are not encrypted and can be read by anyone. They are not
/// suitable for storing sensitive information.
///
/// This function uses the secret key base from the request. If the secret
/// changes then the signature will no longer be verifiable.
///
pub fn sign_message(
  request: Request,
  message: BitArray,
  algorithm: crypto.HashAlgorithm,
) -> String {
  crypto.sign_message(message, <<request.body.secret_key_base:utf8>>, algorithm)
}

/// Verify a signed message which was signed using the `sign_message` function.
///
/// Returns the content of the message if the signature is valid, otherwise
/// returns an error.
///
/// This function uses the secret key base from the request. If the secret
/// changes then the signature will no longer be verifiable.
///
pub fn verify_signed_message(
  request: Request,
  message: String,
) -> Result(BitArray, Nil) {
  crypto.verify_signed_message(message, <<request.body.secret_key_base:utf8>>)
}

//
// Cookies
//

/// Set a cookie on the response. After `max_age` seconds the cookie will be
/// expired by the client.
///
/// This function will sign the value if the `security` parameter is set to
/// `Signed`, making it so the cookie cannot be tampered with by the client.
///
/// Values are base64 encoded so they can contain any characters you want, even
/// if they would not be permitted directly in a cookie.
///
/// Cookies are set using `gleam_http`'s default attributes for HTTPS. If you
/// wish for more control over the cookie attributes then you may want to use
/// the `gleam/http/cookie` module from the `gleam_http` package instead of this
/// function. Be sure to sign and escape the cookie value as needed.
///
/// # Examples
///
/// Setting a plain text cookie that the client can read and modify:
///
/// ```gleam
/// wisp.ok()
/// |> wisp.set_cookie(request, "id", "123", wisp.PlainText, 60 * 60)
/// ```
///
/// Setting a signed cookie that the client can read but not modify:
///
/// ```gleam
/// wisp.ok()
/// |> wisp.set_cookie(request, "id", value, wisp.Signed, 60 * 60)
/// ```
///
pub fn set_cookie(
  response response: Response(state, message, data),
  request request: Request,
  name name: String,
  value value: String,
  security security: Security,
  max_age max_age: Int,
) -> Response(state, message, data) {
  let attributes =
    cookie.Attributes(
      ..cookie.defaults(http.Https),
      max_age: option.Some(max_age),
    )
  let value = case security {
    PlainText -> bit_array.base64_encode(<<value:utf8>>, False)
    Signed -> sign_message(request, <<value:utf8>>, crypto.Sha512)
  }
  response
  |> response.set_cookie(name, value, attributes)
}

pub type Security {
  /// The value is store as plain text without any additional security.
  /// The client will be able to read and modify the value, and create new values.
  PlainText
  /// The value is signed to prevent modification.
  /// The client will be able to read the value but not modify it, or create new
  /// values.
  Signed
}

/// Get a cookie from the request.
///
/// If a cookie is missing, found to be malformed, or the signature is invalid
/// for a signed cookie, then `Error(Nil)` is returned.
///
/// ```gleam
/// wisp.get_cookie(request, "group", wisp.PlainText)
/// // -> Ok("A")
/// ```
///
pub fn get_cookie(
  request request: Request,
  name name: String,
  security security: Security,
) -> Result(String, Nil) {
  use value <- result.try(
    request
    |> request.get_cookies
    |> list.key_find(name),
  )
  use value <- result.try(case security {
    PlainText -> bit_array.base64_decode(value)
    Signed -> verify_signed_message(request, value)
  })
  bit_array.to_string(value)
}

//
// Server-Sent Events
//

/// An error which occurs when sending a server-sent event.
pub type SSEError {
  UnexpectedSSEError
}

/// Send a SSEEvent
pub type SendEvent =
  fn(SSEEvent) -> Result(Nil, SSEError)


/// Initialise a server-sent event actor
pub fn sse(
  request: Request,
  init: Init(state, message, data),
  loop: Loop(state, message),
) -> Result(Response(state, message, data), String) {
  use <- bool.guard(
    when: option.is_none(request.body.sse_enabled),
    return: Error("SSE not enabled"),
  )

  Ok(HttpResponse(200, [], ServerSentEvent(init, loop)))
}

/// Initialise an actor
pub type Init(state, message, return) =
  fn(process.Subject(message)) ->
    Result(actor.Initialised(state, message, return), String)

/// Process an event coming from an actor
pub type Loop(state, message) =
  fn(state, message, fn(SSEEvent) -> Result(Nil, SSEError)) ->
    actor.Next(state, message)

/// A server-sent event represented in Gleam.
///
/// See the [Mozzilla SSE documentation][1] for more information.
///
/// [1]: https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
///
pub type SSEEvent {
  SSEEvent(
    data: String,
    event: Option(String),
    id: Option(String),
    retry: Option(Int),
  )
}

//
// Testing
//

// TODO: chunk the body
/// Create a connection which will return the given body when read.
///
/// This function is intended for use in tests, though you probably want the
/// `wisp/testing` module instead.
///
pub fn create_canned_connection(
  body: BitArray,
  secret_key_base: String,
) -> internal.Connection {
  internal.make_connection(
    fn(_size) {
      Ok(internal.Chunk(body, fn(_size) { Ok(internal.ReadingFinished) }))
    },
    secret_key_base,
  )
}
