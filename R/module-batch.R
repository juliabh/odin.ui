mod_batch_ui <- function(id) {
  ns <- shiny::NS(id)
  shiny::tagList(
    shiny::titlePanel("Sensitivity"),
    shiny::sidebarLayout(
      ## NOTE: almost the same as the visualiser
      shiny::div(
        class = "col-sm-4 col-lg-3",
        shiny::tags$form(
          class = "form-horizontal",
          shiny::uiOutput(ns("status_data")),
          shiny::uiOutput(ns("status_model")),
          shiny::uiOutput(ns("model_parameters")),
          shiny::uiOutput(ns("focal_parameter")),
          ## https://github.com/rstudio/shiny/issues/1675#issuecomment-298398997
          shiny::uiOutput(ns("import_button"), inline = TRUE),
          shiny::actionButton(ns("reset_button"), "Reset",
                              shiny::icon("refresh"),
                              class = "btn-grey pull-right ml-2"),
          shiny::actionButton(ns("go_button"), "Run model",
                              shiny::icon("play"),
                              class = "btn-blue pull-right"))),
      shiny::mainPanel(
        shiny::div(class = "plotly-graph-wrapper",
                   plotly::plotlyOutput(ns("odin_output"))),
        shiny::uiOutput(ns("graph_control")))))
}


mod_batch_server <- function(input, output, session, model, data, configure,
                             import = NULL) {
  rv <- shiny::reactiveValues(pars = NULL)

  output$status_data <- shiny::renderUI({
    show_module_status_if_not_ok(data()$status)
  })

  output$status_model <- shiny::renderUI({
    show_module_status_if_not_ok(model()$status)
  })

  output$status_focal <- shiny::renderText({
    batch_status_focal(rv$focal)
  })

  shiny::observe({
    message("updating batch configuration")
    rv$configuration <- batch_configuration(model(), data(), configure()$link)
  })

  output$model_parameters <- shiny::renderUI({
    batch_control_parameters(rv$configuration, session$ns)
  })

  output$focal_parameter <- shiny::renderUI({
    batch_control_focal(rv$configuration, session$ns)
  })

  output$graph_control <- shiny::renderUI({
    common_control_graph(rv$configuration, session$ns,
                         "Display series in plot", "id_include")
  })

  shiny::observe({
    pars <- rv$configuration$pars
    user <- get_inputs(input, pars$id_value, pars$name)
    rv$focal <- batch_focal(
      input$focal_name, input$focal_pct, input$focal_n, user)
  })

  output$download_button <- shiny::downloadHandler(
    filename = function() {
      common_download_filename(input$download_filename, input$download_type,
                               "batch")
    },
    content = function(filename) {
      common_download_data(filename, rv$result$simulation, input$download_type)
    })

  shiny::observeEvent(
    input$go_button, {
      pars <- rv$configuration$pars
      user <- get_inputs(input, pars$id_value, pars$name)
      rv$result <- batch_run(rv$configuration, rv$focal)
    })

  output$odin_output <- plotly::renderPlotly({
    if (!is.null(rv$result)) {
      vars <- rv$configuration$vars
      include <- get_inputs(input, vars$id_include, vars$name)
      batch_plot(rv$result, include, input$logscale_y)
    }
  })

  output$import_button <- shiny::renderUI({
    if (!is.null(import) && !is.null(import())) {
      shiny::actionButton(session$ns("import"), "Import",
                          shiny::icon("calculator"))
    }
  })

  shiny::observeEvent(
    input$import, {
      user <- import()
      if (!is.null(user)) {
        shiny::isolate({
          id <- rv$pars$par_id[match(names(user), rv$pars$name)]
          if (!any(is.na(id))) {
            for (i in seq_along(id)) {
              shiny::updateNumericInput(session, id[[i]], value = user[[i]])
            }
          }
        })
      }
    })
}


batch_run <- function(configuration, focal) {
  if (is.null(focal)) {
    return(NULL)
  }
  name <- focal$name
  n <- constrain(focal$n, 2, 20)
  value <- seq(focal$from, focal$to, length.out = n)
  pars <- configuration$pars
  i <- match(name, pars$name)
  value <- value[value >= pars$min[[i]] & value <= pars$max[[i]]]

  user <- focal$base
  f <- function(p) {
    user[[name]] <- p
    vis_run_model(configuration, user)
  }

  ## First, the central runs as our base set:
  central <- vis_run_model(configuration, user)

  ## Output types we'll work with:
  types <- names(central$simulation)

  ## Then the sensitivity around that
  batch <- lapply(value, f)
  g <- function(type) {
    combine_colwise(lapply(batch, function(x) x$simulation[[type]]))
  }

  ## Organise output that will download cleanly:
  simulation <- set_names(lapply(types, g), types)

  ## Update with central runs too:
  simulation$user <- cbind(
    central$simulation$user,
    simulation$user[!grepl("^name", names(simulation$user))],
    stringsAsFactors = FALSE)
  for (i in setdiff(types, "user")) {
    simulation[[i]] <- cbind(
      central$simulation[[i]],
      simulation[[i]][, -1, drop = FALSE])
  }

  ## And output for plotting
  simulation$batch <- batch
  simulation$central <- central
  configuration$focal <- list(name = name, value = value, base = user)

  list(configuration = configuration,
       simulation = simulation)
}


batch_focal <- function(name, pct, n, user) {
  if (is_missing(pct) || is_missing(name) || is_missing(n)) {
    return(NULL)
  }
  value <- user[[name]]
  if (is_missing(value)) {
    return(NULL)
  }
  dy <- abs(pct / 100 * value)
  from <- value - dy
  to <- value + dy
  list(base = user, name = name, value = value, n = n, from = from, to = to)
}


