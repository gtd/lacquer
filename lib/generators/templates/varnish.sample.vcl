backend default {
  .host = "0.0.0.0";
  .port = "10000";
}


#
# Handling of requests that are received from clients.
# First decide whether or not to lookup data in the cache.
#
sub vcl_recv {
  # Pipe requests that are non-RFC2616 or CONNECT which is weird.
  if (req.request != "GET" &&
      req.request != "HEAD" &&
      req.request != "PUT" &&
      req.request != "POST" &&
      req.request != "TRACE" &&
      req.request != "OPTIONS" &&
      req.request != "DELETE") {
    pipe;
  }

  # Pass requests that are not GET or HEAD
  if (req.request != "GET" && req.request != "HEAD") {
    pass;
  }

  # Pass requests that we know we aren't caching
  if (req.url ~ "^/admin") {
    pass;
  }

  #
  # Everything below here should be cached
  #

  # Handle compression correctly. Varnish treats headers literally, not
  # semantically. So it is very well possible that there are cache misses
  # because the headers sent by different browsers aren't the same.
  # @see: http://varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      # if the browser supports it, we'll use gzip
      set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
      # next, try deflate if it is supported
      set req.http.Accept-Encoding = "deflate";
    } else {
      # unknown algorithm. Probably junk, remove it
      remove req.http.Accept-Encoding;
    }
  }

  # Clear cookie and authorization headers, set grace time, lookup in the cache
  unset req.http.Cookie;
  unset req.http.Authorization;
  set req.grace = 30s;
  lookup;
}

#
# Called when entering pipe mode
#
sub vcl_pipe {
  # If we don't set the Connection: close header, any following
  # requests from the client will also be piped through and
  # left untouched by varnish. We don't want that.
  set req.http.connection = "close";
  pipe;
}

#
# Called when the requested object has been retrieved from the
# backend, or the request to the backend has failed
#
sub vcl_fetch {
  # Do not cache the object if the backend application does not want us to.
  if (obj.http.Cache-Control ~ "(no-cache|no-store|private|must-revalidate)") {
    pass;
  }

  # Do not cache the object if the status is not in the 200s
  if (obj.status >= 300) {
    # Remove the Set-Cookie header
    remove obj.http.Set-Cookie;
    pass;
  }

  #
  # Everything below here should be cached
  #

  # Remove the Set-Cookie header
  remove obj.http.Set-Cookie;

  # Set the grace time
  set obj.grace = 30s;

  # Deliver the object
  deliver;
}

#
# Called before the response is sent back to the client
#
sub vcl_deliver {
  # Force browsers and intermediary caches to always check back with us
  set resp.http.Cache-Control = "private, max-age=0, must-revalidate";
  set resp.http.Pragma = "no-cache";

  # Add a header to indicate a cache HIT/MISS
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  } else {
    set resp.http.X-Cache = "MISS";
  }
}
