;;; rust-mode.el --- A major emacs mode for editing Rust source code -*-lexical-binding: t-*-

;; Version: 0.5.0
;; Author: Mozilla
;; Url: https://github.com/rust-lang/rust-mode
;; Keywords: languages
;; Package-Requires: ((emacs "25.1"))

;; This file is distributed under the terms of both the MIT license and the
;; Apache License (version 2.0).

;;; Commentary:
;;

;;; Code:

(eval-when-compile (require 'rx)
                   (require 'compile)
                   (require 'url-vars))

(require 'json)
(require 'thingatpt)

(defvar electric-pair-inhibit-predicate)
(defvar electric-pair-skip-self)
(defvar electric-indent-chars)

(defvar rust-buffer-project)
(make-variable-buffer-local 'rust-buffer-project)

(defun rust-re-word (inner) (concat "\\<" inner "\\>"))
(defun rust-re-grab (inner) (concat "\\(" inner "\\)"))
(defun rust-re-shy (inner) (concat "\\(?:" inner "\\)"))

(defconst rust-re-ident "[[:word:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst rust-re-lc-ident "[[:lower:][:multibyte:]_][[:word:][:multibyte:]_[:digit:]]*")
(defconst rust-re-uc-ident "[[:upper:]][[:word:][:multibyte:]_[:digit:]]*")
(defconst rust-re-unsafe "unsafe")
(defconst rust-re-extern "extern")
(defconst rust-re-async-or-const "async\\|const")
(defconst rust-re-generic
  (concat "<[[:space:]]*'" rust-re-ident "[[:space:]]*>"))
(defconst rust-re-union
  (rx-to-string
   `(seq
     (or space line-start)
     (group symbol-start "union" symbol-end)
     (+ space) (regexp ,rust-re-ident))))

(defvar rust-re-vis
  ;; pub | pub ( crate ) | pub ( self ) | pub ( super ) | pub ( in SimplePath )
  (concat
   "pub"
   (rust-re-shy
    (concat
     "[[:space:]]*([[:space:]]*"
     (rust-re-shy
      (concat "crate" "\\|"
              "\\(?:s\\(?:elf\\|uper\\)\\)" "\\|"
              ;;   in SimplePath
              (rust-re-shy
               (concat
                "in[[:space:]]+"
                rust-re-ident
                (rust-re-shy (concat "::" rust-re-ident)) "*"))))
     "[[:space:]]*)"))
   "?"))

;;; Start of a Rust item
(defvar rust-top-item-beg-re
  (concat "\\s-*"
          ;; TODO some of this does only make sense for `fn' (unsafe, extern...)
          ;; and not other items
          (rust-re-shy (concat (rust-re-shy rust-re-vis) "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-shy rust-re-async-or-const) "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-shy rust-re-unsafe) "[[:space:]]+")) "?"
          (regexp-opt
           '("enum" "struct" "union" "type" "mod" "use" "fn" "static" "impl"
             "extern" "trait"))
          "\\_>"))

(defun rust-looking-back-str (str)
  "Return non-nil if there's a match on the text before point and STR.
Like `looking-back' but for fixed strings rather than regexps (so
that it's not so slow)."
  (let ((len (length str)))
    (and (> (point) len)
         (equal str (buffer-substring-no-properties (- (point) len) (point))))))

(defun rust-looking-back-symbols (symbols)
  "Return non-nil if the point is after a member of SYMBOLS.
SYMBOLS is a list of strings that represent the respective
symbols."
  (save-excursion
    (let* ((pt-orig (point))
           (beg-of-symbol (progn (forward-thing 'symbol -1) (point)))
           (end-of-symbol (progn (forward-thing 'symbol 1) (point))))
      (and
       (= end-of-symbol pt-orig)
       (member (buffer-substring-no-properties beg-of-symbol pt-orig)
               symbols)))))

(defun rust-looking-back-ident ()
  "Non-nil if we are looking backwards at a valid rust identifier."
  (let ((beg-of-symbol (save-excursion (forward-thing 'symbol -1) (point))))
    (looking-back rust-re-ident beg-of-symbol)))

(defun rust-looking-back-macro ()
  "Non-nil if looking back at an ident followed by a !

This is stricter than rust syntax which allows a space between
the ident and the ! symbol. If this space is allowed, then we
would also need a keyword check to avoid `if !(condition)` being
seen as a macro."
  (if (> (- (point) (point-min)) 1)
      (save-excursion
        (backward-char)
        (and (= ?! (char-after))
             (rust-looking-back-ident)))))

;; Syntax definitions and helpers
(defvar rust-mode-syntax-table
  (let ((table (make-syntax-table)))

    ;; Operators
    (dolist (i '(?+ ?- ?* ?/ ?% ?& ?| ?^ ?! ?< ?> ?~ ?@))
      (modify-syntax-entry i "." table))

    ;; Strings
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)

    ;; Angle brackets.  We suppress this with syntactic propertization
    ;; when needed
    (modify-syntax-entry ?< "(>" table)
    (modify-syntax-entry ?> ")<" table)

    ;; Comments
    (modify-syntax-entry ?/  ". 124b" table)
    (modify-syntax-entry ?*  ". 23n"  table)
    (modify-syntax-entry ?\n "> b"    table)
    (modify-syntax-entry ?\^m "> b"   table)

    table))

(defgroup rust-mode nil
  "Support for Rust code."
  :link '(url-link "https://www.rust-lang.org/")
  :group 'languages)

(defcustom rust-indent-offset 4
  "Indent Rust code by this number of spaces."
  :type 'integer
  :group 'rust-mode
  :safe #'integerp)

(defcustom rust-indent-method-chain nil
  "Indent Rust method chains, aligned by the `.' operators."
  :type 'boolean
  :group 'rust-mode
  :safe #'booleanp)

(defcustom rust-indent-where-clause nil
  "Indent lines starting with the `where' keyword following a function or trait.
When nil, `where' will be aligned with `fn' or `trait'."
  :type 'boolean
  :group 'rust-mode
  :safe #'booleanp)

(defcustom rust-indent-return-type-to-arguments t
  "Indent a line starting with the `->' (RArrow) following a function, aligning
to the function arguments.  When nil, `->' will be indented one level."
  :type 'boolean
  :group 'rust-mode
  :safe #'booleanp)

(defcustom rust-playpen-url-format "https://play.rust-lang.org/?code=%s"
  "Format string to use when submitting code to the playpen."
  :type 'string
  :group 'rust-mode)

(defcustom rust-shortener-url-format "https://is.gd/create.php?format=simple&url=%s"
  "Format string to use for creating the shortened link of a playpen submission."
  :type 'string
  :group 'rust-mode)

(defcustom rust-match-angle-brackets t
  "Whether to attempt angle bracket matching (`<' and `>') where appropriate."
  :type 'boolean
  :safe #'booleanp
  :group 'rust-mode)

(defcustom rust-format-on-save nil
  "Format future rust buffers before saving using rustfmt."
  :type 'boolean
  :safe #'booleanp
  :group 'rust-mode)

(defcustom rust-format-show-buffer t
  "Show *rustfmt* buffer if formatting detected problems."
  :type 'boolean
  :safe #'booleanp
  :group 'rust-mode)

(defcustom rust-format-goto-problem t
  "Jump to location of first detected problem when formatting buffer."
  :type 'boolean
  :safe #'booleanp
  :group 'rust-mode)

(defcustom rust-rustfmt-bin "rustfmt"
  "Path to rustfmt executable."
  :type 'string
  :group 'rust-mode)

(defcustom rust-rustfmt-switches '("--edition" "2018")
  "Arguments to pass when invoking the `rustfmt' executable."
  :type '(repeat string)
  :group 'rust-mode)

(defcustom rust-cargo-bin "cargo"
  "Path to cargo executable."
  :type 'string
  :group 'rust-mode)

(defcustom rust-always-locate-project-on-open nil
  "Whether to run `cargo locate-project' every time `rust-mode' is activated."
  :type 'boolean
  :group 'rust-mode)

(defface rust-unsafe-face
  '((t :inherit font-lock-warning-face))
  "Face for the `unsafe' keyword."
  :group 'rust-mode)

(defface rust-question-mark-face
  '((t :weight bold :inherit font-lock-builtin-face))
  "Face for the question mark operator."
  :group 'rust-mode)

(defface rust-builtin-formatting-macro-face
  '((t :inherit font-lock-builtin-face))
  "Face for builtin formatting macros (print! &c.)."
  :group 'rust-mode)

(defface rust-string-interpolation-face
  '((t :slant italic :inherit font-lock-string-face))
  "Face for interpolating braces in builtin formatting macro strings."
  :group 'rust-mode)

(defun rust-paren-level () (nth 0 (syntax-ppss)))
(defun rust-in-str () (nth 3 (syntax-ppss)))
(defun rust-in-str-or-cmnt () (nth 8 (syntax-ppss)))
(defun rust-rewind-past-str-cmnt () (goto-char (nth 8 (syntax-ppss))))

(defun rust-rewind-irrelevant ()
  (let ((continue t))
    (while continue
      (let ((starting (point)))
        (skip-chars-backward "[:space:]\n")
        (when (rust-looking-back-str "*/")
          (backward-char))
        (when (rust-in-str-or-cmnt)
          (rust-rewind-past-str-cmnt))
        ;; Rewind until the point no longer moves
        (setq continue (/= starting (point)))))))

(defvar-local rust-macro-scopes nil
  "Cache for the scopes calculated by `rust-macro-scope'.

This variable can be `let' bound directly or indirectly around
`rust-macro-scope' as an optimization but should not be otherwise
set.")

(defun rust-macro-scope (start end)
  "Return the scope of macros in the buffer.

The return value is a list of (START END) positions in the
buffer.

If set START and END are optimizations which limit the return
value to scopes which are approximately with this range."
  (save-excursion
    ;; need to special case macro_rules which has unique syntax
    (let ((scope nil)
          (start (or start (point-min)))
          (end (or end (point-max))))
      (goto-char start)
      ;; if there is a start move back to the previous top level,
      ;; as any macros before that must have closed by this time.
      (let ((top (syntax-ppss-toplevel-pos (syntax-ppss))))
        (when top
          (goto-char top)))
      (while
          (and
           ;; The movement below may have moved us passed end, in
           ;; which case search-forward will error
           (< (point) end)
           (search-forward "!" end t))
        (let ((pt (point)))
          (cond
           ;; in a string or comment is boring, move straight on
           ((rust-in-str-or-cmnt))
           ;; in a normal macro,
           ((and (skip-chars-forward " \t\n\r")
                 (memq (char-after)
                       '(?\[ ?\( ?\{))
                 ;; Check that we have a macro declaration after.
                 (rust-looking-back-macro))
            (let ((start (point)))
              (ignore-errors (forward-list))
              (setq scope (cons (list start (point)) scope))))
           ;; macro_rules, why, why, why did you not use macro syntax??
           ((save-excursion
              ;; yuck -- last test moves point, even if it fails
              (goto-char (- pt 1))
              (skip-chars-backward " \t\n\r")
              (rust-looking-back-str "macro_rules"))
            (save-excursion
              (when (re-search-forward "[[({]" nil t)
                (backward-char)
                (let ((start (point)))
                  (ignore-errors (forward-list))
                  (setq scope (cons (list start (point)) scope)))))))))
      ;; Return 'empty rather than nil, to indicate a buffer with no
      ;; macros at all.
      (or scope 'empty))))

(defun rust-in-macro (&optional start end)
  "Return non-nil when point is within the scope of a macro.

If START and END are set, minimize the buffer analysis to
approximately this location as an optimization.

Alternatively, if `rust-macro-scopes' is a list use the scope
information in this variable. This last is an optimization and
the caller is responsible for ensuring that the data in
`rust-macro-scopes' is up to date."
  (when (> (rust-paren-level) 0)
    (let ((scopes
           (or
            rust-macro-scopes
            (rust-macro-scope start end))))
      ;; `rust-macro-scope' can return the symbol `empty' if the
      ;; buffer has no macros at all.
      (when (listp scopes)
        (seq-some
         (lambda (sc)
           (and (>= (point) (car sc))
                (< (point) (cadr sc))))
         scopes)))))

(defun rust-looking-at-where ()
  "Return T when looking at the \"where\" keyword."
  (and (looking-at-p "\\bwhere\\b")
       (not (rust-in-str-or-cmnt))))

(defun rust-rewind-to-where (&optional limit)
  "Rewind the point to the closest occurrence of the \"where\" keyword.
Return T iff a where-clause was found.  Does not rewind past
LIMIT when passed, otherwise only stops at the beginning of the
buffer."
  (when (re-search-backward "\\bwhere\\b" limit t)
    (if (rust-in-str-or-cmnt)
        (rust-rewind-to-where limit)
      t)))

(defun rust-align-to-expr-after-brace ()
  (save-excursion
    (forward-char)
    ;; We don't want to indent out to the open bracket if the
    ;; open bracket ends the line
    (when (not (looking-at "[[:blank:]]*\\(?://.*\\)?$"))
      (when (looking-at "[[:space:]]")
        (forward-word 1)
        (backward-word 1))
      (current-column))))

(defun rust-rewind-to-beginning-of-current-level-expr ()
  (let ((current-level (rust-paren-level)))
    (back-to-indentation)
    (when (looking-at "->")
      (rust-rewind-irrelevant)
      (back-to-indentation))
    (while (> (rust-paren-level) current-level)
      (backward-up-list)
      (back-to-indentation))
    ;; When we're in the where clause, skip over it.  First find out the start
    ;; of the function and its paren level.
    (let ((function-start nil) (function-level nil))
      (save-excursion
        (rust-beginning-of-defun)
        (back-to-indentation)
        ;; Avoid using multiple-value-bind
        (setq function-start (point)
              function-level (rust-paren-level)))
      ;; On a where clause
      (when (or (rust-looking-at-where)
                ;; or in one of the following lines, e.g.
                ;; where A: Eq
                ;;       B: Hash <- on this line
                (and (save-excursion
                       (rust-rewind-to-where function-start))
                     (= current-level function-level)))
        (goto-char function-start)))))

(defun rust-align-to-method-chain ()
  (save-excursion
    ;; for method-chain alignment to apply, we must be looking at
    ;; another method call or field access or something like
    ;; that. This avoids rather "eager" jumps in situations like:
    ;;
    ;; {
    ;;     something.foo()
    ;; <indent>
    ;;
    ;; Without this check, we would wind up with the cursor under the
    ;; `.`. In an older version, I had the inverse of the current
    ;; check, where we checked for situations that should NOT indent,
    ;; vs checking for the one situation where we SHOULD. It should be
    ;; clear that this is more robust, but also I find it mildly less
    ;; annoying to have to press tab again to align to a method chain
    ;; than to have an over-eager indent in all other cases which must
    ;; be undone via tab.

    (when (looking-at (concat "\s*\." rust-re-ident))
      (forward-line -1)
      (end-of-line)
      ;; Keep going up (looking for a line that could contain a method chain)
      ;; while we're in a comment or on a blank line. Stop when the paren
      ;; level changes.
      (let ((level (rust-paren-level)))
        (while (and (or (rust-in-str-or-cmnt)
                        ;; Only whitespace (or nothing) from the beginning to
                        ;; the end of the line.
                        (looking-back "^\s*" (point-at-bol)))
                    (= (rust-paren-level) level))
          (forward-line -1)
          (end-of-line)))

      (let
          ;; skip-dot-identifier is used to position the point at the
          ;; `.` when looking at something like
          ;;
          ;;      foo.bar
          ;;         ^   ^
          ;;         |   |
          ;;         |  position of point
          ;;       returned offset
          ;;
          ((skip-dot-identifier
            (lambda ()
              (when (and (rust-looking-back-ident)
                         (save-excursion
                           (forward-thing 'symbol -1)
                           (= ?. (char-before))))
                (forward-thing 'symbol -1)
                (backward-char)
                (- (current-column) rust-indent-offset)))))
        (cond
         ;; foo.bar(...)
         ((looking-back "[)?]" (1- (point)))
          (backward-list 1)
          (funcall skip-dot-identifier))

         ;; foo.bar
         (t (funcall skip-dot-identifier)))))))

(defun rust-mode-indent-line ()
  (interactive)
  (let ((indent
         (save-excursion
           (back-to-indentation)
           ;; Point is now at beginning of current line
           (let* ((level (rust-paren-level))
                  (baseline
                   ;; Our "baseline" is one level out from the
                   ;; indentation of the expression containing the
                   ;; innermost enclosing opening bracket.  That way
                   ;; if we are within a block that has a different
                   ;; indentation than this mode would give it, we
                   ;; still indent the inside of it correctly relative
                   ;; to the outside.
                   (if (= 0 level)
                       0
                     (or
                      (when rust-indent-method-chain
                        (rust-align-to-method-chain))
                      (save-excursion
                        (rust-rewind-irrelevant)
                        (backward-up-list)
                        (rust-rewind-to-beginning-of-current-level-expr)
                        (+ (current-column) rust-indent-offset))))))
             (cond
              ;; Indent inside a non-raw string only if the previous line
              ;; ends with a backslash that is inside the same string
              ((nth 3 (syntax-ppss))
               (let*
                   ((string-begin-pos (nth 8 (syntax-ppss)))
                    (end-of-prev-line-pos
                     (and (not (rust--same-line-p (point) (point-min)))
                          (line-end-position 0))))
                 (when
                     (and
                      ;; If the string begins with an "r" it's a raw string and
                      ;; we should not change the indentation
                      (/= ?r (char-after string-begin-pos))

                      ;; If we're on the first line this will be nil and the
                      ;; rest does not apply
                      end-of-prev-line-pos

                      ;; The end of the previous line needs to be inside the
                      ;; current string...
                      (> end-of-prev-line-pos string-begin-pos)

                      ;; ...and end with a backslash
                      (= ?\\ (char-before end-of-prev-line-pos)))

                   ;; Indent to the same level as the previous line, or the
                   ;; start of the string if the previous line starts the string
                   (if (rust--same-line-p end-of-prev-line-pos string-begin-pos)
                       ;; The previous line is the start of the string.
                       ;; If the backslash is the only character after the
                       ;; string beginning, indent to the next indent
                       ;; level.  Otherwise align with the start of the string.
                       (if (> (- end-of-prev-line-pos string-begin-pos) 2)
                           (save-excursion
                             (goto-char (+ 1 string-begin-pos))
                             (current-column))
                         baseline)

                     ;; The previous line is not the start of the string, so
                     ;; match its indentation.
                     (save-excursion
                       (goto-char end-of-prev-line-pos)
                       (back-to-indentation)
                       (current-column))))))

              ;; A function return type is indented to the corresponding
              ;; function arguments, if -to-arguments is selected.
              ((and rust-indent-return-type-to-arguments
                    (looking-at "->"))
               (save-excursion
                 (backward-list)
                 (or (rust-align-to-expr-after-brace)
                     (+ baseline rust-indent-offset))))

              ;; A closing brace is 1 level unindented
              ((looking-at "[]})]") (- baseline rust-indent-offset))

              ;; Doc comments in /** style with leading * indent to line up the *s
              ((and (nth 4 (syntax-ppss)) (looking-at "*"))
               (+ 1 baseline))

              ;; When the user chose not to indent the start of the where
              ;; clause, put it on the baseline.
              ((and (not rust-indent-where-clause)
                    (rust-looking-at-where))
               baseline)

              ;; If we're in any other token-tree / sexp, then:
              (t
               (or
                ;; If we are inside a pair of braces, with something after the
                ;; open brace on the same line and ending with a comma, treat
                ;; it as fields and align them.
                (when (> level 0)
                  (save-excursion
                    (rust-rewind-irrelevant)
                    (backward-up-list)
                    ;; Point is now at the beginning of the containing set of braces
                    (rust-align-to-expr-after-brace)))

                ;; When where-clauses are spread over multiple lines, clauses
                ;; should be aligned on the type parameters.  In this case we
                ;; take care of the second and following clauses (the ones
                ;; that don't start with "where ")
                (save-excursion
                  ;; Find the start of the function, we'll use this to limit
                  ;; our search for "where ".
                  (let ((function-start nil) (function-level nil))
                    (save-excursion
                      ;; If we're already at the start of a function,
                      ;; don't go back any farther.  We can easily do
                      ;; this by moving to the end of the line first.
                      (end-of-line)
                      (rust-beginning-of-defun)
                      (back-to-indentation)
                      ;; Avoid using multiple-value-bind
                      (setq function-start (point)
                            function-level (rust-paren-level)))
                    ;; When we're not on a line starting with "where ", but
                    ;; still on a where-clause line, go to "where "
                    (when (and
                           (not (rust-looking-at-where))
                           ;; We're looking at something like "F: ..."
                           (looking-at (concat rust-re-ident ":"))
                           ;; There is a "where " somewhere after the
                           ;; start of the function.
                           (rust-rewind-to-where function-start)
                           ;; Make sure we're not inside the function
                           ;; already (e.g. initializing a struct) by
                           ;; checking we are the same level.
                           (= function-level level))
                      ;; skip over "where"
                      (forward-char 5)
                      ;; Unless "where" is at the end of the line
                      (if (eolp)
                          ;; in this case the type parameters bounds are just
                          ;; indented once
                          (+ baseline rust-indent-offset)
                        ;; otherwise, skip over whitespace,
                        (skip-chars-forward "[:space:]")
                        ;; get the column of the type parameter and use that
                        ;; as indentation offset
                        (current-column)))))

                (progn
                  (back-to-indentation)
                  ;; Point is now at the beginning of the current line
                  (if (or
                       ;; If this line begins with "else" or "{", stay on the
                       ;; baseline as well (we are continuing an expression,
                       ;; but the "else" or "{" should align with the beginning
                       ;; of the expression it's in.)
                       ;; Or, if this line starts a comment, stay on the
                       ;; baseline as well.
                       (looking-at "\\<else\\>\\|{\\|/[/*]")

                       ;; If this is the start of a top-level item,
                       ;; stay on the baseline.
                       (looking-at rust-top-item-beg-re)

                       (save-excursion
                         (rust-rewind-irrelevant)
                         ;; Point is now at the end of the previous line
                         (or
                          ;; If we are at the start of the buffer, no
                          ;; indentation is needed, so stay at baseline...
                          (= (point) 1)
                          ;; ..or if the previous line ends with any of these:
                          ;;     { ? : ( , ; [ }
                          ;; then we are at the beginning of an
                          ;; expression, so stay on the baseline...
                          (looking-back "[(,:;[{}]\\|[^|]|" (- (point) 2))
                          ;; or if the previous line is the end of an
                          ;; attribute, stay at the baseline...
                          (progn (rust-rewind-to-beginning-of-current-level-expr)
                                 (looking-at "#")))))
                      baseline

                    ;; Otherwise, we are continuing the same expression from
                    ;; the previous line, so add one additional indent level
                    (+ baseline rust-indent-offset))))))))))

    (when indent
      ;; If we're at the beginning of the line (before or at the current
      ;; indentation), jump with the indentation change.  Otherwise, save the
      ;; excursion so that adding the indentations will leave us at the
      ;; equivalent position within the line to where we were before.
      (if (<= (current-column) (current-indentation))
          (indent-line-to indent)
        (save-excursion (indent-line-to indent))))))

(defun rust--same-line-p (pos1 pos2)
  "Return non-nil if POS1 and POS2 are on the same line."
  (save-excursion (= (progn (goto-char pos1) (line-end-position))
                     (progn (goto-char pos2) (line-end-position)))))

;; Font-locking definitions and helpers
(defconst rust-mode-keywords
  '("as" "async" "await"
    "box" "break"
    "const" "continue" "crate"
    "do" "dyn"
    "else" "enum" "extern"
    "false" "fn" "for"
    "if" "impl" "in"
    "let" "loop"
    "match" "mod" "move" "mut"
    "priv" "pub"
    "ref" "return"
    "self" "static" "struct" "super"
    "true" "trait" "type" "try"
    "use"
    "virtual"
    "where" "while"
    "yield"))

(defconst rust-special-types
  '("u8" "i8"
    "u16" "i16"
    "u32" "i32"
    "u64" "i64"
    "u128" "i128"

    "f32" "f64"
    "isize" "usize"
    "bool"
    "str" "char"))

(defconst rust-re-type-or-constructor
  (rx symbol-start
      (group upper (0+ (any word nonascii digit "_")))
      symbol-end))

(defconst rust-re-pre-expression-operators "[-=!%&*/:<>[{(|.^;}]")
(defun rust-re-item-def (itype)
  (concat (rust-re-word itype)
          (rust-re-shy rust-re-generic) "?"
          "[[:space:]]+" (rust-re-grab rust-re-ident)))

;; TODO some of this does only make sense for `fn' (unsafe, extern...)
;; and not other items
(defun rust-re-item-def-imenu (itype)
  (concat "^[[:space:]]*"
          (rust-re-shy (concat rust-re-vis "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-word "default") "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-shy rust-re-async-or-const) "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-word rust-re-unsafe) "[[:space:]]+")) "?"
          (rust-re-shy (concat (rust-re-word rust-re-extern) "[[:space:]]+"
                               (rust-re-shy "\"[^\"]+\"[[:space:]]+") "?")) "?"
          (rust-re-item-def itype)))

(defconst rust-re-special-types (regexp-opt rust-special-types 'symbols))

(defun rust-path-font-lock-matcher (re-ident)
  "Match occurrences of RE-IDENT followed by a double-colon.
Examples include to match names like \"foo::\" or \"Foo::\".
Does not match type annotations of the form \"foo::<\"."
  `(lambda (limit)
     (catch 'rust-path-font-lock-matcher
       (while t
         (let* ((symbol-then-colons (rx-to-string '(seq (group (regexp ,re-ident)) "::")))
                (match (re-search-forward symbol-then-colons limit t)))
           (cond
            ;; If we didn't find a match, there are no more occurrences
            ;; of foo::, so return.
            ((null match) (throw 'rust-path-font-lock-matcher nil))
            ;; If this isn't a type annotation foo::<, we've found a
            ;; match, so a return it!
            ((not (looking-at (rx (0+ space) "<")))
             (throw 'rust-path-font-lock-matcher match))))))))

(defun rust-next-string-interpolation (limit)
  "Search forward from point for the next Rust interpolation marker before LIMIT.
Set point to the end of the occurrence found, and return match beginning
and end."
  (catch 'match
    (save-match-data
      (save-excursion
        (while (search-forward "{" limit t)
          (if (eql (char-after (point)) ?{)
              (forward-char)
            (let ((start (match-beginning 0)))
              ;; According to fmt_macros::Parser::next, an opening brace
              ;; must be followed by an optional argument and/or format
              ;; specifier, then a closing brace. A single closing brace
              ;; without a corresponding unescaped opening brace is an
              ;; error. We don't need to do anything special with
              ;; arguments, specifiers, or errors, so we only search for
              ;; the single closing brace.
              (when (search-forward "}" limit t)
                (throw 'match (list start (point)))))))))))

(defun rust-string-interpolation-matcher (limit)
  "Match the next Rust interpolation marker before LIMIT; set match data if found.
Returns nil if the point is not within a Rust string."
  (when (rust-in-str)
    (let ((match (rust-next-string-interpolation limit)))
      (when match
        (set-match-data match)
        (goto-char (cadr match))
        match))))

(defvar rust-builtin-formatting-macros
  '("eprint"
    "eprintln"
    "format"
    "print"
    "println")
  "List of builtin Rust macros for string formatting.
This is used by `rust-mode-font-lock-keywords'.
(`write!' is handled separately).")

(defvar rust-formatting-macro-opening-re
  "[[:space:]\n]*[({[][[:space:]\n]*"
  "Regular expression to match the opening delimiter of a Rust formatting macro.")

(defvar rust-start-of-string-re
  "\\(?:r#*\\)?\""
  "Regular expression to match the start of a Rust raw string.")

(defvar rust-mode-font-lock-keywords
  (append
   `(
     ;; Keywords proper
     (,(regexp-opt rust-mode-keywords 'symbols) . font-lock-keyword-face)

     ;; Contextual keywords
     ("\\_<\\(default\\)[[:space:]]+fn\\_>" 1 font-lock-keyword-face)
     (,rust-re-union 1 font-lock-keyword-face)

     ;; Special types
     (,(regexp-opt rust-special-types 'symbols) . font-lock-type-face)

     ;; The unsafe keyword
     ("\\_<unsafe\\_>" . 'rust-unsafe-face)

     ;; Attributes like `#[bar(baz)]` or `#![bar(baz)]` or `#[bar = "baz"]`
     (,(rust-re-grab (concat "#\\!?\\[" rust-re-ident "[^]]*\\]"))
      1 font-lock-preprocessor-face keep)

     ;; Builtin formatting macros
     (,(concat (rust-re-grab
                (concat (rust-re-word (regexp-opt rust-builtin-formatting-macros))
                        "!"))
               (concat rust-formatting-macro-opening-re
                       "\\(?:" rust-start-of-string-re) "\\)?")
      (1 'rust-builtin-formatting-macro-face)
      (rust-string-interpolation-matcher
       (rust-end-of-string)
       nil
       (0 'rust-string-interpolation-face t nil)))

     ;; write! macro
     (,(concat (rust-re-grab (concat (rust-re-word "write\\(ln\\)?") "!"))
               (concat rust-formatting-macro-opening-re
                       "[[:space:]]*[^\"]+,[[:space:]]*" rust-start-of-string-re))
      (1 'rust-builtin-formatting-macro-face)
      (rust-string-interpolation-matcher
       (rust-end-of-string)
       nil
       (0 'rust-string-interpolation-face t nil)))

     ;; Syntax extension invocations like `foo!`, highlight including the !
     (,(concat (rust-re-grab (concat rust-re-ident "!")) "[({[:space:][]")
      1 font-lock-preprocessor-face)

     ;; Field names like `foo:`, highlight excluding the :
     (,(concat (rust-re-grab rust-re-ident) "[[:space:]]*:[^:]")
      1 font-lock-variable-name-face)

     ;; CamelCase Means Type Or Constructor
     (,rust-re-type-or-constructor 1 font-lock-type-face)

     ;; Type-inferred binding
     (,(concat "\\_<\\(?:let\\s-+ref\\|let\\|ref\\|for\\)\\s-+\\(?:mut\\s-+\\)?"
               (rust-re-grab rust-re-ident) "\\_>") 1 font-lock-variable-name-face)

     ;; Type names like `Foo::`, highlight excluding the ::
     (,(rust-path-font-lock-matcher rust-re-uc-ident) 1 font-lock-type-face)

     ;; Module names like `foo::`, highlight excluding the ::
     (,(rust-path-font-lock-matcher rust-re-lc-ident) 1 font-lock-constant-face)

     ;; Lifetimes like `'foo`
     (,(concat "'" (rust-re-grab rust-re-ident) "[^']") 1 font-lock-variable-name-face)

     ;; Question mark operator
     ("\\?" . 'rust-question-mark-face)
     )

   ;; Ensure we highlight `Foo` in `struct Foo` as a type.
   (mapcar #'(lambda (x)
               (list (rust-re-item-def (car x))
                     1 (cdr x)))
           '(("enum" . font-lock-type-face)
             ("struct" . font-lock-type-face)
             ("union" . font-lock-type-face)
             ("type" . font-lock-type-face)
             ("mod" . font-lock-constant-face)
             ("use" . font-lock-constant-face)
             ("fn" . font-lock-function-name-face)))))

(defun rust-syntax-class-before-point ()
  (when (> (point) 1)
    (syntax-class (syntax-after (1- (point))))))

(defun rust-rewind-qualified-ident ()
  (while (rust-looking-back-ident)
    (backward-sexp)
    (when (save-excursion (rust-rewind-irrelevant) (rust-looking-back-str "::"))
      (rust-rewind-irrelevant)
      (backward-char 2)
      (rust-rewind-irrelevant))))

(defun rust-rewind-type-param-list ()
  (cond
   ((and (rust-looking-back-str ">") (equal 5 (rust-syntax-class-before-point)))
    (backward-sexp)
    (rust-rewind-irrelevant))

   ;; We need to be able to back up past the Fn(args) -> RT form as well.  If
   ;; we're looking back at this, we want to end up just after "Fn".
   ((member (char-before) '(?\] ?\) ))
    (let* ((is-paren (rust-looking-back-str ")"))
           (dest (save-excursion
                   (backward-sexp)
                   (rust-rewind-irrelevant)
                   (or
                    (when (rust-looking-back-str "->")
                      (backward-char 2)
                      (rust-rewind-irrelevant)
                      (when (rust-looking-back-str ")")
                        (backward-sexp)
                        (point)))
                    (and is-paren (point))))))
      (when dest
        (goto-char dest))))))

(defun rust-rewind-to-decl-name ()
  "Return the point at the beginning of the name in a declaration.
I.e. if we are before an ident that is part of a declaration that
can have a where clause, rewind back to just before the name of
the subject of that where clause and return the new point.
Otherwise return nil."

  (let* ((ident-pos (point))
         (newpos (save-excursion
                   (rust-rewind-irrelevant)
                   (rust-rewind-type-param-list)
                   (cond
                    ((rust-looking-back-symbols
                      '("fn" "trait" "enum" "struct" "union" "impl" "type"))
                     ident-pos)

                    ((equal 5 (rust-syntax-class-before-point))
                     (backward-sexp)
                     (rust-rewind-to-decl-name))

                    ((looking-back "[:,'+=]" (1- (point)))
                     (backward-char)
                     (rust-rewind-to-decl-name))

                    ((rust-looking-back-str "->")
                     (backward-char 2)
                     (rust-rewind-to-decl-name))

                    ((rust-looking-back-ident)
                     (rust-rewind-qualified-ident)
                     (rust-rewind-to-decl-name))))))
    (when newpos (goto-char newpos))
    newpos))

(defun rust-is-in-expression-context (token)
  "Return t if what comes right after the point is part of an
expression (as opposed to starting a type) by looking at what
comes before.  Takes a symbol that roughly indicates what is
after the point.

This function is used as part of `rust-is-lt-char-operator' as
part of angle bracket matching, and is not intended to be used
outside of this context."
  (save-excursion
    (let ((postchar (char-after)))
      (rust-rewind-irrelevant)
      ;; A type alias or ascription could have a type param list.  Skip backwards past it.
      (when (member token '(ambiguous-operator open-brace))
        (rust-rewind-type-param-list))
      (cond

       ;; Certain keywords always introduce expressions
       ((rust-looking-back-symbols '("if" "while" "match" "return" "box" "in")) t)

       ;; "as" introduces a type
       ((rust-looking-back-symbols '("as")) nil)

       ;; An open angle bracket never introduces expression context WITHIN the angle brackets
       ((and (equal token 'open-brace) (equal postchar ?<)) nil)

       ;; An ident! followed by an open brace is a macro invocation.  Consider
       ;; it to be an expression.
       ((and (equal token 'open-brace) (rust-looking-back-macro)) t)

       ;; In a brace context a "]" introduces an expression.
       ((and (eq token 'open-brace) (rust-looking-back-str "]")))

       ;; An identifier is right after an ending paren, bracket, angle bracket
       ;; or curly brace.  It's a type if the last sexp was a type.
       ((and (equal token 'ident) (equal 5 (rust-syntax-class-before-point)))
        (backward-sexp)
        (rust-is-in-expression-context 'open-brace))

       ;; If a "for" appears without a ; or { before it, it's part of an
       ;; "impl X for y", so the y is a type.  Otherwise it's
       ;; introducing a loop, so the y is an expression
       ((and (equal token 'ident) (rust-looking-back-symbols '("for")))
        (backward-sexp)
        (rust-rewind-irrelevant)
        (looking-back "[{;]" (1- (point))))

       ((rust-looking-back-ident)
        (rust-rewind-qualified-ident)
        (rust-rewind-irrelevant)
        (cond
         ((equal token 'open-brace)
          ;; We now know we have:
          ;;   ident <maybe type params> [{([]
          ;; where [{([] denotes either a {, ( or [.
          ;; This character is bound as postchar.
          (cond
           ;; If postchar is a paren or square bracket, then if the
           ;; brace is a type if the identifier is one
           ((member postchar '(?\( ?\[ )) (rust-is-in-expression-context 'ident))

           ;; If postchar is a curly brace, the brace can only be a type if
           ;; ident2 is the name of an enum, struct or trait being declared.
           ;; Note that if there is a -> before the ident then the ident would
           ;; be a type but the { is not.
           ((equal ?{ postchar)
            (not (and (rust-rewind-to-decl-name)
                      (progn
                        (rust-rewind-irrelevant)
                        (rust-looking-back-symbols
                         '("enum" "struct" "union" "trait" "type"))))))))

         ((equal token 'ambiguous-operator)
          (cond
           ;; An ampersand after an ident has to be an operator rather
           ;; than a & at the beginning of a ref type
           ((equal postchar ?&) t)

           ;; A : followed by a type then an = introduces an
           ;; expression (unless it is part of a where clause of a
           ;; "type" declaration)
           ((and (equal postchar ?=)
                 (looking-back "[^:]:" (- (point) 2))
                 (not (save-excursion
                        (and (rust-rewind-to-decl-name)
                             (progn (rust-rewind-irrelevant)
                                    (rust-looking-back-symbols '("type"))))))))

           ;; "let ident =" introduces an expression--and so does "const" and "mut"
           ((and (equal postchar ?=) (rust-looking-back-symbols '("let" "const" "mut"))) t)

           ;; As a specific special case, see if this is the = in this situation:
           ;;     enum EnumName<type params> { Ident =
           ;; In this case, this is a c-like enum and despite Ident
           ;; representing a type, what comes after the = is an expression
           ((and
             (> (rust-paren-level) 0)
             (save-excursion
               (backward-up-list)
               (rust-rewind-irrelevant)
               (rust-rewind-type-param-list)
               (and
                (rust-looking-back-ident)
                (progn
                  (rust-rewind-qualified-ident)
                  (rust-rewind-irrelevant)
                  (rust-looking-back-str "enum")))))
            t)

           ;; Otherwise the ambiguous operator is a type if the identifier is a type
           ((rust-is-in-expression-context 'ident) t)))

         ((equal token 'colon)
          (cond
           ;; If we see a ident: not inside any braces/parens, we're at top level.
           ;; There are no allowed expressions after colons there, just types.
           ((<= (rust-paren-level) 0) nil)

           ;; We see ident: inside a list
           ((looking-back "[{,]" (1- (point)))
            (backward-up-list)

            ;; If a : appears whose surrounding paren/brackets/braces are
            ;; anything other than curly braces, it can't be a field
            ;; initializer and must be denoting a type.
            (when (looking-at "{")
              (rust-rewind-irrelevant)
              (rust-rewind-type-param-list)
              (when (rust-looking-back-ident)
                ;; We have a context that looks like this:
                ;;    ident2 <maybe type params> { [maybe paren-balanced code ending in comma] ident1:
                ;; the point is sitting just after ident2, and we trying to
                ;; figure out if the colon introduces an expression or a type.
                ;; The answer is that ident1 is a field name, and what comes
                ;; after the colon is an expression, if ident2 is an
                ;; expression.
                (rust-rewind-qualified-ident)
                (rust-is-in-expression-context 'ident))))

           ;; Otherwise, if the ident: appeared with anything other than , or {
           ;; before it, it can't be part of a struct initializer and therefore
           ;; must be denoting a type.
           (t nil)))))

       ;; An operator-like character after a string is indeed an operator
       ((and (equal token 'ambiguous-operator)
             (member (rust-syntax-class-before-point) '(5 7 15))) t)

       ;; A colon that has something other than an identifier before it is a
       ;; type ascription
       ((equal token 'colon) nil)

       ;; A :: introduces a type (or module, but not an expression in any case)
       ((rust-looking-back-str "::") nil)

       ((rust-looking-back-str ":")
        (backward-char)
        (rust-is-in-expression-context 'colon))

       ;; A -> introduces a type
       ((rust-looking-back-str "->") nil)

       ;; If we are up against the beginning of a list, or after a comma inside
       ;; of one, back up out of it and check what the list itself is
       ((or
         (equal 4 (rust-syntax-class-before-point))
         (rust-looking-back-str ","))
        (condition-case nil
            (progn
              (backward-up-list)
              (rust-is-in-expression-context 'open-brace))
          (scan-error nil)))

       ;; A => introduces an expression
       ((rust-looking-back-str "=>") t)

       ;; A == introduces an expression
       ((rust-looking-back-str "==") t)

       ;; These operators can introduce expressions or types
       ((looking-back "[-+=!?&*]" (1- (point)))
        (backward-char)
        (rust-is-in-expression-context 'ambiguous-operator))

       ;; These operators always introduce expressions.  (Note that if this
       ;; regexp finds a < it must not be an angle bracket, or it'd
       ;; have been caught in the syntax-class check above instead of this.)
       ((looking-back rust-re-pre-expression-operators (1- (point))) t)))))

(defun rust-is-lt-char-operator ()
  "Return t if the `<' after the point is the less-than operator.
Otherwise, for instance if it's an opening angle bracket, return nil."

  (let ((case-fold-search nil))
    (save-excursion
      (rust-rewind-irrelevant)
      ;; We are now just after the character syntactically before the <.
      (cond

       ;; If we are looking back at a < that is not an angle bracket (but not
       ;; two of them) then this is the second < in a bit shift operator
       ((and (rust-looking-back-str "<")
             (not (equal 4 (rust-syntax-class-before-point)))
             (not (rust-looking-back-str "<<"))))

       ;; On the other hand, if we are after a closing paren/brace/bracket it
       ;; can only be an operator, not an angle bracket.  Likewise, if we are
       ;; after a string it's an operator.  (The string case could actually be
       ;; valid in rust for character literals.)
       ((member (rust-syntax-class-before-point) '(5 7 15)) t)

       ;; If we are looking back at an operator, we know that we are at
       ;; the beginning of an expression, and thus it has to be an angle
       ;; bracket (starting a "<Type as Trait>::" construct.)
       ((looking-back rust-re-pre-expression-operators (1- (point))) nil)

       ;; If we are looking back at a keyword, it's an angle bracket
       ;; unless that keyword is "self", "true" or "false"
       ((rust-looking-back-symbols rust-mode-keywords)
        (rust-looking-back-symbols '("self" "true" "false")))

       ((rust-looking-back-str "?")
        (rust-is-in-expression-context 'ambiguous-operator))

       ;; If we're looking back at an identifier, this depends on whether
       ;; the identifier is part of an expression or a type
       ((rust-looking-back-ident)
        (backward-sexp)
        (or
         ;; The special types can't take type param lists, so a < after one is
         ;; always an operator
         (looking-at rust-re-special-types)

         (rust-is-in-expression-context 'ident)))

       ;; Otherwise, assume it's an angle bracket
       ))))

(defun rust-electric-pair-inhibit-predicate-wrap (char)
  "Prevent \"matching\" with a `>' when CHAR is the less-than operator.
This wraps the default defined by `electric-pair-inhibit-predicate'."
  (or
   (when (= ?< char)
     (save-excursion
       (backward-char)
       (rust-is-lt-char-operator)))
   (funcall (default-value 'electric-pair-inhibit-predicate) char)))

(defun rust-electric-pair-skip-self-wrap (char)
  "Skip CHAR instead of inserting a second closing character.
This wraps the default defined by `electric-pair-skip-self'."
  (or
   (= ?> char)
   (funcall (default-value 'electric-pair-skip-self) char)))

(defun rust-ordinary-lt-gt-p ()
  "Test whether the `<' or `>' at point is an ordinary operator of some kind.

This returns t if the `<' or `>' is an ordinary operator (like
less-than) or part of one (like `->'); and nil if the character
should be considered a paired angle bracket."
  (cond
   ;; If matching is turned off suppress all of them
   ((not rust-match-angle-brackets) t)

   ;; This is a cheap check so we do it early.
   ;; Don't treat the > in -> or => as an angle bracket
   ((and (= (following-char) ?>) (memq (preceding-char) '(?- ?=))) t)

   ;; We don't take < or > in strings or comments to be angle brackets
   ((rust-in-str-or-cmnt) t)

   ;; Inside a macro we don't really know the syntax.  Any < or > may be an
   ;; angle bracket or it may not.  But we know that the other braces have
   ;; to balance regardless of the < and >, so if we don't treat any < or >
   ;; as angle brackets it won't mess up any paren balancing.
   ((rust-in-macro) t)

   ((= (following-char) ?<)
    (rust-is-lt-char-operator))

   ;; Since rust-ordinary-lt-gt-p is called only when either < or > are at the point,
   ;; we know that the following char must be > in the clauses below.

   ;; If we are at top level and not in any list, it can't be a closing
   ;; angle bracket
   ((>= 0 (rust-paren-level)) t)

   ;; Otherwise, treat the > as a closing angle bracket if it would
   ;; match an opening one
   ((save-excursion
      (backward-up-list)
      (/= (following-char) ?<)))))

(defun rust-mode-syntactic-face-function (state)
  "Return face which distinguishes doc and normal comments in the given syntax STATE."
  (if (nth 3 state)
      'font-lock-string-face
    (save-excursion
      (goto-char (nth 8 state))
      (if (looking-at "/\\([*][*!][^*!]\\|/[/!][^/!]\\)")
          'font-lock-doc-face
        'font-lock-comment-face))))

(eval-and-compile
  (defconst rust--char-literal-rx
    (rx (seq
         (group "'")
         (or
          (seq
           "\\"
           (or
            (: "u{" (** 1 6 xdigit) "}")
            (: "x" (= 2 xdigit))
            (any "'nrt0\"\\")))
          (not (any "'\\")))
         (group "'")))
    "A regular expression matching a character literal."))

(defun rust--syntax-propertize-raw-string (str-start end)
  "A helper for rust-syntax-propertize.

This will apply the appropriate string syntax to the character
from the STR-START up to the end of the raw string, or to END,
whichever comes first."
  (when (save-excursion
          (goto-char str-start)
          (looking-at "r\\(#*\\)\\(\"\\)"))
    ;; In a raw string, so try to find the end.
    (let ((hashes (match-string 1)))
      ;; Match \ characters at the end of the string to suppress
      ;; their normal character-quote syntax.
      (when (re-search-forward (concat "\\(\\\\*\\)\\(\"" hashes "\\)") end t)
        (put-text-property (match-beginning 1) (match-end 1)
                           'syntax-table (string-to-syntax "_"))
        (put-text-property (1- (match-end 2)) (match-end 2)
                           'syntax-table (string-to-syntax "|"))
        (goto-char (match-end 0))))))

(defun rust-syntax-propertize (start end)
  "A `syntax-propertize-function' to apply properties from START to END."
  ;; Cache all macro scopes as an optimization. See issue #208
  (let ((rust-macro-scopes (rust-macro-scope start end)))
    (goto-char start)
    (let ((str-start (rust-in-str-or-cmnt)))
      (when str-start
        (rust--syntax-propertize-raw-string str-start end)))
    (funcall
     (syntax-propertize-rules
      ;; Character literals.
      (rust--char-literal-rx (1 "\"") (2 "\""))
      ;; Raw strings.
      ("\\(r\\)#*\""
       (0 (ignore
           (goto-char (match-end 0))
           (unless (save-excursion (nth 8 (syntax-ppss (match-beginning 0))))
             (put-text-property (match-beginning 1) (match-end 1)
                                'syntax-table (string-to-syntax "|"))
             (rust--syntax-propertize-raw-string (match-beginning 0) end)))))
      ("[<>]"
       (0 (ignore
           (when (save-match-data
                   (save-excursion
                     (goto-char (match-beginning 0))
                     (rust-ordinary-lt-gt-p)))
             (put-text-property (match-beginning 0) (match-end 0)
                                'syntax-table (string-to-syntax "."))
             (goto-char (match-end 0)))))))
     (point) end)))

(defun rust-fill-prefix-for-comment-start (line-start)
  "Determine what to use for `fill-prefix' based on the text at LINE-START."
  (let ((result
         ;; Replace /* with same number of spaces
         (replace-regexp-in-string
          "\\(?:/\\*+?\\)[!*]?"
          (lambda (s)
            ;; We want the * to line up with the first * of the
            ;; comment start
            (let ((offset (if (eq t
                                  (compare-strings "/*" nil nil
                                                   s
                                                   (- (length s) 2)
                                                   (length s)))
                              1 2)))
              (concat (make-string (- (length s) offset)
                                   ?\x20) "*")))
          line-start)))
    ;; Make sure we've got at least one space at the end
    (if (not (= (aref result (- (length result) 1)) ?\x20))
        (setq result (concat result " ")))
    result))

(defun rust-in-comment-paragraph (body)
  ;; We might move the point to fill the next comment, but we don't want it
  ;; seeming to jump around on the user
  (save-excursion
    ;; If we're outside of a comment, with only whitespace and then a comment
    ;; in front, jump to the comment and prepare to fill it.
    (when (not (nth 4 (syntax-ppss)))
      (beginning-of-line)
      (when (looking-at (concat "[[:space:]\n]*" comment-start-skip))
        (goto-char (match-end 0))))

    ;; We need this when we're moving the point around and then checking syntax
    ;; while doing paragraph fills, because the cache it uses isn't always
    ;; invalidated during this.
    (syntax-ppss-flush-cache 1)
    ;; If we're at the beginning of a comment paragraph with nothing but
    ;; whitespace til the next line, jump to the next line so that we use the
    ;; existing prefix to figure out what the new prefix should be, rather than
    ;; inferring it from the comment start.
    (let ((next-bol (line-beginning-position 2)))
      (while (save-excursion
               (end-of-line)
               (syntax-ppss-flush-cache 1)
               (and (nth 4 (syntax-ppss))
                    (save-excursion
                      (beginning-of-line)
                      (looking-at paragraph-start))
                    (looking-at "[[:space:]]*$")
                    (nth 4 (syntax-ppss next-bol))))
        (goto-char next-bol)))

    (syntax-ppss-flush-cache 1)
    ;; If we're on the last line of a multiline-style comment that started
    ;; above, back up one line so we don't mistake the * of the */ that ends
    ;; the comment for a prefix.
    (when (save-excursion
            (and (nth 4 (syntax-ppss (line-beginning-position 1)))
                 (looking-at "[[:space:]]*\\*/")))
      (goto-char (line-end-position 0)))
    (funcall body)))

(defun rust-with-comment-fill-prefix (body)
  (let*
      ((line-string (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position)))
       (line-comment-start
        (when (nth 4 (syntax-ppss))
          (cond
           ;; If we're inside the comment and see a * prefix, use it
           ((string-match "^\\([[:space:]]*\\*+[[:space:]]*\\)"
                          line-string)
            (match-string 1 line-string))
           ;; If we're at the start of a comment, figure out what prefix
           ;; to use for the subsequent lines after it
           ((string-match (concat "[[:space:]]*" comment-start-skip) line-string)
            (rust-fill-prefix-for-comment-start
             (match-string 0 line-string))))))
       (fill-prefix
        (or line-comment-start
            fill-prefix)))
    (funcall body)))

(defun rust-find-fill-prefix ()
  (rust-in-comment-paragraph
   (lambda ()
     (rust-with-comment-fill-prefix
      (lambda ()
        fill-prefix)))))

(defun rust-fill-paragraph (&rest args)
  "Special wrapping for `fill-paragraph'.
This handles multi-line comments with a * prefix on each line."
  (rust-in-comment-paragraph
   (lambda ()
     (rust-with-comment-fill-prefix
      (lambda ()
        (let
            ((fill-paragraph-function
              (if (not (eq fill-paragraph-function 'rust-fill-paragraph))
                  fill-paragraph-function))
             (fill-paragraph-handle-comment t))
          (apply 'fill-paragraph args)
          t))))))

(defun rust-do-auto-fill (&rest args)
  "Special wrapping for `do-auto-fill'.
This handles multi-line comments with a * prefix on each line."
  (rust-with-comment-fill-prefix
   (lambda ()
     (apply 'do-auto-fill args)
     t)))

(defun rust-fill-forward-paragraph (arg)
  ;; This is to work around some funny behavior when a paragraph separator is
  ;; at the very top of the file and there is a fill prefix.
  (let ((fill-prefix nil)) (forward-paragraph arg)))

(defun rust-comment-indent-new-line (&optional arg)
  (rust-with-comment-fill-prefix
   (lambda () (comment-indent-new-line arg))))

;;; Imenu support

(defvar rust-imenu-generic-expression
  (append (mapcar #'(lambda (x)
                      (list (capitalize x) (rust-re-item-def-imenu x) 1))
                  '("enum" "struct" "union" "type" "mod" "fn" "trait" "impl"))
          `(("Macro" ,(rust-re-item-def-imenu "macro_rules!") 1)))
  "Value for `imenu-generic-expression' in Rust mode.

Create a hierarchical index of the item definitions in a Rust file.

Imenu will show all the enums, structs, etc. in their own subheading.
Use idomenu (imenu with `ido-mode') for best mileage.")

;;; Defun Motions

(defun rust-beginning-of-defun (&optional arg)
  "Move backward to the beginning of the current defun.

With ARG, move backward multiple defuns.  Negative ARG means
move forward.

This is written mainly to be used as `beginning-of-defun-function' for Rust.
Don't move to the beginning of the line. `beginning-of-defun',
which calls this, does that afterwards."
  (interactive "p")
  (let* ((arg (or arg 1))
         (magnitude (abs arg))
         (sign (if (< arg 0) -1 1)))
    ;; If moving forward, don't find the defun we might currently be
    ;; on.
    (when (< sign 0)
      (end-of-line))
    (catch 'done
      (dotimes (_ magnitude)
        ;; Search until we find a match that is not in a string or comment.
        (while (if (re-search-backward (concat "^\\(" rust-top-item-beg-re "\\)")
                                       nil 'move sign)
                   (rust-in-str-or-cmnt)
                 ;; Did not find it.
                 (throw 'done nil)))))
    t))

(defun rust-end-of-defun ()
  "Move forward to the next end of defun.

With argument, do it that many times.
Negative argument -N means move back to Nth preceding end of defun.

Assume that this is called after `beginning-of-defun'.  So point is
at the beginning of the defun body.

This is written mainly to be used as `end-of-defun-function' for Rust."
  (interactive)
  ;; Find the opening brace
  (if (re-search-forward "[{]" nil t)
      (progn
        (goto-char (match-beginning 0))
        ;; Go to the closing brace
        (condition-case nil
            (forward-sexp)
          (scan-error
           ;; The parentheses are unbalanced; instead of being unable
           ;; to fontify, just jump to the end of the buffer
           (goto-char (point-max)))))
    ;; There is no opening brace, so consider the whole buffer to be one "defun"
    (goto-char (point-max))))

(defun rust-end-of-string ()
  "Skip to the end of the current string."
  (save-excursion
    (skip-syntax-forward "^\"|")
    (skip-syntax-forward "\"|")
    (point)))

;; Formatting using rustfmt
(defconst rust-rustfmt-buffername "*rustfmt*")

(defun rust--format-call (buf)
  "Format BUF using rustfmt."
  (with-current-buffer (get-buffer-create rust-rustfmt-buffername)
    (view-mode +1)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert-buffer-substring buf)
      (let* ((tmpf (make-temp-file "rustfmt"))
             (ret (apply 'call-process-region
                         (point-min)
                         (point-max)
                         rust-rustfmt-bin
                         t
                         `(t ,tmpf)
                         nil
                         rust-rustfmt-switches)))
        (unwind-protect
            (cond
             ((zerop ret)
              (if (not (string= (buffer-string)
                                (with-current-buffer buf (buffer-string))))
                  ;; replace-buffer-contents was in emacs 26.1, but it
                  ;; was broken for non-ASCII strings, so we need 26.2.
                  (if (and (fboundp 'replace-buffer-contents)
                           (version<= "26.2" emacs-version))
                      (with-current-buffer buf
                        (replace-buffer-contents rust-rustfmt-buffername))
                    (copy-to-buffer buf (point-min) (point-max))))
              (kill-buffer))
             ((= ret 3)
              (if (not (string= (buffer-string)
                                (with-current-buffer buf (buffer-string))))
                  (copy-to-buffer buf (point-min) (point-max)))
              (erase-buffer)
              (insert-file-contents tmpf)
              (rust--format-fix-rustfmt-buffer (buffer-name buf))
              (error "Rustfmt could not format some lines, see *rustfmt* buffer for details"))
             (t
              (erase-buffer)
              (insert-file-contents tmpf)
              (rust--format-fix-rustfmt-buffer (buffer-name buf))
              (error "Rustfmt failed, see *rustfmt* buffer for details"))))
        (delete-file tmpf)))))

;; Since we run rustfmt through stdin we get <stdin> markers in the
;; output. This replaces them with the buffer name instead.
(defun rust--format-fix-rustfmt-buffer (buffer-name)
  (with-current-buffer (get-buffer rust-rustfmt-buffername)
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (while (re-search-forward "--> <stdin>:" nil t)
        (replace-match (format "--> %s:" buffer-name)))
      (while (re-search-forward "--> stdin:" nil t)
        (replace-match (format "--> %s:" buffer-name))))))

;; If rust-mode has been configured to navigate to source of the error
;; or display it, do so -- and return true. Otherwise return nil to
;; indicate nothing was done.
(defun rust--format-error-handler ()
  (with-current-buffer (get-buffer rust-rustfmt-buffername)
    (when (string= (string-trim (buffer-string))
                   "Unrecognized option: 'edition'")
      (warn "rustfmt is likely out of date and its version is not supported")))
  (let ((ok nil))
    (when rust-format-show-buffer
      (display-buffer (get-buffer rust-rustfmt-buffername))
      (setq ok t))
    (when rust-format-goto-problem
      (rust-goto-format-problem)
      (setq ok t))
    ok))

(defun rust-goto-format-problem ()
  "Jumps to problem reported by rustfmt, if any.

In case of multiple problems cycles through them. Displays the
rustfmt complain in the echo area."
  (interactive)
  ;; This uses position in *rustfmt* buffer to know which is the next
  ;; error to jump to, and source: line in the buffer to figure which
  ;; buffer it is from.
  (let ((rustfmt (get-buffer rust-rustfmt-buffername)))
    (if (not rustfmt)
        (message "No *rustfmt*, no problems.")
      (let ((target-buffer (with-current-buffer rustfmt
                             (save-excursion
                               (goto-char (point-min))
                               (when (re-search-forward "--> \\([^:]+\\):" nil t)
                                 (match-string 1)))))
            (target-point (with-current-buffer rustfmt
                            ;; No save-excursion, this is how we cycle through!
                            (let ((regex "--> [^:]+:\\([0-9]+\\):\\([0-9]+\\)"))
                              (when (or (re-search-forward regex nil t)
                                        (progn (goto-char (point-min))
                                               (re-search-forward regex nil t)))
                                (cons (string-to-number (match-string 1))
                                      (string-to-number (match-string 2)))))))
            (target-problem (with-current-buffer rustfmt
                              (save-excursion
                                (when (re-search-backward "^error:.+\n" nil t)
                                  (forward-char (length "error: "))
                                  (let ((p0 (point)))
                                    (if (re-search-forward "\nerror:.+\n" nil t)
                                        (buffer-substring p0 (point))
                                      (buffer-substring p0 (point-max)))))))))
        (when (and target-buffer (get-buffer target-buffer) target-point)
          (switch-to-buffer target-buffer)
          (goto-char (point-min))
          (forward-line (1- (car target-point)))
          (forward-char (1- (cdr target-point))))
        (message target-problem)))))

(defconst rust--format-word "\
\\b\\(else\\|enum\\|fn\\|for\\|if\\|let\\|loop\\|\
match\\|struct\\|union\\|unsafe\\|while\\)\\b")
(defconst rust--format-line "\\([\n]\\)")

;; Counts number of matches of regex beginning up to max-beginning,
;; leaving the point at the beginning of the last match.
(defun rust--format-count (regex max-beginning)
  (let ((count 0)
        save-point
        beginning)
    (while (and (< (point) max-beginning)
                (re-search-forward regex max-beginning t))
      (setq count (1+ count))
      (setq beginning (match-beginning 1)))
    ;; try one more in case max-beginning lies in the middle of a match
    (setq save-point (point))
    (when (re-search-forward regex nil t)
      (let ((try-beginning (match-beginning 1)))
        (if (> try-beginning max-beginning)
            (goto-char save-point)
          (setq count (1+ count))
          (setq beginning try-beginning))))
    (when beginning (goto-char beginning))
    count))

;; Gets list describing pos or (point).
;; The list contains:
;; 1. the number of matches of rust--format-word,
;; 2. the number of matches of rust--format-line after that,
;; 3. the number of columns after that.
(defun rust--format-get-loc (buffer &optional pos)
  (with-current-buffer buffer
    (save-excursion
      (let ((pos (or pos (point)))
            words lines columns)
        (goto-char (point-min))
        (setq words (rust--format-count rust--format-word pos))
        (setq lines (rust--format-count rust--format-line pos))
        (if (> lines 0)
            (if (= (point) pos)
                (setq columns -1)
              (forward-char 1)
              (goto-char pos)
              (setq columns (current-column)))
          (let ((initial-column (current-column)))
            (goto-char pos)
            (setq columns (- (current-column) initial-column))))
        (list words lines columns)))))

;; Moves the point forward by count matches of regex up to max-pos,
;; and returns new max-pos making sure final position does not include another match.
(defun rust--format-forward (regex count max-pos)
  (when (< (point) max-pos)
    (let ((beginning (point)))
      (while (> count 0)
        (setq count (1- count))
        (re-search-forward regex nil t)
        (setq beginning (match-beginning 1)))
      (when (re-search-forward regex nil t)
        (setq max-pos (min max-pos (match-beginning 1))))
      (goto-char beginning)))
  max-pos)

;; Gets the position from a location list obtained using rust--format-get-loc.
(defun rust--format-get-pos (buffer loc)
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((max-pos (point-max))
            (words (pop loc))
            (lines (pop loc))
            (columns (pop loc)))
        (setq max-pos (rust--format-forward rust--format-word words max-pos))
        (setq max-pos (rust--format-forward rust--format-line lines max-pos))
        (when (> lines 0) (forward-char))
        (let ((initial-column (current-column))
              (save-point (point)))
          (move-end-of-line nil)
          (when (> (current-column) (+ initial-column columns))
            (goto-char save-point)
            (forward-char columns)))
        (min (point) max-pos)))))

(defun rust-format-diff-buffer ()
  "Show diff to current buffer from rustfmt.

Return the created process."
  (interactive)
  (unless (executable-find rust-rustfmt-bin)
    (error "Could not locate executable \%s\"" rust-rustfmt-bin))
  (let* ((buffer
          (with-current-buffer
              (get-buffer-create "*rustfmt-diff*")
            (let ((inhibit-read-only t))
              (erase-buffer))
            (current-buffer)))
         (proc
          (apply 'start-process
                 "rustfmt-diff"
                 buffer
                 rust-rustfmt-bin
                 "--check"
                 (cons (buffer-file-name)
                       rust-rustfmt-switches))))
    (set-process-sentinel proc 'rust-format-diff-buffer-sentinel)
    proc))

(defun rust-format-diff-buffer-sentinel (process _e)
  (when (eq 'exit (process-status process))
    (if (> (process-exit-status process) 0)
        (with-current-buffer "*rustfmt-diff*"
          (let ((inhibit-read-only t))
            (diff-mode))
          (pop-to-buffer (current-buffer)))
      (message "rustfmt check passed."))))

(defun rust--format-buffer-using-replace-buffer-contents ()
  (condition-case err
      (progn
        (rust--format-call (current-buffer))
        (message "Formatted buffer with rustfmt."))
    (error
     (or (rust--format-error-handler)
         (signal (car err) (cdr err))))))

(defun rust--format-buffer-saving-position-manually ()
  (let* ((current (current-buffer))
         (base (or (buffer-base-buffer current) current))
         buffer-loc
         window-loc)
    (dolist (buffer (buffer-list))
      (when (or (eq buffer base)
                (eq (buffer-base-buffer buffer) base))
        (push (list buffer
                    (rust--format-get-loc buffer nil))
              buffer-loc)))
    (dolist (frame (frame-list))
      (dolist (window (window-list frame))
        (let ((buffer (window-buffer window)))
          (when (or (eq buffer base)
                    (eq (buffer-base-buffer buffer) base))
            (let ((start (window-start window))
                  (point (window-point window)))
              (push (list window
                          (rust--format-get-loc buffer start)
                          (rust--format-get-loc buffer point))
                    window-loc))))))
    (condition-case err
        (unwind-protect
            ;; save and restore window start position
            ;; after reformatting
            ;; to avoid the disturbing scrolling
            (let ((w-start (window-start)))
              (rust--format-call (current-buffer))
              (set-window-start (selected-window) w-start)
              (message "Formatted buffer with rustfmt."))
          (dolist (loc buffer-loc)
            (let* ((buffer (pop loc))
                   (pos (rust--format-get-pos buffer (pop loc))))
              (with-current-buffer buffer
                (goto-char pos))))
          (dolist (loc window-loc)
            (let* ((window (pop loc))
                   (buffer (window-buffer window))
                   (start (rust--format-get-pos buffer (pop loc)))
                   (pos (rust--format-get-pos buffer (pop loc))))
              (unless (eq buffer current)
                (set-window-start window start))
              (set-window-point window pos))))
      (error
       (or (rust--format-error-handler)
           (signal (car err) (cdr err)))))))

(defun rust-format-buffer ()
  "Format the current buffer using rustfmt."
  (interactive)
  (unless (executable-find rust-rustfmt-bin)
    (error "Could not locate executable \"%s\"" rust-rustfmt-bin))
  ;; If emacs version >= 26.2, we can use replace-buffer-contents to
  ;; preserve location and markers in buffer, otherwise we can try to
  ;; save locations as best we can, though we still lose markers.
  (if (version<= "26.2" emacs-version)
      (rust--format-buffer-using-replace-buffer-contents)
    (rust--format-buffer-saving-position-manually)))

(defun rust-enable-format-on-save ()
  "Enable formatting using rustfmt when saving buffer."
  (interactive)
  (setq-local rust-format-on-save t))

(defun rust-disable-format-on-save ()
  "Disable formatting using rustfmt when saving buffer."
  (interactive)
  (setq-local rust-format-on-save nil))

(defun rust-compile ()
  "Compile using `cargo build`"
  (interactive)
  (compile (format "%s build" rust-cargo-bin)))

(defun rust-run ()
  "Run using `cargo run`"
  (interactive)
  (compile (format "%s run" rust-cargo-bin)))

(defun rust-test ()
  "Test using `cargo test`"
  (interactive)
  (compile (format "%s test" rust-cargo-bin)))

(defvar rust-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-f") 'rust-format-buffer)
    (define-key map (kbd "C-c C-d") 'rust-dbg-wrap-or-unwrap)
    (define-key map (kbd "C-c C-n") 'rust-goto-format-problem)
    map)
  "Keymap for Rust major mode.")

;;;###autoload
(define-derived-mode rust-mode prog-mode "Rust"
  "Major mode for Rust code.

\\{rust-mode-map}"
  :group 'rust-mode
  :syntax-table rust-mode-syntax-table

  ;; Syntax.
  (setq-local syntax-propertize-function #'rust-syntax-propertize)

  ;; Indentation
  (setq-local indent-line-function 'rust-mode-indent-line)

  ;; Fonts
  (setq-local font-lock-defaults '(rust-mode-font-lock-keywords
                                   nil nil nil nil
                                   (font-lock-syntactic-face-function
                                    . rust-mode-syntactic-face-function)))

  ;; Misc
  (setq-local comment-start "// ")
  (setq-local comment-end   "")
  (setq-local open-paren-in-column-0-is-defun-start nil)

  ;; Auto indent on }
  (setq-local
   electric-indent-chars (cons ?} (and (boundp 'electric-indent-chars)
                                       electric-indent-chars)))

  ;; Allow paragraph fills for comments
  (setq-local comment-start-skip "\\(?://[/!]*\\|/\\*[*!]?\\)[[:space:]]*")
  (setq-local paragraph-start
              (concat "[[:space:]]*\\(?:" comment-start-skip "\\|\\*/?[[:space:]]*\\|\\)$"))
  (setq-local paragraph-separate paragraph-start)
  (setq-local normal-auto-fill-function 'rust-do-auto-fill)
  (setq-local fill-paragraph-function 'rust-fill-paragraph)
  (setq-local fill-forward-paragraph-function 'rust-fill-forward-paragraph)
  (setq-local adaptive-fill-function 'rust-find-fill-prefix)
  (setq-local adaptive-fill-first-line-regexp "")
  (setq-local comment-multi-line t)
  (setq-local comment-line-break-function 'rust-comment-indent-new-line)
  (setq-local imenu-generic-expression rust-imenu-generic-expression)
  (setq-local imenu-syntax-alist '((?! . "w"))) ; For macro_rules!
  (setq-local beginning-of-defun-function 'rust-beginning-of-defun)
  (setq-local end-of-defun-function 'rust-end-of-defun)
  (setq-local parse-sexp-lookup-properties t)
  (setq-local electric-pair-inhibit-predicate 'rust-electric-pair-inhibit-predicate-wrap)
  (setq-local electric-pair-skip-self 'rust-electric-pair-skip-self-wrap)

  (add-hook 'before-save-hook 'rust-before-save-hook nil t)
  (add-hook 'after-save-hook 'rust-after-save-hook nil t)

  (setq-local rust-buffer-project nil)

  (when rust-always-locate-project-on-open
    (rust-update-buffer-project)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-mode))

(defun rust-mode-reload ()
  (interactive)
  (unload-feature 'rust-mode)
  (require 'rust-mode)
  (rust-mode))

(defun rust-before-save-hook ()
  (when rust-format-on-save
    (condition-case e
        (rust-format-buffer)
      (error (format "rust-before-save-hook: %S %S"
                     (car e)
                     (cdr e))))))

(defun rust-after-save-hook ()
  (when rust-format-on-save
    (if (not (executable-find rust-rustfmt-bin))
        (error "Could not locate executable \"%s\"" rust-rustfmt-bin)
      (when (get-buffer rust-rustfmt-buffername)
        ;; KLDUGE: re-run the error handlers -- otherwise message area
        ;; would show "Wrote ..." instead of the error description.
        (or (rust--format-error-handler)
            (message "rustfmt detected problems, see *rustfmt* for more."))))))

(defvar rustc-compilation-regexps
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col "\\([0-9]+\\)"))
    (let ((re (concat "^\\(?:error\\|\\(warning\\)\\|\\(note\\)\\)[^\0]+?--> \\("
                      file ":" start-line ":" start-col "\\)")))
      (cons re '(4 5 6 (1 . 2) 3))))
  "Specifications for matching errors in rustc invocations.
See `compilation-error-regexp-alist' for help on their format.")

(defvar rustc-colon-compilation-regexps
  (let ((file "\\([^\n]+\\)")
        (start-line "\\([0-9]+\\)")
        (start-col  "\\([0-9]+\\)"))
    (let ((re (concat "^ *::: " file ":" start-line ":" start-col ; ::: foo/bar.rs
                      )))
      (cons re '(1 2 3 0)))) ;; 0 for info type
  "Specifications for matching `:::` hints in rustc invocations.
See `compilation-error-regexp-alist' for help on their format.")

;; Match test run failures and panics during compilation as
;; compilation warnings
(defvar cargo-compilation-regexps
  '("^\\s-+thread '[^']+' panicked at \\('[^']+', \\([^:]+\\):\\([0-9]+\\)\\)"
    2 3 nil nil 1)
  "Specifications for matching panics in cargo test invocations.
See `compilation-error-regexp-alist' for help on their format.")

(defun rustc-scroll-down-after-next-error ()
  "In the new style error messages, the regular expression
matches on the file name (which appears after `-->`), but the
start of the error appears a few lines earlier.  This hook runs
after `next-error' (\\[next-error]); it simply scrolls down a few lines in
the compilation window until the top of the error is visible."
  (save-selected-window
    (when (eq major-mode 'rust-mode)
      (select-window (get-buffer-window next-error-last-buffer 'visible))
      (when (save-excursion
              (beginning-of-line)
              (looking-at " *-->"))
        (let ((start-of-error
               (save-excursion
                 (beginning-of-line)
                 (while (not (looking-at "^[a-z]+:\\|^[a-z]+\\[E[0-9]+\\]:"))
                   (forward-line -1))
                 (point))))
          (set-window-start (selected-window) start-of-error))))))

(eval-after-load 'compile
  '(progn
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'rustc rustc-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'rustc)
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'rustc-colon rustc-colon-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'rustc-colon)
     (add-to-list 'compilation-error-regexp-alist-alist
                  (cons 'cargo cargo-compilation-regexps))
     (add-to-list 'compilation-error-regexp-alist 'cargo)
     (add-hook 'next-error-hook 'rustc-scroll-down-after-next-error)))

;;; Functions to submit (parts of) buffers to the rust playpen, for sharing.

(defun rust-playpen-region (begin end)
  "Create a shareable URL for the region from BEGIN to END on the Rust playpen."
  (interactive "r")
  (let* ((data (buffer-substring begin end))
         (escaped-data (url-hexify-string data))
         (escaped-playpen-url (url-hexify-string
                               (format rust-playpen-url-format escaped-data))))
    (if (> (length escaped-playpen-url) 5000)
        (error "encoded playpen data exceeds 5000 character limit (length %s)"
               (length escaped-playpen-url))
      (let ((shortener-url (format rust-shortener-url-format escaped-playpen-url))
            (url-request-method "POST"))
        (url-retrieve shortener-url
                      (lambda (state)
                        ;; filter out the headers etc. included at the
                        ;; start of the buffer: the relevant text
                        ;; (shortened url or error message) is exactly
                        ;; the last line.
                        (goto-char (point-max))
                        (let ((last-line (thing-at-point 'line t))
                              (err (plist-get state :error)))
                          (kill-buffer)
                          (if err
                              (error "failed to shorten playpen url: %s" last-line)
                            (message "%s" last-line)))))))))

(defun rust-playpen-buffer ()
  "Create a shareable URL for the contents of the buffer on the Rust playpen."
  (interactive)
  (rust-playpen-region (point-min) (point-max)))

(defun rust-promote-module-into-dir ()
  "Promote the module file visited by the current buffer into its own directory.

For example, if the current buffer is visiting the file `foo.rs',
then this function creates the directory `foo' and renames the
file to `foo/mod.rs'.  The current buffer will be updated to
visit the new file."
  (interactive)
  (let ((filename (buffer-file-name)))
    (if (not filename)
        (message "Buffer is not visiting a file.")
      (if (string-equal (file-name-nondirectory filename) "mod.rs")
          (message "Won't promote a module file already named mod.rs.")
        (let* ((basename (file-name-sans-extension
                          (file-name-nondirectory filename)))
               (mod-dir (file-name-as-directory
                         (concat (file-name-directory filename) basename)))
               (new-name (concat mod-dir "mod.rs")))
          (mkdir mod-dir t)
          (rename-file filename new-name 1)
          (set-visited-file-name new-name))))))

(defun rust-run-clippy ()
  "Run `cargo clippy'."
  (interactive)
  (when (null rust-buffer-project)
    (rust-update-buffer-project))
  (let* ((args (list rust-cargo-bin "clippy"
                     (concat "--manifest-path=" rust-buffer-project)))
         ;; set `compile-command' temporarily so `compile' doesn't
         ;; clobber the existing value
         (compile-command (mapconcat #'shell-quote-argument args " ")))
    (compile compile-command)))

(defun rust-update-buffer-project ()
  (setq-local rust-buffer-project (rust-buffer-project)))

(defun rust-buffer-project ()
  "Get project root if possible."
  (with-temp-buffer
    (let ((ret (call-process rust-cargo-bin nil t nil "locate-project")))
      (when (/= ret 0)
        (error "`cargo locate-project' returned %s status: %s" ret (buffer-string)))
      (goto-char 0)
      (let ((output (json-read)))
        (cdr (assoc-string "root" output))))))

(defun rust-insert-dbg ()
  "Insert the dbg! macro."
  (cond ((region-active-p)
         (when (< (mark) (point))
           (exchange-point-and-mark))
         (let ((old-point (point)))
           (insert-parentheses)
           (goto-char old-point)))
        (t
         (when (rust-in-str)
           (up-list -1 t t))
         (insert "(")
         (forward-sexp)
         (insert ")")
         (backward-sexp)))
  (insert "dbg!"))

;;;###autoload
(defun rust-dbg-wrap-or-unwrap ()
  "Either remove or add the dbg! macro."
  (interactive)
  (save-excursion
    (if (region-active-p)
        (rust-insert-dbg)

      (let ((beginning-of-symbol (ignore-errors (beginning-of-thing 'symbol))))
        (when beginning-of-symbol
          (goto-char beginning-of-symbol)))

      (let ((dbg-point (save-excursion
                         (or (and (looking-at-p "dbg!") (+ 4 (point)))
                             (ignore-errors
                               (while (not (rust-looking-back-str "dbg!"))
                                 (backward-up-list))
                               (point))))))
        (cond (dbg-point
               (goto-char dbg-point)
               (delete-char -4)
               (delete-pair))
              (t (rust-insert-dbg)))))))

(provide 'rust-mode)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; rust-mode.el ends here
