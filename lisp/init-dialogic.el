;;; -*- lexical-binding: t; -*-
;;; init-dialogic.el --- Dialogic formatting for blog posts

;; Dialogic formatting embeds a simulated conversation into an otherwise
;; ordinary article: "side characters" interrupt the main text with questions,
;; counterarguments or jokes, so a dense section reads as a chat rather than a
;; lecture.  See the `blog post writing tips' node in the org-roam tree.
;;
;; Phase 1 — authoring and export only.  No LLM is involved anywhere in this
;; file: `rata-dialogic-insert-block' writes the skeleton, the export filter
;; turns it into styled HTML, and `rata-dialogic-audit' reports density.  A
;; later phase may add generated turns on top; nothing here depends on it, so
;; the workflow keeps working with Ollama down.
;;
;; The org source shape is a special block holding a description list:
;;
;;   #+begin_dialogue
;;   - Skeptic :: But what happens when the logic changes?
;;   - Me :: Then you use ~--full-refresh~, which I get to below.
;;   #+end_dialogue
;;
;; NB on export (this is why `rata-dialogic--filter-parse-tree' exists rather
;; than leaning on ox-hugo's default special-block handling): ox-hugo already
;; wraps an unknown special block in `<div class="dialogue">' with blank lines
;; around the contents, which is exactly right.  What is not right is the
;; description list inside it — `org-blackfriday-item' exports a non-nested
;; description list in Blackfriday syntax ("Term\n: description"), and this
;; site renders with goldmark, which has no definition-list extension enabled.
;; The turns would render as literal "Skeptic : ..." text.  So the filter
;; rewrites each list item into a paragraph that starts with a raw <span>
;; carrying the speaker.  It rewrites the *parse tree* rather than the exported
;; string so that inline org markup inside a turn (~code~, links, emphasis)
;; still goes through the normal transcoders.

