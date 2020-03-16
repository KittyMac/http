use "collections"
use "net"
use "net_ssl"
use "time"
use "debug"

interface tag _SessionRegistry
  be register_session(conn: _ServerConnection)
  be unregister_session(conn: _ServerConnection)

actor HTTPServer is _SessionRegistry
  """
  Runs an HTTP server.

  ### Server operation

  Information flow into the Server is as follows:

  1. `Server` listens for incoming TCP connections.

  2. `RequestBuilder` is the notification class for new connections. It creates
  a `ServerConnection` actor and receives all the raw data from TCP. It uses
  the `HTTPParser` to assemble complete `Payload` objects which are passed off
  to the `ServerConnection`.

  3. The `ServerConnection` actor deals with *completely formed* requests
  that have been parsed by the `HTTPParser`. This is where requests get
  dispatched to the caller-provided Handler.

  With streaming content, dispatch to the application's back end Handler
  has to happen *before* all of the body has been received. This has to be
  carefully choreographed because a `Payload` is an `iso` object and can only
  belong to one actor at a time, yet the `RequestBuilder` is running within
  the `TCPConnection` actor while the `RequestHandler` is running under the
  `ServerConnection` actor. Each incoming bufferful of body data, a
  `ByteSeq val`, is handed off to `ServerConnection`, to be passed on to the
  back end Handler.

  1. It turns out that the issues in sending a request and a response are the
  same, as are the issues in receiving them. Therefore the same notification
  interface, `HTTPHandler` is used on both ends, and the same sending
  interface `HTTPSession` is used. This makes the code easier to read as well.

  1. `HTTPHandler.apply()` will be the way the client/server is informed of a
  new response/request message. All of the headers will be present so that the
  request can be dispatched for correct processing. Subsequent calls to a new
  function `HTTPHandler.chunk` will provide the body data, if any. This
  stream will be terminated by a call to the new function
  `HTTPHandler.finished`.

  2. Pipelining of requests is to optimize the transmission of requests over
  slow links (such as over satellites), not to cause simultaneous execution
  on the server within one session. Multiple received simple requests (`GET`,
  `HEAD`, and `OPTIONS`) are queued in the server and passed to the back end
  application one at a time. If a client wants true parallel execution of
  requests, it should use multiple sessions (which many browsers actually
  do already).

  Since processing of a streaming response can take a relatively long time,
  acting on additional requests in the meantime does nothing but use up memory
  since responses would have to be queued. And if the server is being used to
  stream media, it is possible that these additional requests will themselves
  generate large responses.  Instead we will just let the requests queue up
  until a maximum queue length is reached (a small number) at which point we
  will back-pressure the inbound TCP stream.
  """
  let _notify: ServerNotify
  var _handler_maker: HandlerFactory val
  let _config: HTTPServerConfig
  let _sslctx: (SSLContext | None)
  let _listen: TCPListener
  var _address: NetAddress
  let _sessions: SetIs[_ServerConnection tag] = SetIs[_ServerConnection tag]
  let _timers: Timers = Timers
  var _timer: (Timer tag | None) = None

  new create(
    auth: TCPListenerAuth,
    notify: ServerNotify iso,
    handler: HandlerFactory val,
    config: HTTPServerConfig,
    sslctx: (SSLContext | None) = None)
  =>
    """
    Create a server bound to the given host and service. To do this we
    listen for incoming TCP connections, with a notification handler
    that will create a server session actor for each one.
    """
    _notify = consume notify
    _handler_maker = handler
    _config = HTTPServerConfig
    _sslctx = sslctx

    _listen = TCPListener(auth,
        _ServerListener(this, config, sslctx, _handler_maker),
        config.host, config.port, config.max_concurrent_connections)

    _address = recover NetAddress end

  be register_session(conn: _ServerConnection) =>
    _sessions.set(conn)

    // only start a timer if we have a connection-timeout configured
    if _config.has_timeout() then
      match _timer
      | None =>
        let that: HTTPServer tag = this
        let timeout_interval = _config.timeout_heartbeat_interval
        let t = Timer(
          object iso is TimerNotify
            fun ref apply(timer': Timer, count: U64): Bool =>
              that._start_heartbeat()
              true
          end,
          Nanos.from_seconds(timeout_interval),
          Nanos.from_seconds(timeout_interval))
        _timer = t
        _timers(consume t)
      end
    end

  be _start_heartbeat() =>
    // iterate through _sessions and ping all connections
    let current_seconds = Time.seconds() // seconds resolution is fine
    for session in _sessions.values() do
      session._heartbeat(current_seconds)
    end

  be unregister_session(conn: _ServerConnection) =>
    _sessions.unset(conn)

  be set_handler(handler: HandlerFactory val) =>
    """
    Replace the request handler.
    """
    _handler_maker = handler
    _listen.set_notify(
      _ServerListener(this, _config, _sslctx, _handler_maker))

  be dispose() =>
    """
    Shut down the server gracefully. To do this we have to eliminate
    any source of further inputs. So we stop listening for new incoming
    TCP connections, and close any that still exist.
    """
    _listen.dispose()
    _timers.dispose()
    for conn in _sessions.values() do
      conn.dispose()
    end

  fun local_address(): NetAddress =>
    """
    Returns the locally bound address.
    """
    _address

  be _listening(address: NetAddress) =>
    """
    Called when we are listening.
    """
    _address = address
    _notify.listening(this)

  be _not_listening() =>
    """
    Called when we fail to listen.
    """
    _notify.not_listening(this)

  be _closed() =>
    """
    Called when we stop listening.
    """
    _notify.closed(this)

