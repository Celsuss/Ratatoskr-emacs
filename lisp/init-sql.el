;;; -*- lexical-binding: t; -*-
;;; init-sql.el --- SQL client (ejc-sql + Snowflake over JDBC)

;; --- Snowflake connection parameters ---
;; Set these in `local.el', which is gitignored; `local.el.example' is the
;; template.  They are nil here on purpose: they mirror ~/.dbt/profiles.yml and
;; name a real account, user, role and schema, and this repository has a public
;; remote.  No password is involved either way — authenticator=externalbrowser
;; does SSO in the browser.  See D-012 in .are/memory/DECISIONS.md.
(defvar rata-sql-snowflake-account nil
  "Snowflake account identifier (the host part of the JDBC URI).")

(defvar rata-sql-snowflake-user nil
  "Snowflake user, usually a work email address.")

(defvar rata-sql-snowflake-role nil
  "Snowflake role to assume on connect.")

(defvar rata-sql-snowflake-warehouse nil
  "Snowflake warehouse to run queries on.")

(defvar rata-sql-snowflake-database nil
  "Snowflake database to connect to.")

(defvar rata-sql-snowflake-schema nil
  "Snowflake schema to connect to.")

(defvar rata-sql-snowflake-jdbc-version "3.28.0"
  "Maven version of net.snowflake/snowflake-jdbc.
Resolved into ~/.m2 on first connect.  Pinned to 3.x on purpose: 4.x
renamed the driver class to `net.snowflake.client.api.driver.SnowflakeDriver'.")

(defvar rata-sql-connection-name "snowflake"
  "Name this connection is registered under for `ejc-connect'.")

(defvar rata-sql-scratch-file
  (expand-file-name "var/sql/snowflake.sql" user-emacs-directory)
  "Persistent scratch file for ad-hoc Snowflake queries.")

(defvar rata-sql-snowflake-parameters
  '(rata-sql-snowflake-account rata-sql-snowflake-user rata-sql-snowflake-role
    rata-sql-snowflake-warehouse rata-sql-snowflake-database
    rata-sql-snowflake-schema)
  "The connection parameters that must be set before connecting.")

(defun rata-sql-snowflake-uri ()
  "Build the Snowflake JDBC connection URI.
Signals if any parameter is unset: a URI built from nil would be
accepted here and fail much later, inside a Leiningen nREPL boot."
  (let ((missing (seq-remove #'symbol-value rata-sql-snowflake-parameters)))
    (when missing
      (user-error "Snowflake is not configured: %s unset.  See local.el.example"
                  (mapconcat #'symbol-name missing ", "))))
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