batch_plot <- function(result, include, logscale_y) {
  plot_plotly(batch_plot_series(result, include), logscale_y)
}


batch_plot_series <- function(result, include) {
  cfg <- result$configuration
  cols <- cfg$cols
  include <- names(include)[list_to_logical(include)]

  ## TODO: remove cheat:
  if (length(include == 0L)) {
    include <- intersect(c("weekly_onset", "weekly_death_h"),
                         result$configuration$vars$name)
  }

  if (length(include) == 0L) {
    return(NULL)
  }

  xy <- result$simulation$central$simulation$smooth
  series_central <- plot_plotly_series_bulk(
    xy[, 1], xy[, include, drop = FALSE], cols$model, FALSE, FALSE,
    legendgroup = set_names(include, include))

  plot_plotly(series_central)

  f <- function(nm) {
    t <- result$simulation$smooth[, 1]
    y <- lapply(result$simulation$batch, function(x) x$simulation$smooth[, nm])
    m <- matrix(unlist(y), length(y[[1]]), length(y))
    colnames(m) <- sprintf("%s (%s = %s)", nm, cfg$focal$name, cfg$focal$value)
    col <- set_names(rep(cols$model[[nm]], ncol(m)), colnames(m))
    plot_plotly_series_bulk(t, m, col, FALSE, FALSE,
                            legendgroup = nm, showlegend = FALSE, width = 1)
  }
  series_batch <- unlist(lapply(include, f), FALSE, FALSE)

  data <- cfg$data$data
  data_time <- data[[cfg$data$name_time]]
  series_data <- plot_plotly_series_bulk(
    data_time, data[names(cols$data)], cols$data, TRUE, FALSE)

  c(series_batch, series_central, series_data)
}


plot_batch <- function(output, vars, cols, logscale_y) {
  p <- plotly::plot_ly()
  p <- plotly::config(p, collaborate = FALSE, displaylogo = FALSE)
  for (i in vars) {
    for (j in seq_along(output$z)) {
      nm <- sprintf("%s (%s)", i, output$p[[j]])
      p <- plotly::add_lines(p, x = output$t, y = output$z[[j]][, i],
                             name = nm, legendgroup = i, showlegend = FALSE,
                             hoverlabel = list(namelength = -1),
                             line = list(color = cols[[i]], width = 1))
    }
    p <- plotly::add_lines(p, x = output$t, y = output$y[, i],
                           name = i, legendgroup = i,
                           line = list(color = cols[[i]]))
  }

  if (logscale_y) {
    p <- plotly::layout(p, yaxis = list(type = "log"))
  }

  p
}


mod_batch_graph_control <- function(outputs, cols, ns) {
  graph_settings <- mod_batch_graph_settings(outputs, cols, ns)
  shiny::tagList(
    shiny::div(
      class = "pull-right",
      graph_settings))
}


mod_batch_graph_settings <- function(outputs, cols, ns) {
  if (is.null(outputs)) {
    return(NULL)
  }
  title <- "Graph settings"
  id <- ns(sprintf("hide_%s", gsub(" ", "_", tolower(title))))
  labels <- Map(function(lab, col)
    shiny::span(lab, style = paste0("color:", col)),
    outputs$name, cols[outputs$name])

  tags <- shiny::div(class = "form-group",
                     raw_checkbox_input(ns("logscale_y"), "Log scale y axis"),
                     shiny::tags$label("Include in plot"),
                     Map(raw_checkbox_input, ns(outputs$include),
                         labels, value = FALSE))

  head <- shiny::a(style = "text-align: right; display: block;",
                   "data-toggle" = "collapse",
                   class = "text-muted",
                   href = paste0("#", id),
                   title, shiny::icon("gear", lib = "font-awesome"))

  body <- shiny::div(id = id,
                    class = "collapse box",
                    style = "width: 300px;",
                    list(tags))

  shiny::div(class = "pull-right mt-3", head, body)
}


batch_configuration <- function(model, data, link) {
  if (!isTRUE(model$result$success) || !isTRUE(data$configured)) {
    return(NULL)
  }

  pars <- model$result$info$pars
  pars$value <- vnapply(pars$default_value, function(x) x %||% NA_real_)
  pars$id_value <- sprintf("par_value_%s", pars$name)

  vars <- model$result$info$vars
  vars$id_include <- sprintf("var_include_%s", vars$name)

  cols <- odin_colours(vars$name, data$name_vars, link)

  list(data = data, model = model, link = link,
       pars = pars, vars = vars, cols = cols)
}


## NOTE: This is the same as vis_control_paramters
batch_control_parameters <- function(configuration, ns) {
  if (is.null(configuration)) {
    return(NULL)
  }
  pars <- configuration$pars
  mod_model_control_section(
    "Model parameters",
    Map(simple_numeric_input, pars$name, ns(pars$id_value), pars$value),
    ns = ns)
}


batch_control_focal <- function(configuration, ns) {
  if (is.null(configuration)) {
    return(NULL)
  }
  mod_model_control_section(
    "Vary parameter",
    horizontal_form_group(
      "Parameter to vary",
      raw_select_input(
        ns("focal_name"), configuration$pars$name, selected = NA)),
    simple_numeric_input("Variation (%)", ns("focal_pct"), 10),
    simple_numeric_input("Number of runs", ns("focal_n"), 10),
    shiny::textOutput(ns("status_focal")),
    ns = ns)
}


batch_status_focal <- function(focal) {
  if (!is.null(focal)) {
    sprintf("%s - %s - %s",
            focal$from, focal$value, focal$to)
  }
}