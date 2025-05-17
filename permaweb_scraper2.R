#!/usr/bin/env Rscript 
# ──────────────────────────────────────────────────────────────────────────────
#  Scrape Permaweb-Journal and upsert into Supabase Postgres   (table: permaweb)
# ──────────────────────────────────────────────────────────────────────────────
suppressPackageStartupMessages({
  library(rvest)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(DBI)
  library(RPostgres)
})

# ── 1.  scrape helpers ────────────────────────────────────────────────────────
scrape_front <- function() {
  link  <- "https://permaweb-journal.arweave.net/"
  page  <- read_html(link)
  
  tibble(
    title   = html_text(html_nodes(page, ".article-text .alias")),
    date    = html_text(html_nodes(page, "em"))      |> str_trim() |> mdy(),
    summary = html_text(html_nodes(page, "p + p")),
    url     = html_attr(html_nodes(page, ".article-text .alias"), "href") |>
      (\(x) str_c("https://permaweb-journal.arweave.net", x))()
  )
}

scrape_article_body <- function(url) {
  read_html(url) |> html_node("article") |> html_text2() |> str_squish()
}

# ── 2.  scrape front page + bodies ────────────────────────────────────────────
front <- scrape_front()
front$body <- vapply(front$url, scrape_article_body, character(1))
front <- front |>
  mutate(art_id = str_extract(url, "[^/]+$")) |>
  relocate(art_id)

# ── 3.  connect to Supabase Postgres ──────────────────────────────────────────
# Use the connection‑pool host in Supabase (the one you originally tested)
pg_par <- list(
  host     = trimws(Sys.getenv("SUPABASE_HOST",
                               "aws-0-us-east-2.pooler.supabase.com")),
  port     = as.integer(Sys.getenv("SUPABASE_PORT", "5432")),
  dbname   = trimws(Sys.getenv("SUPABASE_DB", "postgres")),
  user     = trimws(Sys.getenv("SUPABASE_USER",
                               "postgres.zdizrqyeuyqdlmvgadkm")),
  password = trimws(Sys.getenv("SUPABASE_PWD"))
)


con <- dbConnect(
  RPostgres::Postgres(),
  host     = pg_par$host,
  port     = pg_par$port,
  dbname   = pg_par$dbname,
  user     = pg_par$user,
  password = pg_par$password,
  sslmode  = "require"
)

# ── 4.  ensure target table exists ────────────────────────────────────────────
dbExecute(con, "
  CREATE TABLE IF NOT EXISTS permaweb (
    art_id  text PRIMARY KEY,
    title   text,
    date    date,
    summary text,
    url     text,
    body    text
  );
")

# ── 5.  bulk-upsert -----------------------------------------------------------
dbWriteTable(con, "tmp_permaweb", front, temporary = TRUE, overwrite = TRUE)

dbExecute(con, "
  INSERT INTO permaweb AS p (art_id, title, date, summary, url, body)
  SELECT art_id, title, date, summary, url, body
  FROM tmp_permaweb
  ON CONFLICT (art_id) DO UPDATE
     SET title   = EXCLUDED.title,
         date    = EXCLUDED.date,
         summary = EXCLUDED.summary,
         url     = EXCLUDED.url,
         body    = EXCLUDED.body;
")

# ── 6.  tidy up & close -------------------------------------------------------
dbExecute(con, 'DROP TABLE IF EXISTS tmp_permaweb;')
dbDisconnect(con)
message("✅  Scrape finished and upserted into Supabase.")

# ── 7.  (optional) quick sanity checks when run interactively -----------------
if (interactive()) {
  con_chk <- dbConnect(
    RPostgres::Postgres(),
    host     = pg_par$host,
    port     = pg_par$port,
    dbname   = pg_par$dbname,
    user     = pg_par$user,
    password = pg_par$password,
    sslmode  = "require"
  )
  
  print(dbGetQuery(con_chk, "SELECT COUNT(*) AS n_articles FROM permaweb;"))
  print(dbGetQuery(con_chk, "
      SELECT art_id, title, date
      FROM permaweb
      ORDER BY date DESC
      LIMIT 5;
    "))
  dbDisconnect(con_chk)
}
