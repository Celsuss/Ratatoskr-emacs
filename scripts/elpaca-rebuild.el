;;; elpaca-rebuild.el --- Rebuild every queued package with the running Emacs -*- lexical-binding: t; -*-

;; Run *after* init has loaded, from a checkout root:
;;
;;   emacs --init-directory . --batch -l early-init.el -l init.el -l scripts/elpaca-rebuild.el
;;
;; `just rebuild-packages' wraps this, and first deletes the stale artifacts.
;; Every `.elc' under `elpaca/builds' (and every `.eln' derived from one) is only
;; valid for the Emacs that byte-compiled it: macros such as `compat-call' resolve
;; at compile time, so a package built under Emacs 30 hard-calls shims that compat
;; deliberately stops defining on 31 (FAIL-0015, L-036).  Nothing here fetches or
;; re-clones -- `elpaca-rebuild' uses the `:rebuild' build steps, which are the
;; default steps minus `elpaca-source', so the sources on disk are what gets
;; compiled and no upstream drift rides along.
;;
;; This is the same thing `elpaca-ui-execute-marks' does with every row marked for
;; rebuild, done headless so it can be scripted and verified: `elpaca-rebuild'
;; with a nil INTERACTIVE argument only re-queues, one `elpaca-process-queues'
;; then drives every queue in order (dependencies before dependents, which is what
;; makes the fresh builds read fresh dependencies), and the loop below blocks
;; until nothing is left in flight.  `sit-for' is what `elpaca-wait' itself uses in
;; batch mode; it pumps subprocess output and timers.
;;
;; Exit status is 0 when every package finished and 1 when any failed or the
;; timeout expired, with the failures named, so a wrapper can gate on it.

(require 'cl-lib)

;; Owned by elpaca, which init.el has already bootstrapped by the time this file
;; loads; declared so a standalone `just check' does not warn.
(declare-function elpaca--queued "elpaca")
(declare-function elpaca--status "elpaca")
(declare-function elpaca-rebuild "elpaca")
(declare-function elpaca-process-queues "elpaca")
(declare-function elpaca<-log "elpaca")

(defvar rata-elpaca-rebuild-timeout (* 30 60)
  "Seconds to wait for the rebuild before giving up.
Set the environment variable RATA_ELPACA_REBUILD_TIMEOUT to override.")

(defvar rata-elpaca-rebuild-dry-run (getenv "RATA_ELPACA_REBUILD_DRY_RUN")
  "When non-nil, list what would be rebuilt and queue nothing.
Exists so the driver and the wait loop can be exercised without touching a
single artifact.")

(let* ((timeout (or (ignore-errors
                      (string-to-number (getenv "RATA_ELPACA_REBUILD_TIMEOUT")))
                    rata-elpaca-rebuild-timeout))
       (ids (delete-dups (mapcar #'car (elpaca--queued))))
       (start (current-time)))
  (message "elpaca-rebuild: %s %d packages with Emacs %s in %s"
           (if rata-elpaca-rebuild-dry-run "would rebuild" "rebuilding")
           (length ids) emacs-version user-emacs-directory)
  (unless rata-elpaca-rebuild-dry-run
    (dolist (id ids) (elpaca-rebuild id))
    (elpaca-process-queues))
  (cl-flet ((in-flight ()
              (cl-remove-if (lambda (pair)
                              (memq (elpaca--status (cdr pair)) '(finished failed)))
                            (elpaca--queued))))
    (let ((last-report 0))
      (while (and (in-flight)
                  (< (float-time (time-since start)) timeout))
        (let ((elapsed (floor (float-time (time-since start)))))
          ;; A progress line every 30 s: a 200-package rebuild is minutes of
          ;; silence otherwise, and silence is indistinguishable from a hang.
          (when (>= (- elapsed last-report) 30)
            (setq last-report elapsed)
            (message "elpaca-rebuild: %ds, %d in flight"
                     elapsed (length (in-flight)))))
        (sit-for 0.5)))
    (let ((failed (cl-remove-if-not
                   (lambda (pair) (eq (elpaca--status (cdr pair)) 'failed))
                   (elpaca--queued)))
          (stuck (in-flight)))
      (dolist (pair failed)
        (message "elpaca-rebuild: FAILED %s -- %s"
                 (car pair) (nth 2 (car (elpaca<-log (cdr pair))))))
      (dolist (pair stuck)
        (message "elpaca-rebuild: TIMED OUT %s (status %s)"
                 (car pair) (elpaca--status (cdr pair))))
      (message "elpaca-rebuild: %d finished, %d failed, %d unfinished in %.0fs"
               (- (length ids) (length failed) (length stuck))
               (length failed) (length stuck)
               (float-time (time-since start)))
      (kill-emacs (if (or failed stuck) 1 0)))))

;;; elpaca-rebuild.el ends here
