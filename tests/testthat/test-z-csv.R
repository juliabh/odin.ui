context("selenium: csv")

test_that("upload data", {
  dr <- selenium_driver()

  app <- launch_csv()

  dr$navigate(app$url)
  on.exit(dr$close())

  title <- dr$getTitle()[[1]]
  expect_equal(title, "Upload data")

  upload <- retry_until_element_exists(dr, shiny::NS("odin_csv", "filename"))
  upload <- dr$findElement("id", shiny::NS("odin_csv", "filename"))

  ## Upload data into the app:
  path <- path_remote("tests/testthat/examples/data/trig.csv")
  upload$sendKeysToElement(list(path))

  ## We should automatically set the time variable field now
  summary <- dr$findElement("id", shiny::NS("odin_csv", "summary"))
  expect_with_retry(
    expect_match,
    function() summary$getElementText()[[1]],
    "Uploaded 51 rows and 3 columns\\s+Response variables: a, b")

  ## For now, just check that there is actually a plot produced.
  ## Unfortunately I don't see the svg element here though.
  plot <- dr$findElement("id", shiny::NS("odin_csv", "data_plot"))
  expect_with_retry(
    expect_true,
    function() plot$isElementDisplayed()[[1]])

  table <- dr$findElement("id", shiny::NS("odin_csv", "data_table"))
  table_head <- table$findChildElement("xpath", ".//thead/tr")
  expect_equal(vcapply(table_head$findChildElements("tag name", "th"),
                       function(x) x$getElementText()[[1]]),
               c("t", "a", "b"))

  clear <- dr$findElement("id", shiny::NS("odin_csv", "clear"))
  clear$clickElement()

  summary <- dr$findElement("id", shiny::NS("odin_csv", "summary"))
  expect_with_retry(
    expect_equal,
    function() summary$getElementText()[[1]],
    "")

  expect_false(plot$isElementDisplayed()[[1]])
  expect_equal(table$findChildElements("xpath", "div"), list())
})