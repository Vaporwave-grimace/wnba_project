# tests/test_prop_correlation.R
library(testthat)
source(here::here("scripts", "prop_correlation.R"))

test_that("compute_prop_correlation_matrix returns empirical matrix", {
  mat <- compute_prop_correlation_matrix()
  expect_true(is.data.frame(mat))
  expect_true("stat_pair" %in% names(mat))
  expect_true("rho" %in% names(mat))
})

test_that("calculate_correlated_prop_prob computes joint probabilities", {
  res <- calculate_correlated_prop_prob(prob_a = 0.60, prob_b = 0.55, rho = 0.35)
  expect_true(res$correlated_prob > res$uncorrelated_prob)
  expect_equal(res$uncorrelated_prob, 0.33)
  expect_true(res$correlation_boost_pct > 0.0)
})
