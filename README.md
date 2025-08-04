# ez-notes.el 📝

> A minimalist, zero-dependency note management system for Emacs - the lightweight alternative to org-roam

**ez-notes** is a drop-in replacement for org-roam that provides fast, clean note management without external dependencies. Built for users who want the core functionality of org-roam without the complexity.

## ✨ Features

| Feature | ez-notes | org-roam | denote |
|---------|----------|----------|--------|
| **Zero Dependencies** | ✅ | ❌ (requires SQLite, emacsql) | ✅ |
| **Clean Note Titles** | ✅ (no timestamps/underscores) | ✅ | ❌ (shows file structure) |
| **Fast Search** | ✅ (SQLite backend) | ✅ | ❌ (file scanning) |
| **Org-ID Compatible** | ✅ (100% compatible) | ✅ | ❌ (different linking) |
| **Instant Link Creation** | ✅ | ✅ | ✅ |
| **Note from Selection** | ✅ | ✅ | ✅ |
| **Backlinks** | ❌ | ✅ | ❌ |
| **Graph View** | ❌ | ✅ | ❌ |
| **Tags Support** | ✅ | ✅ | ✅ |

### Core Functionality

- ✅ **Create notes** with clean titles and automatic ID generation
- ✅ **Find notes** with fuzzy completion (no filename noise)
- ✅ **Insert links** to existing notes using org-id format
- ✅ **Create from selection** - turn selected text into a new linked note
- ✅ **Fast search** powered by SQLite (Emacs 29+) or hashtable cache
- ✅ **Auto-sync** - notes are indexed automatically on save
- ✅ **Heading support** - link to specific headings within notes
- ✅ **Tag extraction** from `#+tags:` and `#+filetags:`

## 🚀 Installation

### Manual Installation

1. Download `ez-notes.el` and place it in your Emacs load path
2. Add to your init file:

```elisp
(require 'ez-notes)

;; Optional: Set your notes directory (default: ~/org/notes/)
(setq ez-notes-directory "~/my-notes/")

;; Optional: Enable org-id integration for faster link resolution
(ez-notes-enable-org-id-integration)
```

### Package Manager Installation

```elisp
;; Using straight.el
(straight-use-package
 '(ez-notes :type git :host github :repo "ezjones/ez-notes"))

;; Using use-package with straight
(use-package ez-notes
  :straight (:type git :host github :repo "ezjones/ez-notes")
  :custom
  (ez-notes-directory "~/notes/")
  :config
  (ez-notes-enable-org-id-integration))
```

## 📋 Quick Start

### Basic Workflow

| Action | Command | Keybinding (suggested) |
|--------|---------|----------------------|
| Create new note | `ez-notes-create-note` | `C-c n n` |
| Find/open note | `ez-notes-find-note` | `C-c n f` |
| Insert link to note | `ez-notes-insert-or-create-note` | `C-c n l` |
| Create note from selection | Select text → `ez-notes-insert-or-create-note` | `C-c n l` |
| List all notes | `ez-notes-list-notes` | `C-c n L` |
| Refresh database | `ez-notes-refresh` | `C-c n u` |

### Suggested Keybindings

Add these to your init file:

```elisp
(global-set-key (kbd "C-c n n") #'ez-notes-create-note)
(global-set-key (kbd "C-c n f") #'ez-notes-find-note)
(global-set-key (kbd "C-c n l") #'ez-notes-insert-or-create-note)
(global-set-key (kbd "C-c n L") #'ez-notes-list-notes)
(global-set-key (kbd "C-c n u") #'ez-notes-refresh)
```

## 📖 Usage Examples

### Creating Your First Note

1. **Create a new note**:
   ```
   M-x ez-notes-create-note
   Title: My First Note
   ```

   This creates a file like `20241201T143022--my-first-note.org` with:
   ```org
   :PROPERTIES:
   :ID:       a1b2c3d4-e5f6-7890-abcd-ef1234567890
   :END:
   #+title: My First Note
   #+date: [2024-12-01 14:30]

   ```

2. **Find and open notes**:
   ```
   M-x ez-notes-find-note
   Note: My First Note  ← Clean title, no filename clutter!
   ```

### Smart Link Creation

**Scenario 1**: Link to existing note
```org
Select text: "Project Planning"
M-x ez-notes-insert-or-create-note
→ [[id:existing-id][Project Planning]]  ← Links to existing note
```

**Scenario 2**: Create new note from selection
```org
Select text: "New Concept"
M-x ez-notes-insert-or-create-note
→ [[id:new-id][New Concept]]  ← Creates new note with this title
```

### Working with Headings

