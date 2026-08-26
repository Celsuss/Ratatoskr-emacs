;;; -*- lexical-binding: t; -*-
;;; tests/work-agenda-render.el --- Render the "w" work agenda and assert on it
;;
;; Run with:
;;   emacs --init-directory . --batch -l ert -l tests/work-agenda-render.el
;;
;; Or via justfile:
;;   just test-work-agenda
;;
;; Why a separate entry point from tests/run-tests.el:
;;
;;   * `org-super-agenda' is declared `:after org', so in a batch Emacs elpaca
;;     never activates it — it is not even on `load-path', and
;;     `org-agenda-custom-commands' still holds org's default.  This file puts the
;;     package and its declared dependencies on `load-path' by hand, switches the
;;     mode on, and lifts the custom commands out of the module source.  That is
;;     too much scaffolding to hide inside the main suite.
;;   * It needs org fixtures on disk.  `are-verify' lists operator-data paths as
;;     NOT TESTED "no fixture"; this supplies one, for the agenda only, in
;;     `temporary-file-directory' — never anything under second-brain.
;;
;; What it proves: that the "w" command as written in lisp/init-org.el renders a
;; dated calendar of `rata-org-work-agenda-span' days, that the +work preset keeps
;; foreign tasks out of it, and that the backlog below holds exactly the items the
;; calendar cannot show.  It does not prove anything about the operator's real
;; org-roam tree.

