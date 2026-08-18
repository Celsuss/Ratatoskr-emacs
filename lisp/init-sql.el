;;; -*- lexical-binding: t; -*-
;;; init-sql.el --- SQL client (ejc-sql + Snowflake over JDBC)

;; --- Snowflake connection parameters ---
;; Mirrors ~/.dbt/profiles.yml (tele2_nba_dbt, target dev).  No secret
;; lives here: authenticator=externalbrowser does SSO in the browser.
(defvar rata-sql-snowflake-account "tele2.eu-west-1"
  "Snowflake account identifier (the host part of the JDBC URI).")

(defvar rata-sql-snowflake-user "JENS.LORDEN@TELE2.COM")

(defvar rata-sql-snowflake-role "USER__JENS_DOT_LORDEN_AT_TELE2_DOT_COM")

(defvar rata-sql-snowflake-warehouse "AIHUB_B2C_LIGHT_WH")

(defvar rata-sql-snowflake-database "SANDBOX")

(defvar rata-sql-snowflake-schema "JENS_DOT_LORDEN_AT_TELE2_DOT_COM")

(defvar rata-sql-snowflake-jdbc-version "3.28.0"
  "Maven version of net.snowflake/snowflake-jdbc.
Resolved into ~/.m2 on first connect.  Pinned to 3.x on purpose: 4.x
renamed the driver class to `net.snowflake.client.api.driver.SnowflakeDriver'.")

(defvar rata-sql-connection-name "snowflake"
  "Name this connection is registered under for `ejc-connect'.")

(defvar rata-sql-scratch-file
  (expand-file-name "var/sql/snowflake.sql" user-emacs-directory)
  "Persistent scratch file for ad-hoc Snowflake queries.")

(defun rata-sql-snowflake-uri ()
  "Build the Snowflake JDBC connection URI."
  (format (concat "jdbc:snowflake://%s.snowflakecomputing.com/"
                  "?authenticator=externalbrowser"
                  "&user=%s&role=%s&warehouse=%s&db=%s&schema=%s")
          rata-sql-snowflake-account
          (url-hexify-string rata-sql-snowflake-user)
          (url-hexify-string rata-sql-snowflake-role)
          (url-hexify-string rata-sql-snowflake-warehouse)
          (url-hexify-string rata-sql-snowflake-database)
          (url-hexify-string rata-sql-snowflake-schema)))

(defun rata-sql-snowflake-scratch ()
  "Open the persistent Snowflake scratch file and connect it.
First connect boots a Leiningen nREPL, downloads the JDBC driver and
opens a browser tab for SSO, so expect it to take a while."
  (interactive)
  (make-directory (file-name-directory rata-sql-scratch-file) t)
  (find-file rata-sql-scratch-file)
  (unless (bound-and-true-p ejc-db)
    (ejc-connect rata-sql-connection-name)))

(defun rata-sql-tune-output ()
  "Limit rows and column width so wide Snowflake results stay readable."
  (ejc-set-max-rows 500)
  (ejc-set-fetch-size 200)
  (ejc-set-column-width-limit 40)
  (ejc-set-use-unicode t))

;; --- ejc-sql (JDBC client driven from a Clojure nREPL) ---
(use-package ejc-sql
  :after general
  :commands (ejc-sql-mode ejc-connect ejc-connect-interactive
             ejc-eval-user-sql-at-point ejc-eval-user-sql-region
             ejc-describe-table ejc-describe-entity
             ejc-show-last-result ejc-show-prev-result
             ejc-next-sql ejc-previous-sql)
  :custom
  (ejc-result-table-impl 'orgtbl-mode)  ; navigable org table
  (ejc-ring-length 10)
  (ejc-use-flx nil)                     ; orderless already does the matching
  :config
  ;; clomacs' httpd defaults to 8080, which is a busy port on dev machines.
  (setq clomacs-httpd-default-port 8090)

  (ejc-create-connection
   rata-sql-connection-name
   :dependencies (vector (vector 'net.snowflake/snowflake-jdbc
                                 rata-sql-snowflake-jdbc-version))
   :classname "net.snowflake.client.jdbc.SnowflakeDriver"
   :connection-uri (rata-sql-snowflake-uri))

  ;; Keep wide Snowflake result sets readable and cheap to render.
  (add-hook 'ejc-sql-connected-hook #'rata-sql-tune-output))

;; Bindings live at top level rather than in `:config' on purpose: ejc-sql
;; is deferred, so a `:config' block would not run until the package is
;; already loaded — leaving SPC a d s, the entry point, unbound at startup.
;; Every command below is an autoload created by `:commands' above.
(rata-leader
  :states '(normal visual)
  "ad"  '(:ignore t :which-key "database")
  "ads" '(rata-sql-snowflake-scratch :which-key "snowflake scratch")
  "adc" '(ejc-connect :which-key "connect")
  "adi" '(ejc-connect-interactive :which-key "connect interactive")
  "adr" '(ejc-show-last-result :which-key "last result")
  "adp" '(ejc-show-prev-result :which-key "prev result"))

(rata-leader
  :states '(normal visual)
  :keymaps 'sql-mode-map
  "me" '(ejc-eval-user-sql-at-point :which-key "eval at point")
  "mr" '(ejc-eval-user-sql-region :which-key "eval region")
  "md" '(ejc-describe-table :which-key "describe table")
  "mD" '(ejc-describe-entity :which-key "describe entity")
  "mR" '(ejc-show-last-result :which-key "last result")
  "mc" '(ejc-connect :which-key "connect"))

(provide 'init-sql)