ez-notes can link to specific headings that have ID properties:

```org
* My Heading
:PROPERTIES:
:ID:       heading-specific-id
:END:

Some content here...
```

When you run `ez-notes-find-note`, you'll see both file-level and heading-level entries for precise navigation.

## ⚙️ Configuration

### Basic Configuration

```elisp
;; Set notes directory
(setq ez-notes-directory "~/org/notes/")

;; Enable SQLite backend (default on Emacs 29+)
(setq ez-notes-use-sqlite t)

;; Disable SQLite, use hashtable cache instead
(setq ez-notes-use-sqlite nil)
```

### Advanced Configuration

```elisp
;; Enable periodic scanning every 5 minutes
(ez-notes-start-periodic-scan)

;; Enable org-id integration for faster link resolution
(ez-notes-enable-org-id-integration)

;; Custom file naming (modify ez-notes--slugify if needed)
;; Default format: YYYYMMDDTHHMMSS--title-slug.org
```

## 🔧 Maintenance Commands

| Task | Command | When to Use |
|------|---------|-------------|
| **Refresh index** | `ez-notes-refresh` | After bulk file changes |
| **Rebuild database** | `ez-notes-rebuild-backend` | Database corruption or major changes |
| **Fix database issues** | `ez-notes-fix-database` | SQLite readonly/lock errors |
| **Force reconnect** | `ez-notes-force-reconnect` | Database connection problems |

## 🔄 Migration from org-roam

ez-notes is designed to work seamlessly with existing org-roam notes:

### ✅ What Works Immediately

- [x] All existing org-id links continue working
- [x] File structure remains unchanged
- [x] Note titles are preserved
- [x] ID properties are fully compatible

### 📋 Migration Checklist

- [ ] **Backup your notes directory**
- [ ] **Install ez-notes** and set `ez-notes-directory` to your org-roam directory
- [ ] **Run initial scan**: `M-x ez-notes-rebuild-backend`
- [ ] **Test basic functions**: create, find, and link notes
- [ ] **Update keybindings** from org-roam to ez-notes commands
- [ ] **Remove org-roam** from your config (optional)

### Missing Features

Features **not** included in ez-notes (available in org-roam):

- ❌ **Backlinks** - No automatic backlink discovery
- ❌ **Graph view** - No visual graph representation
- ❌ **Roam buffer** - No dedicated sidebar for backlinks
- ❌ **Daily notes** - No built-in daily note templates
- ❌ **Capture templates** - Use standard org-capture instead

## 🏗️ Architecture

### Backend System

ez-notes uses a dual-backend approach for maximum compatibility:

```
┌─────────────────┐    ┌──────────────────┐
│   Emacs 29+     │ or │   Emacs < 29     │
│   SQLite        │    │   Hashtable      │
│   (Fast)        │    │   (Compatible)   │
└─────────────────┘    └──────────────────┘
		 │                       │
		 └───────────┬───────────┘
					 │
			  ┌──────▼──────┐
			  │  ez-notes   │
			  │   API       │
			  └─────────────┘
```

### Performance Characteristics

| Backend | Search Speed | Memory Usage | Persistence |
|---------|--------------|--------------|-------------|
| **SQLite** | Very Fast | Low | Database file |
| **Hashtable** | Fast | Medium | Cache file |

## 🐛 Troubleshooting

### Common Issues

**Database is readonly/locked**
```elisp
M-x ez-notes-fix-database
;; or
M-x ez-notes-force-reconnect
```

**Notes not appearing in search**
```elisp
M-x ez-notes-refresh
;; or for complete rebuild
M-x ez-notes-rebuild-backend
```

**Links not resolving**
```elisp
;; Enable org-id integration
M-x ez-notes-enable-org-id-integration
```

### Debug Information

Check your configuration:
```elisp
;; View current settings
ez-notes-directory          ; Your notes directory
ez-notes-use-sqlite         ; Backend type
ez-notes--db               ; Database connection (if SQLite)
```

## 🤝 Contributing

Contributions are welcome! Areas for improvement:

- [ ] **Performance optimizations** for large note collections
- [ ] **Export/import** functionality
- [ ] **Better error handling** and user feedback
- [ ] **Additional file formats** beyond .org
- [ ] **Integration** with other Emacs packages

## 📄 License

GPL-3.0 License - see LICENSE file for details.

## 🙏 Acknowledgments

- **org-roam** - for the original inspiration and ID system design
- **denote** - for demonstrating minimal dependency approaches
- **Emacs community** - for the powerful foundation this builds upon

---

**Made with ❤️ for the Emacs community**

*"Sometimes the best solution is a simple one but not the simplest"*