(require 'ert)
(require 'cl-lib)

;; --- Bootstrap: load the full config ------------------------------------------
;; `--batch' implies `-q', so the module under test is not loaded for us.  Same
;; two lines as tests/run-tests.el; `rata-org-work-agenda-span' and
;; `rata-org-work-agenda-horizon' come from lisp/init-org.el, and the assertions
;; below compare the rendered view against them rather than against a copy.
(unless (file-exists-p (expand-file-name "init.el" user-emacs-directory))
  (error "work-agenda-render: user-emacs-directory (%s) has no init.el — pass --init-directory ."
         user-emacs-directory))
(load (expand-file-name "early-init.el" user-emacs-directory) nil t)
(load (expand-file-name "init.el" user-emacs-directory) nil t)

;; --- Packages -----------------------------------------------------------------
;; Named explicitly rather than by globbing elpaca/builds: a glob would put ~200
;; unrelated directories on `load-path' and any breakage there would surface here
;; as a mystery.  This is org-super-agenda's Package-Requires plus org itself.
(dolist (pkg '("org" "org-super-agenda" "compat" "s" "dash" "ht" "ts"))
  (let ((dir (expand-file-name (concat "elpaca/builds/" pkg) user-emacs-directory)))
    (if (file-directory-p dir)
        (add-to-list 'load-path dir)
      (error "work-agenda-render: %s is not built; run `just run' once first" dir))))

(require 'org)
(require 'org-agenda)
(require 'org-super-agenda)

;; --- The command under test ---------------------------------------------------

(defun rata-wa--find-setq-value (form variable)
  "Return the quoted value of a (setq VARIABLE \\='(...)) form nested in FORM.
Twin of `rata-test--find-setq-value\=' in tests/run-tests.el; duplicated
rather than shared because that file runs the whole suite when loaded.
Walks car and cdr separately -- the module source contains dotted pairs."
  (cond
   ((not (consp form)) nil)
   ((and (eq (car-safe form) 'setq) (eq (nth 1 form) variable))
    (cadr (nth 2 form)))
   (t (or (rata-wa--find-setq-value (car form) variable)
          (rata-wa--find-setq-value (cdr form) variable)))))

(defun rata-wa--custom-commands ()
  "Return `org-agenda-custom-commands\=' as written in lisp/init-org.el."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/init-org.el" user-emacs-directory))
    (goto-char (point-min))
    (let (form value)
      (while (setq form (ignore-errors (read (current-buffer))))
        (unless value
          (setq value (rata-wa--find-setq-value form 'org-agenda-custom-commands))))
      value)))

(defun rata-wa--stamp (offset)
  "Return an org timestamp OFFSET days from today."
  (format-time-string "<%Y-%m-%d %a>" (org-time-from-absolute (+ (org-today) offset))))

(defun rata-wa--header (offset)
  "Return the date part of the agenda header for OFFSET days from today.
Built from `calendar-month-name-array\=', which is what org renders from --
a locale-aware month name would give \"augusti\" here and never match the
rendered buffer."
  (pcase-let ((`(,month ,day ,year)
               (calendar-gregorian-from-absolute (+ (org-today) offset))))
    (format "%d %s %d" day (aref calendar-month-name-array (1- month)) year)))

(defun rata-wa--visible-lines ()
  "Render the \"w\" agenda over fixtures and return the lines a reader would see.
The tag filter hides entries with an `invisible\=' text property rather
than deleting them, so a raw buffer dump would show the very tasks the
filter is supposed to keep out."
  (let ((work (make-temp-file "rata-work-" nil ".org"))
        (other (make-temp-file "rata-other-" nil ".org")))
    (unwind-protect
        (progn
          ;; Mirrors work_tasks.org: :work: arrives by inheritance, from the
          ;; filetags and the `* Tasks :work:' parent, never on the task itself.
          (with-temp-file work
            (insert "#+filetags: :work:hastodo:\n"
                    "* Tasks :work:\n"
                    "** TODO Dated tomorrow\n   DEADLINE: " (rata-wa--stamp 1) "\n"
                    "** TODO Overdue already\n   DEADLINE: " (rata-wa--stamp -3) "\n"
                    "** TODO Past the horizon\n   DEADLINE: " (rata-wa--stamp 30) "\n"
                    "** TODO Scheduled inside span\n   SCHEDULED: " (rata-wa--stamp 2) "\n"
                    "** TODO Undated backlog item\n"
                    "** TODO [#A] Important undated\n"))
          ;; No work filetag: this is what the +work preset must keep out.
          (with-temp-file other
            (insert "#+filetags: :hastodo:\n"
                    "* Personal :home:\n"
                    "** TODO Not a work task\n   DEADLINE: " (rata-wa--stamp 1) "\n"
                    "** TODO Personal undated\n"))
          (let ((org-agenda-files (list work other))
                (org-agenda-custom-commands (rata-wa--custom-commands))
                (org-agenda-window-setup 'current-window)
                (org-agenda-prefix-format
                 '((agenda . " %i %?-12t% s") (todo . " %i %?-12t% s")
                   (tags . " %i %?-12t% s") (search . " %i %?-12t% s")))
                lines)
            (org-super-agenda-mode)
            ;; `org-agenda' is advised to append every org-roam file tagged
            ;; :hastodo: (rata-org-agenda-files-advice), which would pull the
            ;; operator's real second-brain tree into this run -- the assertions
            ;; would then depend on today's actual work tasks.  Starve the advice
            ;; instead of removing it, so the advice itself stays under test.
            (cl-letf (((symbol-function 'rata-org-roam-agenda-files) (lambda () nil)))
              (org-agenda nil "w"))
            (with-current-buffer org-agenda-buffer-name
              (goto-char (point-min))
              (while (not (eobp))
                (unless (get-text-property (line-beginning-position) 'invisible)
                  (push (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))
                        lines))
                (forward-line 1)))
            (nreverse lines)))
      (delete-file work)
      (delete-file other))))

(defun rata-wa--index (lines regexp)
  "Return the index of the first line in LINES matching REGEXP, or nil."
  (cl-position-if (lambda (l) (string-match-p regexp l)) lines))

;; --- Tests --------------------------------------------------------------------

(ert-deftest rata-test-work-agenda-renders-date-headers ()
  "The calendar block prints one header per day of the span, starting today.
This is the whole point of the block: before it, a work deadline could
only appear in a flat \"Due Soon\" bucket with no date attached."
  (let ((lines (rata-wa--visible-lines)))
    (should (rata-wa--index lines "Work Agenda"))
    (dotimes (offset rata-org-work-agenda-span)
      (should (rata-wa--index lines (regexp-quote (rata-wa--header offset)))))
    ;; And it stops at the horizon -- the day after must not appear, or the
    ;; backlog's "Due later" boundary is in the wrong place.
    (should-not (rata-wa--index
                 lines (regexp-quote (rata-wa--header rata-org-work-agenda-span))))
    (should (equal (rata-org-work-agenda-horizon)
                   (format-time-string
                    "%Y-%m-%d"
                    (org-time-from-absolute
                     (+ (org-today) (1- rata-org-work-agenda-span))))))))

(ert-deftest rata-test-work-agenda-places-items-on-their-day ()
  "Each dated task sits under its own date, and an overdue one under today."
  (let* ((lines (rata-wa--visible-lines))
         (today (rata-wa--index lines (regexp-quote (rata-wa--header 0))))
         (tomorrow (rata-wa--index lines (regexp-quote (rata-wa--header 1))))
         (day-after (rata-wa--index lines (regexp-quote (rata-wa--header 2))))
         (day-three (rata-wa--index lines (regexp-quote (rata-wa--header 3))))
         (overdue (rata-wa--index lines "Overdue already"))
         (dated (rata-wa--index lines "Dated tomorrow"))
         (scheduled (rata-wa--index lines "Scheduled inside span")))
    (should (and today tomorrow day-after day-three))
    (should (< today overdue tomorrow))
    (should (< tomorrow dated day-after))
    (should (< day-after scheduled day-three))
    ;; `org-deadline-warning-days' is 0 in the block, so tomorrow's deadline is
    ;; not also echoed under today as a prewarning.
    (should (= 1 (cl-count-if (lambda (l) (string-match-p "Dated tomorrow" l)) lines)))))

(ert-deftest rata-test-work-agenda-excludes-foreign-tasks ()
  "The +work preset keeps non-work tasks out of the whole view.
The preset lives in the command's global settings slot; per-block it is
documented as unreliable (org-agenda.el:3834), and the symptom of getting
that wrong is personal tasks showing up in a work calendar."
  (let ((lines (rata-wa--visible-lines)))
    (should-not (rata-wa--index lines "Not a work task"))
    (should-not (rata-wa--index lines "Personal undated"))
    ;; The work items from the same run are there, so this is not an empty view.
    (should (rata-wa--index lines "Undated backlog item"))))

(ert-deftest rata-test-work-agenda-backlog-holds-only-what-the-calendar-cannot ()
  "The backlog lists undated work plus deadlines beyond the horizon, nothing else."
  (let* ((lines (rata-wa--visible-lines))
         (backlog (rata-wa--index lines "Work Backlog"))
         (due-later (rata-wa--index lines "Due later"))
         (far (rata-wa--index lines "Past the horizon"))
         (important (rata-wa--index lines "Important undated"))
         (undated (rata-wa--index lines "Undated backlog item")))
    (should backlog)
    (should (< backlog due-later far))
    (should (< backlog important))
    (should (< backlog undated))
    ;; Nothing the calendar already showed is repeated down here.
    (dolist (shown '("Dated tomorrow" "Overdue already" "Scheduled inside span"))
      (let ((at (rata-wa--index lines shown)))
        (should at)
        (should (< at backlog))))
    ;; The catch-all carries its name: a group with only :name and :order selects
    ;; nothing, and the leftovers land in org-super-agenda's own "Other items".
    (should (rata-wa--index lines "Other Projects & Tasks"))
    (should-not (rata-wa--index lines "Other items"))))

(ert-run-tests-batch-and-exit)
