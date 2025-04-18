# This R script is a proxy. It takes input on stdin, and when the input forms
# valid JSON, it will send the JSON to the server. Then, when it receives the
# response, it will print the response to stdout.
#' @rdname mcp
#' @export
mcp_proxy <- function() {
  # TODO: should this actually be a check for being called within Rscript or not?
  check_not_interactive()

  the$proxy_socket <- nanonext::socket("pair", dial = acquaint_socket)

  # Note that we're using file("stdin") instead of stdin(), which are not the
  # same.
  the$f <- file("stdin")
  open(the$f, blocking = FALSE)

  schedule_handle_message_from_client()
  schedule_handle_message_from_server()

  # Pump the event loop
  while (TRUE) {
    later::run_now(Inf)
  }
}

handle_message_from_client <- function(fdstatus) {
  buf <- ""
  schedule_handle_message_from_client()
  # TODO: Read multiple lines all at once (because the server can send
  # multiple requests quickly), and then handle each line separately.
  # Otherwise, the message throughput will be bound by the polling rate.
  line <- readLines(the$f, n = 1)
  # TODO: If stdin is closed, we should exit. Not sure there's a way to detect
  # that stdin has been closed without writing C code, though.

  if (length(line) == 0) {
    return()
  }

  logcat("FROM CLIENT: ", line)

  buf <- paste0(c(buf, line), collapse = "\n")

  data <- NULL

  tryCatch(
    {
      data <- jsonlite::fromJSON(buf)
    },
    error = function(e) {
      # Invalid JSON. Possibly unfinished multi-line JSON message?
    }
  )

  if (is.null(data)) {
    # Can get here if there's an empty line
    return()
  }

  if (!is.list(data) || is.null(data$method)) {
    cat_json(jsonrpc_response(
      data$id,
      error = list(code = -32600, message = "Invalid Request")
    ))
  }

  # If we made it here, it's valid JSON

  if (data$method == "initialize") {
    res <- jsonrpc_response(data$id, capabilities())
    cat_json(res)
  } else if (data$method == "tools/list") {
    res <- jsonrpc_response(
      data$id,
      list(
        tools = get_all_btw_tools()
      )
    )

    cat_json(res)
  } else if (data$method == "tools/call") {
    result <- forward_request(buf)

    # } else if (data$method == "prompts/list") {
    # } else if (data$method == "resources/list") {
  } else if (is.null(data$id)) {
    # If there is no `id` in the request, then this is a notification and the
    # client does not expect a response.
    if (data$method == "notifications/initialized") {
    }
  } else {
    cat_json(jsonrpc_response(
      data$id,
      error = list(code = -32601, message = "Method not found")
    ))
  }

  buf <- ""
}

schedule_handle_message_from_client <- function() {
  # Schedule the callback to run when stdin (fd 0) has input.
  later::later_fd(handle_message_from_client, readfds = 0L)
}

handle_message_from_server <- function(data) {
  schedule_handle_message_from_server()

  logcat("FROM SERVER: ", data)

  # The response_text is alredy JSON, so we'll use cat() instead of cat_json()
  cat(data, "\n", sep = "")
}

schedule_handle_message_from_server <- function() {
  r <- nanonext::recv_aio(the$proxy_socket)
  promises::as.promise(r)$then(handle_message_from_server)
}

forward_request <- function(data) {
  logcat("TO SERVER: ", data)

  nanonext::send_aio(the$proxy_socket, data)
}

# This process will be launched by the MCP client, so stdout/stderr aren't
# visible. This function will log output to the `logfile` so that you can view
# it.
logcat <- function(x, ..., append = TRUE) {
  log_file <- acquaint_log_file()
  cat(x, "\n", sep = "", append = append, file = log_file)
}

cat_json <- function(x) {
  cat(to_json(x), "\n", sep = "")
}

capabilities <- function() {
  list(
    protocolVersion = "2024-11-05",
    capabilities = list(
      # logging = named_list(),
      prompts = named_list(
        listChanged = FALSE
      ),
      resources = named_list(
        subscribe = FALSE,
        listChanged = FALSE
      ),
      tools = named_list(
        listChanged = FALSE
      )
    ),
    serverInfo = list(
      name = "R acquaint server",
      version = "0.0.1"
    ),
    instructions = "This provides information about a running R session."
  )
}

# Hacky way of getting tools from btw
get_all_btw_tools <- function() {
  dummy_provider <- ellmer::Provider("dummy", "dummy", "dummy")

  tools <- lapply(unname(btw:::.btw_tools), function(tool_obj) {
    tool <- tool_obj$tool()

    if (is.null(tool)) {
      return(NULL)
    }

    inputSchema <- compact(ellmer:::as_json(dummy_provider, tool@arguments))
    # This field is present but shouldn't be
    inputSchema$description <- NULL

    list(
      name = tool@name,
      description = tool@description,
      inputSchema = inputSchema
    )
  })

  compact(tools)
}

compact <- function(.x) {
  Filter(length, .x)
}

check_not_interactive <- function(call = caller_env()) {
  if (interactive()) {
    cli::cli_abort(
      c(
      "This function is not intended for interactive use.",
      "i" = "See {.help {.fn mcp_proxy}} for instructions on configuring this
       function with applications"
      ),
      call = call
    )
  }
}
