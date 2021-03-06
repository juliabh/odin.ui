mod_editor_simple_ui <- function(id) {
  ns <- shiny::NS(id)

  path_editor_css <- odin_ui_file("css/styles-editor.css")

  editor <- shiny::tagList(
    odin_css(),
    shiny::includeCSS(path_editor_css),
    mod_help_ui(ns("help"), class = "pull-right"),
    shiny::titlePanel("Editor"),

    shiny::fluidRow(
      shiny::column(6),
      shiny::column(6,
          file_input(ns("uploaded_file"),
                    "Upload model file",
                    multiple = FALSE,
                    accept = c("text/plain", ".R"),
                    button_class = "btn-blue")
      )),
    ## The ace editor setting "showPrintMargin" is the one to control
    ## the 80 char bar but I don't see how to get that through here.
    ## https://github.com/ajaxorg/ace/wiki/Configuring-Ace
    shinyAce::aceEditor(ns("editor"), mode = "r", debounce = 100),
    shiny::actionButton(ns("compile"), "Compile",
                        shiny::icon("cogs"),
                        class = "btn-blue"),
    shiny::div(
      class = "pull-right",
      shiny::actionButton(ns("reset_button"), "Reset",
                          shiny::icon("refresh"),
                          class = "btn-danger"),
      shiny::downloadButton(
        ns("download"), "Save", class = "btn-blue")),

    ## And these should go elsewhere too
    shiny::actionButton(ns("validate_button"), "Validate",
                        shiny::icon("check"), class = "btn-success"),
    shiny::checkboxInput(ns("auto_validate"), "Auto validate",
                         value = FALSE),

    ## TODO: this disables _all_ progress - ideally we'd do this
    ## just for this id, which is going to be a slightly more
    ## clever css rule.
    shiny::tags$style(".shiny-file-input-progress {display: none}"))

  status <- shiny::tagList(
    shiny::uiOutput(ns("validation_info")),
    shiny::uiOutput(ns("model_info")),
    mod_variable_order_ui(ns("order")),
    shiny::uiOutput(ns("status")))

  shiny::fluidRow(
    shiny::column(6, editor),
    shiny::column(6, status))
}


mod_editor_simple_server <- function(input, output, session, initial_code,
                                     editor_status_body) {
  ns <- session$ns
  rv <- shiny::reactiveValues()
  initial_code <- editor_validate_initial_code(initial_code)

  order <- shiny::callModule(
    mod_variable_order_server, "order", shiny::reactive(rv$model$info$vars))
  help <- shiny::callModule(
    mod_help_server, "help", odin_ui_file("md/help/editor.md"))
  modules <- submodules(order = order)

  ## Will only run once:
  shiny::observe({
    shinyAce::updateAceEditor(session, "editor", value = initial_code)
  })

  output$validation_info <- shiny::renderUI({
    editor_validation_info(rv$validation)
  })

  output$model_info <- shiny::renderUI({
    editor_model_info(rv$model)
  })

  shiny::observe({
    rv$status <- editor_status(rv$result, editor_status_body)
  })

  output$status <- shiny::renderUI({
    show_module_status_if_ok(rv$status)
  })

  shiny::observe({
    shinyAce::updateAceEditor(session, "editor",
                              border = editor_border(rv$validation))
  })

  shiny::observeEvent(
    input$uploaded_file, {
      if (!is.null(input$uploaded_file)) {
        code <- editor_read_code(input$uploaded_file$datapath)
        shinyAce::updateAceEditor(session, "editor", value = code)
        rv$validation <- common_odin_validate(code)
      }
    })

  ## Manual validation
  shiny::observeEvent(
    input$validate_button, {
      rv$validation <- common_odin_validate(input$editor)
    })

  ## Realtime validation
  shiny::observe({
    if (!is.null(rv$model)) {
      rv$model$is_current <- identical(rv$model$code, input$editor)
    }
    if (isTRUE(input$auto_validate)) {
      rv$validation <- common_odin_validate(input$editor)
    }
  })

  shiny::observeEvent(
    input$compile, {
      shiny::withProgress(
        message = "Compiling...", value = 1, {
          rv$validation <- common_odin_validate(input$editor)
          rv$model <- common_odin_compile(rv$validation)
        })
    })

  shiny::observe({
    rv$result <- editor_result(rv$model, order$result())
  })

  shiny::observeEvent(
    input$reset_button, {
      shinyAce::updateAceEditor(session, "editor", value = initial_code)
      output$include <- NULL
      rv$result <- NULL
      rv$model <- NULL
      rv$validation <- NULL
      modules$reset()
    })

  output$download <- shiny::downloadHandler(
    filename = "odin.R", # TODO: customisable?
    content = function(con) {
      writeLines(input$editor, con)
    },
    contentType = "text/plain;charset=UTF-8")

  get_state <- function() {
    list(editor = input$editor,
         validation = rv$validation$code,
         model = rv$model$code,
         modules = modules$get_state())
  }

  set_state <- function(state) {
    modules$set_state(state$modules)
    if (!is.null(state$model)) {
      model <- common_odin_compile(common_odin_validate(state$model))
      rv$model <- model
    }
    if (!is.null(state$validation)) {
      rv$validation <- common_odin_validate(state$validation)
    }
    shinyAce::updateAceEditor(session, "editor", value = state$editor)
  }

  ## shiny::outputOptions(output, "validation_info", suspendWhenHidden = FALSE)
  ## shiny::outputOptions(output, "model_info", suspendWhenHidden = FALSE)
  ## shiny::outputOptions(output, "status", suspendWhenHidden = FALSE)

  list(result = shiny::reactive(add_status(rv$result, rv$status)),
       get_state = get_state,
       set_state = set_state)
}


