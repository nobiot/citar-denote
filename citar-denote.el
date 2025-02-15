;;; citar-denote.el --- Creating and accessing bibliography Denote notes with Citar -*- lexical-binding: t -*-

;; Copyright (C) 2022  Peter Prevos

;; Author: Peter Prevos <peter@prevos.net>
;; Maintainer: Peter Prevos <peter@prevos.net>
;; URL: https://github.com/pprevos/denote
;; Version: 0.9
;; Package-Requires: ((emacs "28.2") (citar "1.0") (denote "1.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; citar-denote offers integration of Denote notes with bibliographies
;; using the Citar package.  It provides the following functionality:
;; 1. Link notes to citations with citation-key in the front matter
;; 2. Create new notes linked to citations
;; 3. Access existing notes linked to citations
;;
;; This code would not have existed without the help of others:
;; - Protesilaos Stavrou for creating Denote and encouraging me to write elisp.
;; - Bruce D'Arcus for creating Citar and help creating this package.
;; - Joel Lööw for adding the caching functionality.
;; - Noboru Ota added the ability to use multiple file types.

;;; Code:

(require 'citar)
(require 'denote)

(defgroup citar-denote ()
  "Creating and accessing bibliography files with Citar and Denote."
  :group 'files)

(defcustom citar-denote-keyword "bib"
  "Denote keyword (file tag) to indicate bibliographical notes."
  :group 'citar-denote
  :type '(repeat string))

(defvar citar-denote-file-type (or denote-file-type 'org)
  "File Type used by Citar-Denote.
Default is `denote-file-type' or org if the former is nil.  Users
can use another file type for their bibliographic notes.")

(defvar citar-denote-file-types
  `((org
     :reference-format "#+reference:  %s\n"
     :reference-regex "^#\\+reference\\s-*:")
    (markdown-yaml
     :reference-format "reference:  %s\n"
     :reference-regex "^reference\\s-*:")
    (markdown-toml
     :reference-format "reference  = %s\n"
     :reference-regex "^reference\\s-*=")
    (text
     :reference-format "reference:  %s\n"
     :reference-regex "^reference\\s-*:"))
  "Alist of `denote-file-type' and their format properties.

Each element is of the form (SYMBOL . PROPERTY-LIST).  SYMBOL is
one of those specified in `citar-denote-file-type'.

PROPERTY-LIST is a plist that consists of two elements:

- `:reference-format' front matter identifier for citation key.
- `:reference-regex' Regexp to look for the citekey in a bibliographic notes.")

(defvar citar-denote-files-regexp (concat "_" citar-denote-keyword)
  "Regexp used to look for file names of bibliographic notes.
The default assumes \"_bib\" tag is part of the file name.")

(defconst citar-denote-config
  (list :name "Denote"
        :category 'file
        :items #'citar-denote-get-notes
        :hasitems #'citar-denote-has-notes
        :open #'find-file
        :create #'citar-denote-create-note)
  "Instructing citar to use citar-denote functions.")

(defconst citar-denote-orig-source
  citar-notes-source
  "Store the `citar-notes-source' value prior to enabling citar-denote.")

(defvar citar-notes-source)

(defvar citar-notes-sources)

(defun citar-denote-reference-format (file-type)
  "Return the reference format associated to FILE-TYPE."
  (plist-get
   (alist-get file-type citar-denote-file-types)
   :reference-format))

(defun citar-denote-reference-regex (file-type)
  "Return the reference regex associated to FILE-TYPE."
  (plist-get
   (alist-get file-type citar-denote-file-types)
   :reference-regex))

(defun citar-denote-keywords-prompt ()
  "Prompt for one or more keywords and include `citar-denote-keyword'."
  (let ((choice (append (list citar-denote-keyword)
                        (denote--keywords-crm (denote-keywords)))))
    (if denote-sort-keywords
        (sort choice #'string-lessp)
      choice)))

(defun citar-denote-add-reference (key file-type)
  "Add reference property with KEY in front matter of FILE-TYPE.
It is added after the keywords property if it is present.  If
not, it is added in the first blank line, which can be outside
the front matter depending on FILE-TYPE."
  (goto-char (point-min))
  (if (re-search-forward (denote--keywords-key-regexp file-type) nil t 1)
      ;; find keywords property and move to the next line
      (goto-char (line-beginning-position 2))
    ;; if keywords property is not present, move to the first blank line
    (while (not (eq (char-after) 10)) (forward-line)))
  (insert (format (citar-denote-reference-format citar-denote-file-type) key)))

(defun citar-denote-create-note (key &optional _entry)
  "Create a bibliography note for `KEY' with properties `ENTRY'.
The file type for the note to be created is determined by user
option `denote-file-type'."
  (let ((denote-file-type citar-denote-file-type))
    (denote
     (read-string "Title: " (citar-get-value "title" key))
     (citar-denote-keywords-prompt))
      (citar-denote-add-reference key denote-file-type)))

(defun citar-denote-retrieve-reference-key-value (file file-type)
  "Return cite key value from FILE front matter per FILE-TYPE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward (citar-denote-reference-regex file-type) nil t 1)
      (funcall (denote--title-value-reverse-function file-type)
               (buffer-substring-no-properties (point) (line-end-position))))))

(defun citar-denote-get-notes (&optional keys)
  "Return Denote files associated with the `KEYS' list.
Return a hash table mapping elements of `KEY'` to associated notes.
If `KEYS' is omitted, return notes for all Denote files tagged with
`citar-denote-keyword'."
  (let ((files (make-hash-table :test 'equal)))
    (prog1 files
      (dolist (file (denote-directory-files-matching-regexp
                     citar-denote-files-regexp))
        (let ((key-in-file (citar-denote-retrieve-reference-key-value
                            file (denote-filetype-heuristics file))))
          (if keys (dolist (key keys)
                     (when (string= key key-in-file)
                       (push file (gethash key-in-file files))))
            ;; If optional arg keys are not provided
            (push file (gethash key-in-file files)))))
      (maphash (lambda (key filelist)
                 (puthash key (nreverse filelist) files))
               files))))

(defun citar-denote-has-notes ()
  "Return predicate testing whether entry has associated denote files.
See documentation for `citar-has-notes'."
  (let ((notes (citar-denote-get-notes)))
    (unless (hash-table-empty-p notes)
      (lambda (citekey) (and (gethash citekey notes) t)))))

(defun citar-denote-setup ()
  "Setup `citar-denote-mode'."
  (citar-register-notes-source
   'citar-denote-source citar-denote-config)
  (setq citar-notes-source 'citar-denote-source))

(defun citar-denote-reset ()
  "Reset citar to default values."
  (setq citar-notes-source citar-denote-orig-source)
  (citar-remove-notes-source 'citar-denote))

;;;###autoload
(define-minor-mode citar-denote-mode
  "Toggle `citar-denote-mode'."
  :global t
  :group 'citar
  :lighter " citar-denote"
  (if citar-denote-mode
      (citar-denote-setup)
    (citar-denote-reset)))

(provide 'citar-denote)
;;; citar-denote.el ends here