(eval-when-compile
  (require 'org)
  (require 'org-element)
  (require 'ox))

(defgroup rata-dialogic nil
  "Dialogic formatting for blog posts."
  :group 'rata
  :prefix "rata-dialogic-")

(defcustom rata-dialogic-block-name "dialogue"
  "Name of the org special block that holds one dialogic interruption.
Also the CSS class of the exported wrapper, since ox-hugo derives the
class from the block type."
  :type 'string
  :group 'rata-dialogic)

(defcustom rata-dialogic-self-name "Me"
  "Speaker name used for the author's own turns."
  :type 'string
  :group 'rata-dialogic)

(defcustom rata-dialogic-characters
  '(("Skeptic"  . "Experienced engineer, distrusts hype; asks about failure modes and cost.")
    ("Newcomer" . "Knows SQL, has never used the tool; asks the obvious question the author skipped."))
  "The cast of side characters, as an alist of (NAME . PERSONA).

Hand-authored on purpose: the characters are a voice decision, not
something to be generated.  PERSONA is unused in phase 1 — it documents
the character for you now and is the prompt material a later generation
phase would send to the model."
  :type '(alist :key-type string :value-type string)
  :group 'rata-dialogic)

(defcustom rata-dialogic-who-class "dialogue-who"
  "CSS class applied to the speaker name in exported output."
  :type 'string
  :group 'rata-dialogic)

(defcustom rata-dialogic-max-blocks-per-heading 1
  "Interruptions allowed under one heading before `rata-dialogic-audit' complains.
Dialogic formatting fails by overuse: characters chattering every other
paragraph read as a gimmick."
  :type 'integer
  :group 'rata-dialogic)

(defcustom rata-dialogic-words-per-block 400
  "Words under one heading that suggest an interruption would help.
`rata-dialogic-audit' flags a heading longer than this with no dialogue
block as an opportunity, not an error."
  :type 'integer
  :group 'rata-dialogic)

;;; ============================================================
;;; Source-level helpers (pure where they can be)
;;; ============================================================

(defconst rata-dialogic--turn-regexp
  "^[ \t]*-[ \t]+\\(.+?\\)[ \t]+::[ \t]*\\(.*\\)$"
  "Match one turn line inside a dialogue block.
Group 1 is the speaker, group 2 the (possibly empty) text.")

(defun rata-dialogic-parse-turns (text)
  "Parse TEXT, the body of a dialogue block, into a list of (SPEAKER . TEXT).
Non-matching lines are ignored, so a stray comment does not break the
whole block.  Continuation lines are appended to the turn above them,
mirroring how org itself reads a wrapped description-list item."
  (let (turns)
    (dolist (line (split-string (or text "") "\n"))
      (cond
       ((string-match rata-dialogic--turn-regexp line)
        (push (cons (string-trim (match-string 1 line))
                    (string-trim (match-string 2 line)))
              turns))
       ((and turns (string-match-p "[^ \t]" line))
        (setcdr (car turns)
                (string-trim (concat (cdr (car turns)) " " (string-trim line)))))))
    (nreverse turns)))

(defun rata-dialogic--speakers ()
  "Completion table for a speaker: the author first, then the cast."
  (cons rata-dialogic-self-name (mapcar #'car rata-dialogic-characters)))

(defun rata-dialogic--read-speaker (prompt)
  "Read a speaker name with PROMPT, completing over the cast."
  (completing-read prompt (rata-dialogic--speakers) nil nil nil nil
                   (car (rata-dialogic--speakers))))

(defun rata-dialogic--begin-line ()
  (format "#+begin_%s" rata-dialogic-block-name))

(defun rata-dialogic--end-line ()
  (format "#+end_%s" rata-dialogic-block-name))

(defun rata-dialogic--block-regexp ()
  "Regexp matching a whole dialogue block.  Group 1 is the body.

The `\\(?:^...\\)' around the closing delimiter is not decoration: in an
Emacs regexp `^' is an anchor only at the very start of the pattern or
directly after `\\(', `\\(?:' or `\\|'.  Written as a bare `^' in the
middle of a pattern it is a *literal caret*, so the obvious spelling of
this regexp matches nothing at all — silently, which is how the audit
first reported zero dialogue blocks in a buffer holding two."
  (concat "^[ \t]*" (regexp-quote (rata-dialogic--begin-line)) "[ \t]*\n"
          "\\(\\(?:.\\|\n\\)*?\\)"
          "\\(?:^[ \t]*\\)" (regexp-quote (rata-dialogic--end-line)) ".*$"))

(defun rata-dialogic--block-bounds ()
  "Return (BEGIN . END) of the dialogue block around point, or nil.
BEGIN is the start of the #+begin_ line, END the end of the #+end_ line.
Works from anywhere inside the block, including inside the list."
  (save-excursion
    (let ((origin (point))
          (case-fold-search t))
      (beginning-of-line)
      (when (or (looking-at-p (concat "[ \t]*" (regexp-quote (rata-dialogic--begin-line))))
                (re-search-backward (concat "^[ \t]*" (regexp-quote (rata-dialogic--begin-line)))
                                    nil t))
        (let ((begin (line-beginning-position)))
          (when (re-search-forward (concat "^[ \t]*" (regexp-quote (rata-dialogic--end-line)))
                                   nil t)
            (let ((end (line-end-position)))
              (when (<= origin end)
                (cons begin end)))))))))

;;;###autoload
(defun rata-dialogic-insert-block (who)
  "Insert a dialogue block interrupted by WHO, followed by the author's reply.
Point is left where the interruption text goes."
  (interactive (list (rata-dialogic--read-speaker "Interrupted by: ")))
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org buffer"))
  ;; Open a fresh paragraph: a block glued to the prose above it exports as
  ;; part of that paragraph.
  (unless (bolp) (end-of-line) (insert "\n"))
  (unless (looking-back "\n[ \t]*\n" (max (point-min) (- (point) 3)))
    (insert "\n"))
  (let ((start (point)))
    (insert (rata-dialogic--begin-line) "\n"
            "- " who " :: \n"
            "- " rata-dialogic-self-name " :: \n"
            (rata-dialogic--end-line) "\n")
    (goto-char start)
    (forward-line 1)
    (end-of-line)))

;;;###autoload
(defun rata-dialogic-insert-turn (who)
  "Append a turn spoken by WHO to the dialogue block at point."
  (interactive (list (rata-dialogic--read-speaker "Speaker: ")))
  (let ((bounds (rata-dialogic--block-bounds)))
    (unless bounds
      (user-error "Point is not inside a %s block" rata-dialogic-block-name))
    (goto-char (cdr bounds))
    (beginning-of-line)
    (insert "- " who " :: \n")
    (forward-line -1)
    (end-of-line)))

;;; ============================================================
;;; Folding — read your own prose without the interruptions
;;; ============================================================

(defvar-local rata-dialogic--overlays nil
  "Overlays hiding dialogue blocks in this buffer.")

(defun rata-dialogic--summarise (text)
  "One-line stand-in for a folded block whose body is TEXT."
  (let ((speakers (delete-dups (mapcar #'car (rata-dialogic-parse-turns text)))))
    (format " ⟨%s: %s⟩ "
            rata-dialogic-block-name
            (if speakers (mapconcat #'identity speakers ", ") "empty"))))

;;;###autoload
(defun rata-dialogic-toggle-fold ()
  "Fold or unfold every dialogue block in the buffer.
Folded, the article reads as the monologue it started as — which is the
only way to tell whether the prose still stands on its own."
  (interactive)
  (if rata-dialogic--overlays
      (progn
        (mapc #'delete-overlay rata-dialogic--overlays)
        (setq rata-dialogic--overlays nil)
        (message "Dialogue blocks shown"))
    (let ((case-fold-search t)
          (count 0))
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward
                (concat "^[ \t]*" (regexp-quote (rata-dialogic--begin-line)))
                nil t)
          (let ((begin (line-beginning-position))
                (body-start (1+ (line-end-position))))
            (when (re-search-forward
                   (concat "^[ \t]*" (regexp-quote (rata-dialogic--end-line)))
                   nil t)
              (let* ((end (line-end-position))
                     (body (buffer-substring-no-properties
                            (min body-start (point-max)) (line-beginning-position)))
                     (ov (make-overlay begin end)))
                (overlay-put ov 'display (rata-dialogic--summarise body))
                (overlay-put ov 'rata-dialogic t)
                (overlay-put ov 'evaporate t)
                (push ov rata-dialogic--overlays)
                (setq count (1+ count)))))))
      (message "%d dialogue block%s folded" count (if (= count 1) "" "s")))))

;;; ============================================================
;;; Audit — density and cast consistency
;;; ============================================================

(defconst rata-dialogic--any-block-regexp
  "^[ \t]*#\\+begin_\\([a-z_]+\\).*\n\\(?:.\\|\n\\)*?\\(?:^[ \t]*\\)#\\+end_\\1.*$"
  "Match any org block, delimiter lines included.
Used to keep code, examples and dialogue out of the prose word count: a
section that is mostly a YAML sample is not a section that needs an
interruption.  See `rata-dialogic--block-regexp' on the `\\(?:^' spelling.")

(defun rata-dialogic--count-words (beg end)
  "Count prose words between BEG and END.
Blocks (src, example, dialogue) and keyword/drawer lines do not count."
  (let ((text (buffer-substring-no-properties beg end)))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((case-fold-search t))
        (while (re-search-forward rata-dialogic--any-block-regexp nil t)
          (replace-match ""))
        (goto-char (point-min))
        (while (re-search-forward "^[ \t]*\\(#\\+\\|:[A-Za-z_]+:\\).*$" nil t)
          (replace-match "")))
      (count-words (point-min) (point-max)))))

(defun rata-dialogic-audit-data ()
  "Return one plist per heading in the current org buffer.

Each plist has :heading :level :words :blocks :turns :speakers, counted
over the heading's *own* content only — not its descendants — because the
unit a reader experiences is the subsection, and that is also the unit
`rata-dialogic-max-blocks-per-heading' talks about."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org buffer"))
  (let (rows)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward org-outline-regexp-bol nil t)
        (let* ((heading (or (org-get-heading t t t t) ""))
               (level (org-outline-level))
               (beg (progn (forward-line 1) (point)))
               (end (save-excursion
                      (if (re-search-forward org-outline-regexp-bol nil t)
                          (line-beginning-position)
                        (point-max))))
               (body (buffer-substring-no-properties beg end))
               (turns nil)
               (blocks 0))
          (with-temp-buffer
            (insert body)
            (goto-char (point-min))
            (let ((case-fold-search t))
              (while (re-search-forward (rata-dialogic--block-regexp) nil t)
                (setq blocks (1+ blocks))
                (setq turns (append turns (rata-dialogic-parse-turns
                                           (match-string 1)))))))
          (push (list :heading heading
                      :level level
                      :words (rata-dialogic--count-words beg end)
                      :blocks blocks
                      :turns (length turns)
                      :speakers (delete-dups (mapcar #'car turns)))
                rows)
          (goto-char beg))))
    (nreverse rows)))

(defun rata-dialogic--audit-notes (row)
  "Return the list of note strings for audit ROW."
  (let ((words (plist-get row :words))
        (blocks (plist-get row :blocks))
        (speakers (plist-get row :speakers))
        (known (rata-dialogic--speakers))
        notes)
    (when (> blocks rata-dialogic-max-blocks-per-heading)
      (push (format "%d blocks (max %d) — too chatty"
                    blocks rata-dialogic-max-blocks-per-heading)
            notes))
    (when (and (zerop blocks) (>= words rata-dialogic-words-per-block))
      (push (format "%d words, no interruption — candidate" words) notes))
    (dolist (s speakers)
      (unless (member s known)
        (push (format "unknown speaker %S — not in the cast" s) notes)))
    (nreverse notes)))

;;;###autoload
(defun rata-dialogic-audit ()
  "Report dialogue density per heading for the current buffer."
  (interactive)
  (let ((rows (rata-dialogic-audit-data))
        (source (buffer-name)))
    (with-current-buffer (get-buffer-create "*dialogic-audit*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Dialogue audit — %s\n" source)
                (format "cast: %s | max %d block(s)/heading | candidate at %d words\n\n"
                        (mapconcat #'identity (rata-dialogic--speakers) ", ")
                        rata-dialogic-max-blocks-per-heading
                        rata-dialogic-words-per-block)
                (format "%-6s %-44s %6s %6s %6s\n" "level" "heading" "words" "blocks" "turns")
                (make-string 72 ?-) "\n")
        (dolist (row rows)
          (insert (format "%-6d %-44s %6d %6d %6d\n"
                          (plist-get row :level)
                          (truncate-string-to-width (plist-get row :heading) 44)
                          (plist-get row :words)
                          (plist-get row :blocks)
                          (plist-get row :turns)))
          (dolist (note (rata-dialogic--audit-notes row))
            (insert (format "       ↳ %s\n" note))))
        (insert "\n"
                (format "totals: %d blocks, %d turns, %d words\n"
                        (apply #'+ (mapcar (lambda (r) (plist-get r :blocks)) rows))
                        (apply #'+ (mapcar (lambda (r) (plist-get r :turns)) rows))
                        (apply #'+ (mapcar (lambda (r) (plist-get r :words)) rows))))
        (goto-char (point-min)))
      (special-mode)
      ;; `special-mode' is in none of evil's state lists, so a plain
      ;; `define-key' here would be shadowed — same reason
      ;; `init-claude-loop.el' uses the function form.
      (when (fboundp 'evil-define-key*)
        (evil-define-key* 'normal (current-local-map) (kbd "q") #'quit-window)))
    (display-buffer "*dialogic-audit*")))

;;; ============================================================
;;; Export — dialogue block to styled HTML
;;; ============================================================

(defun rata-dialogic--who-slug (who)
  "Return WHO as a CSS-safe suffix, e.g. \"Me\" to \"me\"."
  (let ((slug (downcase (replace-regexp-in-string "[^[:alnum:]]+" "-" who))))
    (string-trim slug "-+" "-+")))

(defun rata-dialogic--who-snippet (who backend)
  "Return an export-snippet object marking WHO as the speaker for BACKEND.
The speaker gets a second, per-character class so the author's own replies
can be styled apart from an interruption without the CSS having to guess
from document order."
  (org-element-create
   'export-snippet
   (list :back-end (if (org-export-derived-backend-p backend 'html) "html" "md")
         :value (format "<span class=\"%s %s--%s\">%s</span> "
                        rata-dialogic-who-class
                        rata-dialogic-who-class
                        (rata-dialogic--who-slug who)
                        who))))

(defun rata-dialogic--item-to-paragraph (item backend info)
  "Convert description-list ITEM into a paragraph for BACKEND.
Returns nil when the item carries no tag, so a plain list accidentally
left inside a dialogue block is dropped rather than mangled.  INFO is the
export communication channel."
  (ignore info)
  (let* ((tag (org-element-property :tag item))
         ;; The raw org text of the tag, not an exported string: the speaker
         ;; name goes inside an HTML attribute-free <span>, and reading it
         ;; through a second backend would need that backend loaded.
         (who (and tag (string-trim (org-element-interpret-data tag)))))
    (when (org-string-nw-p who)
      (let* ((children (org-element-contents item))
             (first-para (car children))
             (rest (cdr children))
             (body (if (eq (org-element-type first-para) 'paragraph)
                       (org-element-contents first-para)
                     children))
             (rest (if (eq (org-element-type first-para) 'paragraph) rest nil))
             ;; `:post-blank' 1 is load-bearing: without it the turns are
             ;; concatenated with no blank line between them and Markdown reads
             ;; the whole exchange as one paragraph, so every speaker ends up in
             ;; the same <p>.
             (para (apply #'org-element-create 'paragraph '(:post-blank 1)
                          (cons (rata-dialogic--who-snippet who backend) body))))
        (dolist (el rest)
          (org-element-put-property el :post-blank 1))
        (cons para rest)))))

(defun rata-dialogic--filter-parse-tree (tree backend info)
  "Rewrite dialogue blocks in TREE for BACKEND before transcoding.
Each description-list item becomes a paragraph opening with a raw <span>
naming the speaker; the surrounding special block is left alone, so
ox-hugo still wraps it in `<div class=\"dialogue\">'.  INFO is the export
communication channel."
  (when (org-export-derived-backend-p backend 'md 'html)
    (org-element-map tree 'special-block
      (lambda (blk)
        (when (equal (org-element-property :type blk) rata-dialogic-block-name)
          (dolist (list-el (org-element-map blk 'plain-list #'identity nil nil 'plain-list))
            (let (replacements)
              (dolist (item (org-element-contents list-el))
                (when (eq (org-element-type item) 'item)
                  (let ((converted (rata-dialogic--item-to-paragraph item backend info)))
                    (when converted
                      (setq replacements (append replacements converted))))))
              (when replacements
                (dolist (el replacements)
                  (org-element-insert-before el list-el))
                (if (fboundp 'org-element-extract)
                    (org-element-extract list-el)
                  (org-element-extract-element list-el)))))))))
  tree)

(with-eval-after-load 'ox
  (add-to-list 'org-export-filter-parse-tree-functions
               #'rata-dialogic--filter-parse-tree))

;;; ============================================================
;;; Integration
;;; ============================================================

(with-eval-after-load 'org
  ;; `C-c C-,' d expands the block, for when the keyboard is already in org.
  (add-to-list 'org-structure-template-alist
               (cons "d" rata-dialogic-block-name)))

;; Leader keys at top level, not in a deferred `:config' — see FAIL-0009.
(with-eval-after-load 'general
  (rata-leader
    :states '(normal visual)
    "obd"  '(:ignore t :which-key "dialogic")
    "obdd" '(rata-dialogic-insert-block :which-key "insert dialogue")
    "obdt" '(rata-dialogic-insert-turn  :which-key "add turn")
    "obdf" '(rata-dialogic-toggle-fold  :which-key "fold dialogues")
    "obda" '(rata-dialogic-audit        :which-key "audit density")))

(provide 'init-dialogic)