editor_validation_info <- function(status) {
  if (is.null(status)) {
    panel <- NULL
  } else {
    if (!is.null(status$error)) {
      body <- shiny::pre(status$error)
      result <- "error"
      class <- "danger"
    } else if (length(status$messages) > 0L) {
      body <- shiny::pre(paste(status$messages, collapse = "\n\n"))
      result <- "note"
      class <- "info"
    } else {
      body <- NULL
      result <- "success"
      class <- "success"
    }
    title <- sprintf("Validation: %s", result)
    panel <- simple_panel(class, title, body)
  }

  panel
}


editor_model_info <- function(result, id = NULL) {
  if (is.null(result)) {
    panel <- NULL
  } else {
    success <- isTRUE(result$success)
    title <- sprintf("%s, %.2f s elapsed",
                     if (success) "success" else "error", result$elapsed)
    is_current <- result$is_current
    if (!is_current) {
      title <- paste(title, "(code has changed since this was run)")
    }
    if (success) {
      class <- if (is_current) "success" else "default"
      icon_name <- "check-circle"
      ## TODO: this should be hideable, and hidden by default
      ## TODO: only do this if it's nonempty
      if (is_missing(result$output)) {
        body <- NULL
      } else {
        body <- shiny::pre(paste(result$output, collapse = "\n"))
      }
    } else {
      class <- if (is_current) "danger" else "warning"
      icon_name <- "times-circle"
      body <- shiny::pre(result$error)
    }

    title <- sprintf("Compilation: %s", title)
    panel <- panel_collapseable(class, title, body, icon_name,
                                collapsed = success, id = id)
  }

  panel
}


editor_border <- function(validation) {
  if (!is.null(validation$error)) {
    "alert"
  } else {
    "normal"
  }
}


editor_read_code <- function(path) {
  paste0(readLines(path, warn = FALSE), "\n", collapse = "")
}


editor_validate_initial_code <- function(initial_code) {
  if (is.null(initial_code)) {
    initial_code <- readLines(odin_ui_file("editor_default.R"))
  } else if (!is.character(initial_code)) {
    stop("'initial_code' must be a character vector", call. = FALSE)
  }
  if (length(initial_code) == 1L && file.exists(initial_code)) {
    initial_code <- readLines(initial_code)
  }
  initial_code <- paste(initial_code, collapse = "\n")
  if (nzchar(initial_code) && !grepl("\\n$", initial_code)) {
    initial_code <- paste0(initial_code, "\n")
  }
  initial_code
}


editor_status <- function(result, body) {
  if (is.null(result$model)) {
    class <- "danger"
    title <- "Please compile a model"
  } else {
    np <- nrow(result$info$pars)
    nv <- nrow(result$info$vars)
    title <- sprintf("Model with %d parameters and %d variables/outputs",
                     np, nv)
    hide <- !result$info$vars$include
    if (any(hide)) {
      title <- sprintf("%s (%s disabled)", title, sum(hide))
    }

    if (result$is_current) {
      class <- "success"
      body <- NULL
    } else {
      class <- "warning"
      msg <- "Warning: model is out of date, consider recompiling the model."
      if (is.null(body)) {
        body <- msg
      } else {
        body <- shiny::tagList(msg, body)
      }
    }
  }
  module_status(class, title, body)
}


editor_result <- function(model, order) {
  if (!isTRUE(model$success)) {
    return(NULL)
  }
  if (is.null(order)) {
    order <- list(show = model$info$vars$name,
                  hide = character(0), disable = character(0))
  }
  if (!isTRUE(model$success) || length(order$show) == 0) {
    return(NULL)
  }

  vars <- model$info$vars
  vars_order <- c(order$show, order$hide, order$disable)
  vars <- vars[match(vars_order, vars$name), , drop = FALSE]
  vars$show <- vars$name %in% order$show
  vars$hide <- vars$name %in% order$hide
  vars$disable <- vars$name %in% order$disable
  vars$include <- vars$show | vars$hide
  model$info$vars <- vars
  model$order <- order

  model$info$pars$range <- I(vector("list", nrow(model$info$pars)))

  model
}


editor_save <- function(model) {
  if (is.null(model)) {
    return()
  }
  model[c("code", "name", "name_short", "order")]
}


editor_restore <- function(x) {
  if (is.null(x)) {
    return()
  }
  validation <- common_odin_validate(x$code)
  model <- common_odin_compile(validation, x$name, x$name_short)
  editor_result(model, x$order)
}
