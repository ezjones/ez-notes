;;; ez-notes.el --- Minimal note management for Org notes -*- lexical-binding: t; -*-

;; Author: Ez Jones
;; Version: 0.31
;; Keywords: notes, org, convenience

;;; Commentary:
;;
;; Minimalist org-roam style note management for Org notes in a directory.
;; - List notes by #+title: (ignores filename timestamps)
;; - Insert links to notes by title
;; - Create new note from region, insert link
;; - Open notes by title
;;
;; No dependencies, just vanilla Emacs Lisp v29 and Org.

;;; Code:

(defgroup ez-notes nil
  "Minimal note management for Org notes."
  :group 'convenience)

(defcustom ez-notes-directory (expand-file-name "~/org/notes/")
  "Directory where your Org notes are stored."
  :type 'directory)

(defcustom ez-notes-use-sqlite (and (>= emacs-major-version 29) (functionp 'sqlite-open))
  "Use SQLite backend for better performance (requires Emacs 29+)."
  :type 'boolean)

(defvar ez-notes--db nil
  "SQLite database connection for note metadata.")

(defvar ez-notes--cache (make-hash-table :test 'equal)
  "Fallback hashtable cache for note metadata.")

(defvar ez-notes--cache-file nil
  "Cache file path for hashtable fallback.")

(defun ez-notes--db-file ()
  "Return path to SQLite database file."
  (expand-file-name ".ez-notes.db" ez-notes-directory))

(defun ez-notes--cache-file-path ()
  "Return path to cache file for hashtable fallback."
  (or ez-notes--cache-file
      (setq ez-notes--cache-file
            (expand-file-name ".ez-notes-cache.el" ez-notes-directory))))

(defun ez-notes--init-db ()
  "Initialize SQLite database with schema."
  (when ez-notes-use-sqlite
    (unless ez-notes--db
      (make-directory ez-notes-directory t)
      (setq ez-notes--db (sqlite-open (ez-notes--db-file)))
      (sqlite-execute ez-notes--db "
        CREATE TABLE IF NOT EXISTS notes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          file_path TEXT NOT NULL,
          mtime REAL NOT NULL,
          tags TEXT,
          created REAL DEFAULT (julianday('now')),
          heading_level INTEGER DEFAULT 0,
          char_position INTEGER,
          is_file_entry BOOLEAN DEFAULT 1
        )")
      (ez-notes--migrate-schema)
      (sqlite-execute ez-notes--db "
        CREATE INDEX IF NOT EXISTS idx_notes_title ON notes(title)")
      (sqlite-execute ez-notes--db "
        CREATE INDEX IF NOT EXISTS idx_notes_mtime ON notes(mtime)")
      (sqlite-execute ez-notes--db "
        CREATE INDEX IF NOT EXISTS idx_notes_tags ON notes(tags)")
      (sqlite-execute ez-notes--db "
        CREATE INDEX IF NOT EXISTS idx_notes_file_path ON notes(file_path)")
      (sqlite-execute ez-notes--db "
        CREATE INDEX IF NOT EXISTS idx_notes_is_file_entry ON notes(is_file_entry)"))))

(defun ez-notes--migrate-schema ()
  "Migrate existing database schema to support headings."
  (when ez-notes-use-sqlite
    ;; Check if we need to migrate by seeing if new columns exist
    (condition-case nil
        (sqlite-select ez-notes--db "SELECT heading_level FROM notes LIMIT 1")
      (error
       ;; Columns don't exist, need to migrate
       (message "ez-notes: Migrating database schema...")

       ;; Add new columns with default values
       (sqlite-execute ez-notes--db "ALTER TABLE notes ADD COLUMN heading_level INTEGER DEFAULT 0")
       (sqlite-execute ez-notes--db "ALTER TABLE notes ADD COLUMN char_position INTEGER")
       (sqlite-execute ez-notes--db "ALTER TABLE notes ADD COLUMN is_file_entry BOOLEAN DEFAULT 1")

       ;; Update existing entries to be file entries
       (sqlite-execute ez-notes--db "UPDATE notes SET heading_level = 0, char_position = 1, is_file_entry = 1")

       ;; Remove the UNIQUE constraint on file_path by recreating the table
       (sqlite-execute ez-notes--db "
         CREATE TABLE notes_new (
           id TEXT PRIMARY KEY,
           title TEXT NOT NULL,
           file_path TEXT NOT NULL,
           mtime REAL NOT NULL,
           tags TEXT,
           created REAL DEFAULT (julianday('now')),
           heading_level INTEGER DEFAULT 0,
           char_position INTEGER,
           is_file_entry BOOLEAN DEFAULT 1
         )")

       ;; Copy data from old table
       (sqlite-execute ez-notes--db "
         INSERT INTO notes_new (id, title, file_path, mtime, tags, created, heading_level, char_position, is_file_entry)
         SELECT id, title, file_path, mtime, tags, created, heading_level, char_position, is_file_entry FROM notes")

       ;; Drop old table and rename new one
       (sqlite-execute ez-notes--db "DROP TABLE notes")
       (sqlite-execute ez-notes--db "ALTER TABLE notes_new RENAME TO notes")

       (message "ez-notes: Database migration complete")))))

(defun ez-notes--close-db ()
  "Close SQLite database connection."
  (when ez-notes--db
    (sqlite-close ez-notes--db)
    (setq ez-notes--db nil)))

(defun ez-notes--force-reconnect ()
  "Force close and reopen database connection to fix locking issues."
  (interactive)
  (when ez-notes-use-sqlite
    (ez-notes--close-db)
    (ez-notes--init-db)
    (message "ez-notes: Database reconnected")))

(defun ez-notes--test-db-writability ()
  "Test if database is writable. Returns t if writable, nil otherwise."
  (when ez-notes-use-sqlite
    (condition-case err
        (progn
          (ez-notes--init-db)
          (sqlite-execute ez-notes--db "CREATE TEMP TABLE IF NOT EXISTS write_test (id INTEGER)")
          (sqlite-execute ez-notes--db "INSERT INTO write_test (id) VALUES (1)")
          (sqlite-execute ez-notes--db "DELETE FROM write_test WHERE id = 1")
          (sqlite-execute ez-notes--db "DROP TABLE write_test")
          t)
      (error
       (message "ez-notes: Database write test failed: %s" (error-message-string err))
       nil))))

(defun ez-notes--load-cache ()
  "Load hashtable cache from file."
  (unless ez-notes-use-sqlite
    (let ((cache-file (ez-notes--cache-file-path)))
      (when (file-exists-p cache-file)
        (with-temp-buffer
          (insert-file-contents cache-file)
          (goto-char (point-min))
          (condition-case nil
              (setq ez-notes--cache (read (current-buffer)))
            (error (setq ez-notes--cache (make-hash-table :test 'equal))))))
      (unless (hash-table-p ez-notes--cache)
        (setq ez-notes--cache (make-hash-table :test 'equal))))))

(defun ez-notes--save-cache ()
  "Save hashtable cache to file."
  (unless ez-notes-use-sqlite
    (make-directory ez-notes-directory t)
    (with-temp-file (ez-notes--cache-file-path)
      (prin1 ez-notes--cache (current-buffer)))))

(defun ez-notes--get-file-mtime (file)
  "Get modification time of FILE as float."
  (float-time (file-attribute-modification-time (file-attributes file))))

(defun ez-notes--extract-tags (file)
  "Extract tags from FILE's #+tags: or #+filetags: lines."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096) ; read first 4KB
    (goto-char (point-min))
    (let (tags)
      (while (re-search-forward "^#\\+\\(?:file\\)?tags:[ \t]*\\(.*\\)$" nil t)
        (let ((tag-line (string-trim (match-string 1))))
          (when tag-line
            (setq tags (append tags (split-string tag-line "[ \t:]+" t))))))
      (when tags
        (mapconcat #'identity (delete-dups tags) " ")))))

(defun ez-notes--db-insert-or-update (file)
  "Insert or update note metadata for FILE in database."
  (when ez-notes-use-sqlite
    (condition-case err
        (progn
          (ez-notes--init-db)
          ;; Test writability before proceeding
          (unless (ez-notes--test-db-writability)
            (ez-notes--force-reconnect)
            (unless (ez-notes--test-db-writability)
              (error "Database is readonly after reconnection attempt")))

          (let* ((mtime (ez-notes--get-file-mtime file))
                 (tags (ez-notes--extract-tags file))
                 (headings (ez-notes--extract-all-headings-with-ids file)))
            ;; Use transaction for atomic operations
            (sqlite-execute ez-notes--db "BEGIN TRANSACTION")
            (condition-case transaction-err
                (progn
                  ;; First, remove all existing entries for this file
                  (sqlite-execute ez-notes--db "DELETE FROM notes WHERE file_path = ?" (list file))

                  ;; Then insert all headings with IDs found in the file
                  (dolist (heading headings)
                    (let ((id (plist-get heading :id))
                          (title (plist-get heading :title))
                          (level (plist-get heading :level))
                          (position (plist-get heading :position))
                          (is-file-entry (plist-get heading :is-file-entry)))
                      ;; Use INSERT OR REPLACE to handle ID conflicts gracefully
                      ;; If an ID exists elsewhere, this entry will overwrite it
                      (sqlite-execute ez-notes--db
                                      "INSERT OR REPLACE INTO notes (id, title, file_path, mtime, tags, heading_level, char_position, is_file_entry) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                                      (list id title file mtime tags level position (if is-file-entry 1 0)))))
                  (sqlite-execute ez-notes--db "COMMIT"))
              (error
               (sqlite-execute ez-notes--db "ROLLBACK")
               (signal (car transaction-err) (cdr transaction-err))))))
      (error
       (message "ez-notes: Failed to update database for %s: %s" file (error-message-string err))
       (when (string-match-p "readonly\\|locked" (error-message-string err))
         (message "ez-notes: Try running M-x ez-notes-force-reconnect"))))))

(defun ez-notes--cache-insert-or-update (file)
  "Insert or update note metadata for FILE in hashtable cache."
  (unless ez-notes-use-sqlite
    (let* ((mtime (ez-notes--get-file-mtime file))
           (tags (ez-notes--extract-tags file))
           (headings (ez-notes--extract-all-headings-with-ids file)))
      ;; Store all headings found in the file
      (puthash file (list :headings headings :mtime mtime :tags tags) ez-notes--cache))))

(defun ez-notes--db-get-notes ()
  "Get all notes from database as alist of (title . (file-path . metadata))."
  (when ez-notes-use-sqlite
    (ez-notes--init-db)
    (mapcar (lambda (row)
              (let ((id (nth 0 row))
                    (title (nth 1 row))
                    (file-path (nth 2 row))
                    (heading-level (nth 3 row))
                    (char-position (nth 4 row))
                    (is-file-entry (nth 5 row)))
                (cons title (list :file-path file-path
                                  :id id
                                  :heading-level heading-level
                                  :char-position char-position
                                  :is-file-entry (= is-file-entry 1)))))
            (sqlite-select ez-notes--db "SELECT id, title, file_path, heading_level, char_position, is_file_entry FROM notes ORDER BY title"))))

(defun ez-notes--cache-get-notes ()
  "Get all notes from hashtable cache as alist of (title . (file-path . metadata))."
  (unless ez-notes-use-sqlite
    (ez-notes--load-cache)
    (let (notes)
      (maphash (lambda (file metadata)
                 (let ((headings (plist-get metadata :headings)))
                   (dolist (heading headings)
                     (let ((title (plist-get heading :title))
                           (id (plist-get heading :id))
                           (level (plist-get heading :level))
                           (position (plist-get heading :position))
                           (is-file-entry (plist-get heading :is-file-entry)))
                       (when title
                         (push (cons title (list :file-path file
                                                 :id id
                                                 :heading-level level
                                                 :char-position position
                                                 :is-file-entry is-file-entry)) notes))))))
               ez-notes--cache)
      (sort notes (lambda (a b) (string< (car a) (car b)))))))

(defun ez-notes--db-get-note-by-id (id)
  "Get note by ID from database."
  (when ez-notes-use-sqlite
    (ez-notes--init-db)
    (let ((result (sqlite-select ez-notes--db "SELECT title, file_path FROM notes WHERE id = ?" (list id))))
      (when result
        (let ((row (car result)))
          (cons (car row) (cadr row)))))))

(defun ez-notes--cache-get-note-by-id (id)
  "Get note by ID from hashtable cache."
  (unless ez-notes-use-sqlite
    (ez-notes--load-cache)
    (catch 'found
      (maphash (lambda (file metadata)
                 (let ((headings (plist-get metadata :headings)))
                   (dolist (heading headings)
                     (when (string= id (plist-get heading :id))
                       (throw 'found (cons (plist-get heading :title) file))))))
               ez-notes--cache)
      nil)))

(defun ez-notes--ensure-backend ()
  "Initialize the appropriate backend (SQLite or hashtable cache)."
  (if ez-notes-use-sqlite
      (ez-notes--init-db)
    (ez-notes--load-cache)))

(defun ez-notes--file-needs-update-p (file)
  "Check if FILE needs to be updated in the backend."
  (let ((current-mtime (ez-notes--get-file-mtime file)))
    (if ez-notes-use-sqlite
        (let ((result (sqlite-select ez-notes--db "SELECT mtime FROM notes WHERE file_path = ?" (list file))))
          (if result
              (not (equal current-mtime (car (car result))))
            t)) ; File not in database, needs update
      ;; Hashtable cache
      (let ((metadata (gethash file ez-notes--cache)))
        (if metadata
            (not (equal current-mtime (plist-get metadata :mtime)))
          t))))) ; File not in cache, needs update

(defun ez-notes--remove-file-from-backend (file)
  "Remove FILE from the backend."
  (if ez-notes-use-sqlite
      (condition-case err
          (progn
            (ez-notes--init-db)
            (unless (ez-notes--test-db-writability)
              (ez-notes--force-reconnect))
            (sqlite-execute ez-notes--db "DELETE FROM notes WHERE file_path = ?" (list file)))
        (error
         (message "ez-notes: Failed to remove %s: %s" file (error-message-string err))
         (when (string-match-p "readonly\\|locked" (error-message-string err))
           (message "ez-notes: Try running M-x ez-notes-force-reconnect"))))
    (remhash file ez-notes--cache)))

(defun ez-notes--update-file-in-backend (file)
  "Update FILE in the backend if it needs updating."
  (when (file-exists-p file)
    (if ez-notes-use-sqlite
        (ez-notes--db-insert-or-update file)
      (ez-notes--cache-insert-or-update file))))

(defun ez-notes--scan-for-changes ()
  "Scan directory for changes and update backend incrementally."
  (ez-notes--ensure-backend)
  (let ((current-files (directory-files ez-notes-directory t "\\.org$"))
        (updated-count 0)
        (removed-count 0))

    ;; Update or add changed files
    (dolist (file current-files)
      (when (ez-notes--file-needs-update-p file)
        (ez-notes--update-file-in-backend file)
        (setq updated-count (1+ updated-count))))

    ;; Remove deleted files from backend
    (if ez-notes-use-sqlite
        (let ((db-files (mapcar #'cadr (sqlite-select ez-notes--db "SELECT id, file_path FROM notes"))))
          (dolist (db-file db-files)
            (unless (file-exists-p db-file)
              (ez-notes--remove-file-from-backend db-file)
              (setq removed-count (1+ removed-count)))))
      ;; Hashtable cache
      (let (files-to-remove)
        (maphash (lambda (file _metadata)
                   (unless (file-exists-p file)
                     (push file files-to-remove)))
                 ez-notes--cache)
        (dolist (file files-to-remove)
          (ez-notes--remove-file-from-backend file)
          (setq removed-count (1+ removed-count)))))

    ;; Save cache if using hashtable
    (unless ez-notes-use-sqlite
      (ez-notes--save-cache))

    (when (or (> updated-count 0) (> removed-count 0))
      (message "Updated %d notes, removed %d notes" updated-count removed-count))

    (list updated-count removed-count)))

(defun ez-notes--ensure-up-to-date ()
  "Ensure the backend is up to date by scanning for changes."
  (ez-notes--auto-migrate-if-needed)
  (ez-notes--scan-for-changes))

(defun ez-notes--is-backend-empty-p ()
  "Check if the backend is empty (first run)."
  (if ez-notes-use-sqlite
      (let ((count (sqlite-select ez-notes--db "SELECT COUNT(*) FROM notes")))
        (= (car (car count)) 0))
    (= (hash-table-count ez-notes--cache) 0)))

(defun ez-notes--migrate-all-notes ()
  "Migrate all notes to the backend (initial population)."
  (ez-notes--ensure-backend)
  (let ((org-files (directory-files ez-notes-directory t "\\.org$"))
        (migrated-count 0))
    (message "Migrating %d notes to backend..." (length org-files))
    (dolist (file org-files)
      (when (and (ez-notes--org-title file) (ez-notes--org-id file))
        (ez-notes--update-file-in-backend file)
        (setq migrated-count (1+ migrated-count))))

    ;; Save cache if using hashtable
    (unless ez-notes-use-sqlite
      (ez-notes--save-cache))

    (message "Migration complete: %d notes added to backend" migrated-count)
    migrated-count))

;;;###autoload
(defun ez-notes-rebuild-backend ()
  "Rebuild the entire note backend from scratch.
This scans all notes and rebuilds the database/cache completely."
  (interactive)
  (when (yes-or-no-p "Rebuild entire note backend? This will scan all files. ")
    (if ez-notes-use-sqlite
        (progn
          (ez-notes--close-db)
          (when (file-exists-p (ez-notes--db-file))
            (delete-file (ez-notes--db-file)))
          (ez-notes--init-db))
      ;; Clear hashtable cache
      (setq ez-notes--cache (make-hash-table :test 'equal)))

    (ez-notes--migrate-all-notes)))

(defun ez-notes--auto-migrate-if-needed ()
  "Automatically migrate notes if backend is empty."
  (ez-notes--ensure-backend)
  (when (ez-notes--is-backend-empty-p)
    (let ((org-files (directory-files ez-notes-directory t "\\.org$")))
      (when org-files
        (message "First run detected, populating backend...")
        (ez-notes--migrate-all-notes)))))

(defun ez-notes--org-title (file)
  "Extract #+title: from FILE, or return nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 2048) ; only read first 2KB
    (goto-char (point-min))
    (when (re-search-forward "^#\\+title:[ \t]*\\(.*\\)$" nil t)
      (string-trim (match-string 1)))))

(defun ez-notes--org-id (file)
  "Extract the Org :ID: property from FILE."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (goto-char (point-min))
    (when (re-search-forward "^:ID:[ \t]+\\([0-9a-fA-F-]+\\)" nil t)
      (match-string 1))))

(defun ez-notes--extract-all-headings-with-ids (file)
  "Extract all headings with ID properties from FILE.
Returns a list of alists with keys: :id, :title, :level, :position"
  (with-temp-buffer
    (insert-file-contents-literally file)
    (goto-char (point-min))
    (let (headings seen-ids)
      ;; First, look for file-level ID and title
      (let ((file-id (ez-notes--org-id file))
            (file-title (ez-notes--org-title file)))
        (when (and file-id file-title)
          (push file-id seen-ids)
          (push (list :id file-id
                      :title file-title
                      :level 0
                      :position 1
                      :is-file-entry t) headings)))

      ;; Then scan for headings with their own IDs
      (goto-char (point-min))
      (while (re-search-forward "^\\(\\*+\\)[ \t]*\\(.*\\)" nil t)
        (let ((level (length (match-string 1)))
              (heading-title (string-trim (match-string 2)))
              (heading-start (line-beginning-position)))
          ;; Skip empty titles
          (when (not (string-empty-p heading-title))
            ;; Look for :ID: property in the properties drawer following this heading
            (save-excursion
              (forward-line 1)
              (when (looking-at "^[ \t]*:PROPERTIES:")
                (let ((prop-end (save-excursion
                                  (when (re-search-forward "^[ \t]*:END:" nil t)
                                    (point)))))
                  (when prop-end
                    (when (re-search-forward "^[ \t]*:ID:[ \t]+\\([0-9a-fA-F-]+\\)" prop-end t)
                      (let ((heading-id (match-string 1)))
                        ;; Only add if we haven't seen this ID before in this file
                        (unless (member heading-id seen-ids)
                          (push heading-id seen-ids)
                          (push (list :id heading-id
                                      :title heading-title
                                      :level level
                                      :position heading-start
                                      :is-file-entry nil) headings)))))))))))
      (nreverse headings))))

(defun ez-notes--list-notes ()
  "Return an alist of (title . path) for all org files in `ez-notes-directory'."
  (ez-notes--ensure-up-to-date)
  (if ez-notes-use-sqlite
      (ez-notes--db-get-notes)
    (ez-notes--cache-get-notes)))

(defun ez-notes--read-note-title ()
  "Prompt for a note title from existing notes. Returns (title . metadata)."
  (let* ((notes (ez-notes--list-notes))
         (titles (mapcar #'car notes))
         (selected (completing-read "Note: " titles nil t)))
    (assoc selected notes)))

(defun ez-notes--insert-link ()
  "Insert an Org ID link to a note."
  (let* ((note (ez-notes--read-note-title))
         (title (car note))
         (metadata (cdr note)))
    (when (and title metadata)
      (let ((id (plist-get metadata :id)))
        (if id
            (insert (format "[[id:%s][%s]]" id title))
          (message "Note '%s' is missing an :ID: property." title))))))

;;;###autoload
(defun ez-notes-find-note ()
  "Open a note by title with completion."
  (interactive)
  (let* ((note (ez-notes--read-note-title)))
    (when note
      (let* ((metadata (cdr note))
             (file-path (plist-get metadata :file-path))
             (char-position (plist-get metadata :char-position))
             (is-file-entry (plist-get metadata :is-file-entry)))
        (find-file file-path)
        ;; If it's a heading (not file entry), jump to the specific position
        (when (and char-position (not is-file-entry))
          (goto-char char-position))))))

(defun ez-notes--slugify (title)
  "Make a filename slug from TITLE."
  (let ((slug (downcase (replace-regexp-in-string "[^a-zA-Z0-9]+" "-" title))))
    (replace-regexp-in-string "-+" "-" (string-trim slug "-"))))

(defun ez-notes--create-from-region (beg end)
  "Move region to a new note, insert a link in its place. Uses Org ID for linking."
  (let* ((region (buffer-substring-no-properties beg end))
         (title (read-string "New note title: " region))
         (slug (ez-notes--slugify title))
         (timestamp (format-time-string "%Y%m%dT%H%M%S"))
         (id (ez-notes--generate-id))
         (filename (expand-file-name (format "%s--%s.org" timestamp slug) ez-notes-directory)))
    (make-directory ez-notes-directory t)
    (with-temp-file filename
      (insert (format ":PROPERTIES:\n:ID:       %s\n:END:\n#+title:      %s\n#+date:       [%s]\n\n%s\n"
                      id title (format-time-string "%Y-%m-%d %H:%M") region)))
    (delete-region beg end)
    (insert (format "[[id:%s][%s]]" id title))
    ;; Update the backend with the new note
    (ez-notes--ensure-backend)
    (ez-notes--update-file-in-backend filename)
    (unless ez-notes-use-sqlite
      (ez-notes--save-cache))
    (message "Note created: %s" filename)))

;;;###autoload
(defun ez-notes-insert-or-create-note ()
  "Create note from region, or insert link to existing note.

If a region is active, first check if a note with the selected text
as title already exists. If it exists, insert a link to it.
If it doesn't exist, create a new note with the selected text.

If no region is active, this prompts to select an existing note
and inserts a link to it."
  (interactive)
  (if (use-region-p)
      (let* ((region-text (buffer-substring-no-properties (region-beginning) (region-end)))
             (title (string-trim region-text))
             (notes (ez-notes--list-notes))
             (existing-note (assoc title notes)))
        (if existing-note
            ;; Note exists, insert link to existing note
            (let* ((metadata (cdr existing-note))
                   (id (plist-get metadata :id)))
              (if id
                  (progn
                    (delete-region (region-beginning) (region-end))
                    (insert (format "[[id:%s][%s]]" id title))
                    (message "Linked to existing note: %s" title))
                (message "Existing note '%s' is missing an :ID: property." title)))
          ;; Note doesn't exist, create new one
          (ez-notes--create-from-region (region-beginning) (region-end))))
    (ez-notes--insert-link)))

;;;###autoload
(defun ez-notes-refresh ()
  "Refresh the note database by scanning for file changes."
  (interactive)
  (let ((result (ez-notes--scan-for-changes)))
    (when result
      (let ((updated (car result))
            (removed (cadr result)))
        (if (> (+ updated removed) 0)
            (message "Backend updated: %d notes updated, %d removed" updated removed)
          (message "Backend is up to date"))))))

;; Keep old function name for backward compatibility
;;;###autoload
(defalias 'ez-notes-update-id-locations 'ez-notes-refresh)

(defun ez-notes--generate-id ()
  "Generate a unique ID for a note."
  (require 'org-id)
  (org-id-new))

(defun ez-notes--find-id-file (id)
  "Find file containing ID using our SQLite backend."
  (ez-notes--ensure-backend)
  (if ez-notes-use-sqlite
      (ez-notes--db-get-note-by-id id)
    (ez-notes--cache-get-note-by-id id)))

(defun ez-notes--org-id-find-id-file (id)
  "Override org-id's file finder to use our SQLite backend."
  (let ((result (ez-notes--find-id-file id)))
    (when result
      (cdr result)))) ; Return just the file path

;; Override org-id's ID resolution
(defun ez-notes--setup-org-id-integration ()
  "Setup integration with org-id to use our backend."
  (when (featurep 'org-id)
    ;; Override the function that finds files by ID
    (advice-add 'org-id-find-id-file :override #'ez-notes--org-id-find-id-file)
    (message "ez-notes: Using SQLite backend for org-id resolution")))

;; Auto-setup when org-id is loaded
(with-eval-after-load 'org-id
  (ez-notes--setup-org-id-integration))

;; Auto-update hooks for better sync
(defun ez-notes--auto-update-on-save ()
  "Update backend when saving org files in notes directory."
  (when (and buffer-file-name
             (string-match-p "\\.org$" buffer-file-name)
             (file-in-directory-p buffer-file-name ez-notes-directory))
    (ez-notes--ensure-backend)
    (ez-notes--update-file-in-backend buffer-file-name)
    (unless ez-notes-use-sqlite
      (ez-notes--save-cache))))

;; Hook to update on file save
(add-hook 'after-save-hook #'ez-notes--auto-update-on-save)

;; Auto-scan on startup (but only if notes directory exists)
(defun ez-notes--startup-scan ()
  "Scan for changes on Emacs startup if notes directory exists."
  (when (file-directory-p ez-notes-directory)
    (ez-notes--ensure-up-to-date)))

;; Run startup scan after init
(add-hook 'emacs-startup-hook #'ez-notes--startup-scan)

;; Optional: Auto-scan periodically (every 5 minutes)
(defvar ez-notes--scan-timer nil "Timer for periodic scanning.")

(defun ez-notes--start-periodic-scan ()
  "Start periodic scanning every 5 minutes."
  (interactive)
  (when ez-notes--scan-timer
    (cancel-timer ez-notes--scan-timer))
  (setq ez-notes--scan-timer
        (run-with-timer 300 300 #'ez-notes--ensure-up-to-date))
  (message "ez-notes: Started periodic scanning every 5 minutes"))

(defun ez-notes--stop-periodic-scan ()
  "Stop periodic scanning."
  (interactive)
  (when ez-notes--scan-timer
    (cancel-timer ez-notes--scan-timer)
    (setq ez-notes--scan-timer nil)
    (message "ez-notes: Stopped periodic scanning")))

;;;###autoload
(defun ez-notes-create-note ()
  "Create a new note with a title prompt."
  (interactive)
  (let* ((title (read-string "New note title: "))
         (slug (ez-notes--slugify title))
         (timestamp (format-time-string "%Y%m%dT%H%M%S"))
         (id (ez-notes--generate-id))
         (filename (expand-file-name (format "%s--%s.org" timestamp slug) ez-notes-directory)))
    (when (not (string-empty-p title))
      (make-directory ez-notes-directory t)
      (with-temp-file filename
        (insert (format ":PROPERTIES:\n:ID:       %s\n:END:\n#+title:      %s\n#+date:       [%s]\n\n"
                        id title (format-time-string "%Y-%m-%d %H:%M"))))
      ;; Update the backend with the new note
      (ez-notes--ensure-backend)
      (ez-notes--update-file-in-backend filename)
      (unless ez-notes-use-sqlite
        (ez-notes--save-cache))
      ;; Open the new note
      (find-file filename)
      (goto-char (point-max))
      (message "Note created: %s" filename))))

;;;###autoload
(defun ez-notes-enable-org-id-integration ()
  "Manually enable org-id integration with ez-notes backend."
  (interactive)
  (require 'org-id)
  (ez-notes--setup-org-id-integration))

;;;###autoload
(defun ez-notes-fix-database ()
  "Fix common database issues (readonly, locked, stale connections).
This function will:
1. Test database writability
2. Force reconnect if needed
3. Suggest fallback to hashtable cache if issues persist"
  (interactive)
  (if ez-notes-use-sqlite
      (progn
        (message "ez-notes: Testing database writability...")
        (if (ez-notes--test-db-writability)
            (message "ez-notes: Database is working correctly")
          (progn
            (message "ez-notes: Database issues detected, attempting to fix...")
            (ez-notes--force-reconnect)
            (if (ez-notes--test-db-writability)
                (message "ez-notes: Database fixed successfully!")
              (message "ez-notes: Could not fix database. Consider switching to hashtable mode with: (setq ez-notes-use-sqlite nil)")))))
    (message "ez-notes: Currently using hashtable cache (SQLite disabled)")))

;;;###autoload
(defun ez-notes-list-notes ()
  "Show a buffer listing all notes by title."
  (interactive)
  (let ((notes (ez-notes--list-notes)))
    (with-current-buffer (get-buffer-create "*EZ Notes*")
      (erase-buffer)
      (dolist (note notes)
        (let* ((title (car note))
               (metadata (cdr note))
               (id (plist-get metadata :id))
               (heading-level (plist-get metadata :heading-level))
               (is-file-entry (plist-get metadata :is-file-entry)))
          (if id
              (let ((prefix (if is-file-entry
                                "- "
                              (concat (make-string (* 2 heading-level) ? ) "- "))))
                (insert (format "%s[[id:%s][%s]]\n" prefix id title)))
            (insert (format "- %s (no ID)\n" title)))))
      (org-mode)
      (goto-char (point-min))
      (pop-to-buffer (current-buffer)))))

;; Keybindings (customize as needed)
;; Suggestion: bind in your init.el, e.g.:
;; (global-set-key (kbd "M-C-\\") #'ez-notes-insert-or-create-note)
;; (global-set-key (kbd "M-\\") #'ez-notes-find-note)
(global-set-key (kbd "C-c n n") #'ez-notes-create-note)
;; (global-set-key (kbd "C-c n L") #'ez-notes-list-notes)
;; (global-set-key (kbd "C-c n u") #'ez-notes-refresh)
;; (global-set-key (kbd "C-c n r") #'ez-notes-rebuild-backend)
;; (global-set-key (kbd "C-c n i") #'ez-notes-enable-org-id-integration)
;; (global-set-key (kbd "C-c n f") #'ez-notes-fix-database)

(provide 'ez-notes)
;;; ez-notes.el ends here
