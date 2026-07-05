;;; xwidget.el --- api functions for xwidgets  -*- lexical-binding: t -*-

;; Copyright (C) 2011-2026 Free Software Foundation, Inc.

;; Author: Joakim Verona <joakim@verona.se>

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; See the node "(emacs)Embedded WebKit Widgets" in the Emacs manual for
;; help on user-facing features, and "(elisp)Embedded Native Widgets" in
;; the Emacs Lisp reference manual for help on more API functions.

;;; Code:

;; This breaks compilation when we don't have xwidgets.
;; And is pointless when we do, since it's in C and so preloaded.
;;(require 'xwidget-internal)

(require 'bookmark)
(require 'format-spec)

(declare-function make-xwidget "xwidget.c"
                  (type title width height &optional arguments buffer related))
(declare-function xwidget-buffer "xwidget.c" (xwidget))
(declare-function set-xwidget-buffer "xwidget.c" (xwidget buffer))
(declare-function xwidget-size-request "xwidget.c" (xwidget))
(declare-function xwidget-resize "xwidget.c" (xwidget new-width new-height))
(declare-function xwidget-webkit-execute-script "xwidget.c"
                  (xwidget script &optional callback))
(declare-function xwidget-webkit-uri "xwidget.c" (xwidget))
(declare-function xwidget-webkit-title "xwidget.c" (xwidget))
(declare-function xwidget-webkit-goto-uri "xwidget.c" (xwidget uri))
(declare-function xwidget-webkit-goto-history "xwidget.c" (xwidget rel-pos))
(declare-function xwidget-webkit-zoom "xwidget.c" (xwidget factor))
(declare-function xwidget-plist "xwidget.c" (xwidget))
(declare-function set-xwidget-plist "xwidget.c" (xwidget plist))
(declare-function xwidget-view-window "xwidget.c" (xwidget-view))
(declare-function xwidget-view-model "xwidget.c" (xwidget-view))
(declare-function delete-xwidget-view "xwidget.c" (xwidget-view))
(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function xwidget-query-on-exit-flag "xwidget.c" (xwidget))
(declare-function xwidget-webkit-back-forward-list "xwidget.c" (xwidget &optional limit))
(declare-function xwidget-webkit-estimated-load-progress "xwidget.c" (xwidget))
(declare-function xwidget-webkit-set-cookie-storage-file "xwidget.c" (xwidget file))
(declare-function xwidget-live-p "xwidget.c" (xwidget))
(declare-function xwidget-webkit-stop-loading "xwidget.c" (xwidget))
(declare-function xwidget-info "xwidget.c" (xwidget))

(defgroup xwidget nil
  "Displaying native widgets in Emacs buffers."
  :group 'widgets)

(defun xwidget-insert (pos type title width height &optional args related)
  "Insert an xwidget at position POS.
Supply the xwidget's TYPE, TITLE, WIDTH, HEIGHT, and RELATED.
See `make-xwidget' for the possible TYPE values.
The usage of optional argument ARGS depends on the xwidget.
This returns the result of `make-xwidget'."
  (goto-char pos)
  (let ((id (make-xwidget type title width height args nil related)))
    (put-text-property (point) (+ 1 (point))
                       'display (list 'xwidget ':xwidget id))
    id))

(defun xwidget-at (pos)
  "Return xwidget at POS."
  (let* ((disp (get-text-property pos 'display))
         (xw (ignore-errors (car (cdr (cdr disp))))))
    (when (xwidget-live-p xw) xw)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; webkit support
(require 'browse-url)
(require 'image-mode);;for some image-mode alike functionality
(require 'seq)
(require 'url-handlers)

(defgroup xwidget-webkit nil
  "Displaying webkit xwidgets in Emacs buffers."
  :version "29.1"
  :group 'web
  :prefix "xwidget-webkit-")

(defcustom xwidget-webkit-buffer-name-format "*xwidget-webkit: %T*"
  "Template for naming `xwidget-webkit' buffers.
It can use the following special constructs:

  %T -- the title of the Web page loaded by the xwidget.
  %U -- the URI of the Web page loaded by the xwidget."
  :type 'string
  :version "29.1")

(defcustom xwidget-webkit-cookie-file nil
  "The name of the file where `xwidget-webkit-browse-url' will store cookies.
They will be stored as plain text in Mozilla \"cookies.txt\"
format.  If nil, do not store cookies.  You must kill all xwidget-webkit
buffers for this setting to take effect after setting it to nil."
  :type '(choice (const :tag "Do not store cookies" nil) file)
  :version "29.1")

;;;###autoload
(defun xwidget-webkit-browse-url (url &optional new-session)
  "Ask xwidget-webkit to browse URL.
NEW-SESSION specifies whether to create a new xwidget-webkit session.
Interactively, URL defaults to the string looking like a url around point."
  (interactive (progn
                 (require 'browse-url)
                 (browse-url-interactive-arg "xwidget-webkit URL: ")))
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (when (stringp url)
    ;; If it's a "naked url", just try adding https: to it.
    (unless (string-match "\\`[A-Za-z]+:" url)
      (setq url (concat "https://" url)))
    (if new-session
        (xwidget-webkit-new-session url)
      (xwidget-webkit-goto-url url))))

(function-put 'xwidget-webkit-browse-url 'browse-url-browser-kind 'internal)

(defun xwidget-webkit-clone-and-split-below ()
  "Clone current URL into a new widget place in new window below.
Get the URL of current session, then browse to the URL
in `split-window-below' with a new xwidget webkit session."
  (interactive nil xwidget-webkit-mode)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (with-selected-window (split-window-below)
      (xwidget-webkit-new-session url))))

(defun xwidget-webkit-clone-and-split-right ()
  "Clone current URL into a new widget place in new window right.
Get the URL of current session, then browse to the URL
in `split-window-right' with a new xwidget webkit session."
  (interactive nil xwidget-webkit-mode)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (with-selected-window (split-window-right)
      (xwidget-webkit-new-session url))))

(declare-function xwidget-perform-lispy-event "xwidget.c")

(defvar xwidget-webkit--input-method-events nil
  "Internal variable used to store input method events.")

(defvar-local xwidget-webkit--loading-p nil
  "Whether or not a page is being loaded.")

(defvar-local xwidget-webkit--progress-update-timer nil
  "Timer that updates the display of page load progress in the header line.")

(defun xwidget-webkit-pass-command-event-with-input-method ()
  "Handle a `with-input-method' event."
  (interactive)
  (let ((key (pop unread-command-events)))
    (setq xwidget-webkit--input-method-events
          (funcall input-method-function key))
    (exit-minibuffer)))

(defun xwidget-webkit-pass-command-event ()
  "Pass `last-command-event' to the current buffer's WebKit widget.
If `current-input-method' is non-nil, consult `input-method-function'
for the actual events that will be sent."
  (interactive)
  (if (and current-input-method
           (characterp last-command-event))
      (let ((xwidget-webkit--input-method-events nil)
            (minibuffer-local-map (make-keymap)))
        (define-key minibuffer-local-map [with-input-method]
          'xwidget-webkit-pass-command-event-with-input-method)
        (push last-command-event unread-command-events)
        (push 'with-input-method unread-command-events)
        (read-from-minibuffer "" nil nil nil nil nil t)
        (dolist (event xwidget-webkit--input-method-events)
          (xwidget-perform-lispy-event (xwidget-webkit-current-session)
                                       event)))
    (xwidget-perform-lispy-event (xwidget-webkit-current-session)
                                 last-command-event)))

;;todo.
;; - check that the webkit support is compiled in
(defvar xwidget-webkit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" 'xwidget-webkit-browse-url)
    (define-key map "a" 'xwidget-webkit-adjust-size-dispatch)
    (define-key map "b" 'xwidget-webkit-back)
    (define-key map "f" 'xwidget-webkit-forward)
    (define-key map "r" 'xwidget-webkit-reload)
    (define-key map "\C-m" 'xwidget-webkit-insert-string)
    (define-key map "w" 'xwidget-webkit-current-url)
    (define-key map "+" 'xwidget-webkit-zoom-in)
    (define-key map "-" 'xwidget-webkit-zoom-out)
    (define-key map "e" 'xwidget-webkit-edit-mode)
    (define-key map "\C-r" 'xwidget-webkit-isearch-mode)
    (define-key map "\C-s" 'xwidget-webkit-isearch-mode)
    (define-key map "H" 'xwidget-webkit-browse-history)

    ;;similar to image mode bindings
    (define-key map (kbd "SPC")                 'xwidget-webkit-scroll-up)
    (define-key map (kbd "S-SPC")               'xwidget-webkit-scroll-down)
    (define-key map (kbd "DEL")                 'xwidget-webkit-scroll-down)

    (define-key map [remap scroll-up]           'xwidget-webkit-scroll-up-line)
    (define-key map [remap scroll-up-command]   'xwidget-webkit-scroll-up)

    (define-key map [remap scroll-down]         'xwidget-webkit-scroll-down-line)
    (define-key map [remap scroll-down-command] 'xwidget-webkit-scroll-down)

    (define-key map [remap forward-char]        'xwidget-webkit-scroll-forward)
    (define-key map [remap backward-char]       'xwidget-webkit-scroll-backward)
    (define-key map [remap right-char]          'xwidget-webkit-scroll-forward)
    (define-key map [remap left-char]           'xwidget-webkit-scroll-backward)
    (define-key map [remap previous-line]       'xwidget-webkit-scroll-down-line)
    (define-key map [remap next-line]           'xwidget-webkit-scroll-up-line)

    ;; (define-key map [remap move-beginning-of-line] 'image-bol)
    ;; (define-key map [remap move-end-of-line]       'image-eol)
    (define-key map [remap beginning-of-buffer] 'xwidget-webkit-scroll-top)
    (define-key map [remap end-of-buffer]       'xwidget-webkit-scroll-bottom)
    map)
  "Keymap for `xwidget-webkit-mode'.")

(easy-menu-define nil xwidget-webkit-mode-map "Xwidget WebKit menu."
  (list "Xwidget WebKit"
        ["Browse URL" xwidget-webkit-browse-url
         :active t
         :help "Prompt for a URL, then instruct WebKit to browse it"]
        ["Back" xwidget-webkit-back t]
        ["Forward" xwidget-webkit-forward t]
        ["Reload" xwidget-webkit-reload t]
        ["History" xwidget-webkit-browse-history t]
        ["Insert String" xwidget-webkit-insert-string
         :active t
         :help "Insert a string into the currently active field"]
        ["Zoom In" xwidget-webkit-zoom-in t]
        ["Zoom Out" xwidget-webkit-zoom-out t]
        ["Edit Mode" xwidget-webkit-edit-mode
         :active t
         :style toggle
         :selected xwidget-webkit-edit-mode
         :help "Send self inserting characters to the WebKit widget"]
        ["Save Selection" xwidget-webkit-copy-selection-as-kill
         :active t
         :help "Save the browser's selection in the kill ring"]
        ["Incremental Search" xwidget-webkit-isearch-mode
         :active (not xwidget-webkit-isearch-mode)
         :help "Perform incremental search inside the WebKit widget"]
        ["Stop Loading" xwidget-webkit-stop
         :active xwidget-webkit--loading-p]))

(defvar xwidget-webkit-tool-bar-map
  (let ((map (make-sparse-keymap)))
    (prog1 map
      (tool-bar-local-item-from-menu 'xwidget-webkit-stop
                                     "cancel"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-back
                                     "left-arrow"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-forward
                                     "right-arrow"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-reload
                                     "refresh"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-zoom-in
                                     "zoom-in"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-zoom-out
                                     "zoom-out"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-browse-url
                                     "connect-to-url"
                                     map
                                     xwidget-webkit-mode-map)
      (tool-bar-local-item-from-menu 'xwidget-webkit-isearch-mode
                                     "search"
                                     map
                                     xwidget-webkit-mode-map))))

(defun xwidget-webkit-zoom-in ()
  "Increase webkit view zoom factor."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-zoom (xwidget-webkit-current-session) 0.1))

(defun xwidget-webkit-zoom-out ()
  "Decrease webkit view zoom factor."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-zoom (xwidget-webkit-current-session) -0.1))

(defun xwidget-webkit-scroll-up (&optional arg)
  "Scroll webkit up by ARG pixels; or full window height if no ARG.
Stop if bottom of page is reached.
Interactively, ARG is the prefix numeric argument.
Negative ARG scrolls down."
  (interactive "P" xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   (format "window.scrollBy(0, %d);"
           (or arg (xwidget-window-inside-pixel-height (selected-window))))))

(defun xwidget-webkit-scroll-down (&optional arg)
  "Scroll webkit down by ARG pixels; or full window height if no ARG.
Stop if top of page is reached.
Interactively, ARG is the prefix numeric argument.
Negative ARG scrolls up."
  (interactive "P" xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   (format "window.scrollBy(0, -%d);"
           (or arg (xwidget-window-inside-pixel-height (selected-window))))))

(defun xwidget-webkit-scroll-up-line (&optional n)
  "Scroll webkit up by N lines.
The height of line is calculated with `window-font-height'.
Stop if the bottom edge of the page is reached.
If N is omitted or nil, scroll up by one line."
  (interactive "p" xwidget-webkit-mode)
  (xwidget-webkit-scroll-up (* n (window-font-height))))

(defun xwidget-webkit-scroll-down-line (&optional n)
  "Scroll webkit down by N lines.
The height of line is calculated with `window-font-height'.
Stop if the top edge of the page is reached.
If N is omitted or nil, scroll down by one line."
  (interactive "p" xwidget-webkit-mode)
  (xwidget-webkit-scroll-down (* n (window-font-height))))

(defun xwidget-webkit-scroll-forward (&optional n)
  "Scroll webkit horizontally by N chars.
If the widget is larger than the window, hscroll by N columns
instead.  The width of char is calculated with
`window-font-width'.  If N is omitted or nil, scroll forwards by
one char."
  (interactive "p" xwidget-webkit-mode)
  (let ((session (xwidget-webkit-current-session)))
    (if (> (- (aref (xwidget-info session) 2)
              (window-text-width nil t))
           (window-font-width))
        (set-window-hscroll nil (+ (window-hscroll) n))
      (xwidget-webkit-execute-script session
                                     (format "window.scrollBy(%d, 0);"
                                             (* n (window-font-width)))))))

(defun xwidget-webkit-scroll-backward (&optional n)
  "Scroll webkit back by N chars.
If the widget is larger than the window, hscroll backwards by N
columns instead.  The width of char is calculated with
`window-font-width'.  If N is omitted or nil, scroll backwards by
one char."
  (interactive "p" xwidget-webkit-mode)
  (let ((session (xwidget-webkit-current-session)))
    (if (and (> (- (aref (xwidget-info session) 2)
                   (window-text-width nil t))
                (window-font-width))
             (> (window-hscroll) 0))
        (set-window-hscroll nil (- (window-hscroll) n))
      (xwidget-webkit-execute-script session
                                     (format "window.scrollBy(-%d, 0);"
                                             (* n (window-font-width)))))))

(defun xwidget-webkit-scroll-top ()
  "Scroll webkit to the very top."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "window.scrollTo(pageXOffset, 0);"))

(defun xwidget-webkit-scroll-bottom ()
  "Scroll webkit to the very bottom."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "window.scrollTo(pageXOffset, window.document.body.scrollHeight);"))

;; The xwidget event needs to go in the special map.  To receive
;; xwidget events, you should place a callback in the property list of
;; the xwidget, instead of handling these events manually.
;;
;; See `xwidget-webkit-new-session' for an example of how to do this.
(define-key special-event-map [xwidget-event] #'xwidget-event-handler)

(defun xwidget-log (&rest msg)
  "Log MSG to a buffer."
  (let ((buf (get-buffer-create " *xwidget-log*")))
    (with-current-buffer buf
      (insert (apply #'format msg))
      (insert "\n"))))

(defun xwidget-event-handler ()
  "Receive xwidget event."
  (interactive nil xwidget-webkit-mode)
  (xwidget-log "stuff happened to xwidget %S" last-input-event)
  (let*
      ((xwidget-event-type (nth 1 last-input-event))
       (xwidget (nth 2 last-input-event))
       (xwidget-callback (xwidget-get xwidget 'callback)))
    (when xwidget-callback
      (funcall xwidget-callback xwidget xwidget-event-type))))

(defun xwidget-webkit--update-progress-timer-function (xwidget)
  "Force an update of the header line of XWIDGET's buffer."
  (with-current-buffer (xwidget-buffer xwidget)
    (force-mode-line-update)))

(defun xwidget-webkit-buffer-kill ()
  "Clean up an xwidget-webkit buffer before it is killed."
  (when (timerp xwidget-webkit--progress-update-timer)
    (cancel-timer xwidget-webkit--progress-update-timer)))

(defun xwidget-webkit-callback (xwidget xwidget-event-type)
  "Callback for xwidgets.
XWIDGET instance, XWIDGET-EVENT-TYPE depends on the originating xwidget."
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log
       "error: callback called for xwidget with dead buffer")
    (cond ((eq xwidget-event-type 'load-changed)
           (let ((title (xwidget-webkit-title xwidget))
                 (uri (xwidget-webkit-uri xwidget)))
             (when-let* ((buffer (get-buffer "*Xwidget WebKit History*")))
               (with-current-buffer buffer
                 (revert-buffer)))
             (with-current-buffer (xwidget-buffer xwidget)
               (if (string-equal (nth 3 last-input-event)
                                 "load-finished")
                   (progn
                     (setq xwidget-webkit--loading-p nil)
                     (cancel-timer xwidget-webkit--progress-update-timer))
                 (unless xwidget-webkit--loading-p
                   (setq xwidget-webkit--loading-p t
                         xwidget-webkit--progress-update-timer
                         (run-at-time 0.5 0.5 #'xwidget-webkit--update-progress-timer-function
                                      xwidget)))))
             ;; This function will be called multi times, so only
             ;; change buffer name when the load actually completes
             ;; this can limit buffer-name flicker in mode-line.
             (when (or (string-equal (nth 3 last-input-event)
                                     "load-finished")
                       (> (length title) 0))
               (with-current-buffer (xwidget-buffer xwidget)
                 (force-mode-line-update)
                 (xwidget-log "webkit finished loading: %s" title)
                 ;; Do not adjust webkit size to window here, the
                 ;; selected window can be the mini-buffer window
                 ;; unwantedly.
                 (rename-buffer
                  (format-spec
                   xwidget-webkit-buffer-name-format
                   `((?T . ,title)
                     (?U . ,uri)))
                  t)))))
          ((eq xwidget-event-type 'decide-policy)
           (let ((strarg  (nth 3 last-input-event)))
             (if (string-match ".*#\\(.*\\)" strarg)
                 (xwidget-webkit-show-id-or-named-element
                  xwidget
                  (match-string 1 strarg)))))
          ;; TODO: Response handling other than download.
          ((eq xwidget-event-type 'download-callback)
           (let ((url  (nth 3 last-input-event))
                 (mime-type (nth 4 last-input-event))
                 (file-name (nth 5 last-input-event)))
             (xwidget-webkit-save-as-file url mime-type file-name)))
          ((eq xwidget-event-type 'javascript-callback)
           (let ((proc (nth 3 last-input-event))
                 (arg  (nth 4 last-input-event)))
             (funcall proc arg)))
          (t (xwidget-log "unhandled event:%s" xwidget-event-type)))))

(defvar bookmark-make-record-function)
(when (memq window-system '(mac ns))
  (defcustom xwidget-webkit-enable-plugins nil
    "Enable plugins for xwidget webkit.
If non-nil, plugins are enabled.  Otherwise, disabled."
    :type 'boolean
    :version "28.1"))

(define-derived-mode xwidget-webkit-mode special-mode "xwidget-webkit"
  "Xwidget webkit view mode."
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-webkit-buffer-kill)
  (setq-local tool-bar-map xwidget-webkit-tool-bar-map)
  (setq-local bookmark-make-record-function
              #'xwidget-webkit-bookmark-make-record)
  (setq-local header-line-format
              (list "WebKit: "
                    '(:eval
                      (xwidget-webkit-title (xwidget-webkit-current-session)))
                    '(:eval
                      (when xwidget-webkit--loading-p
                        (let ((session (xwidget-webkit-current-session)))
                          (format " [%d%%%%]"
                                  (* 100
                                     (xwidget-webkit-estimated-load-progress
                                      session))))))))
  ;; Keep track of [vh]scroll when switching buffers
  (image-mode-setup-winprops))

;;; Download, save as file.

(defcustom xwidget-webkit-download-dir "~/Downloads/"
  "Directory where download file saved."
  :version "28.1"
  :type 'file)

(defun xwidget-webkit-save-as-file (url mime-type file-name)
  "For XWIDGET webkit, save URL of MIME-TYPE to location specified by user.
FILE-NAME combined with `xwidget-webkit-download-dir' is the default file name
of the prompt when reading.  When the file name the user specified is a
directory, URL is saved at the specified directory as FILE-NAME."
  (let ((save-name (read-file-name
                    (format "Save URL `%s' of type `%s' in file/directory: "
                            url mime-type)
                    xwidget-webkit-download-dir
                    (when file-name
                      (expand-file-name
                       file-name
                       xwidget-webkit-download-dir)))))
    (if (file-directory-p save-name)
        (setq save-name
              (expand-file-name (file-name-nondirectory file-name) save-name)))
    (setq xwidget-webkit-download-dir (file-name-directory save-name))
    (url-copy-file url save-name t)))

;;; Bookmarks integration

(defcustom xwidget-webkit-bookmark-jump-new-session nil
  "Whether to jump to a bookmarked URL in a new xwidget webkit session.
If non-nil, create a new xwidget webkit session, otherwise use
the value of `xwidget-webkit-last-session'."
  :version "28.1"
  :type 'boolean)

(defun xwidget-webkit-bookmark-make-record ()
  "Create a bookmark record for a webkit xwidget."
  (nconc (bookmark-make-record-default t t)
         `((page . ,(xwidget-webkit-uri (xwidget-webkit-current-session)))
           (handler . xwidget-webkit-bookmark-jump-handler))))

;;;###autoload
(defun xwidget-webkit-bookmark-jump-handler (bookmark)
  "Jump to the web page bookmarked by the bookmark record BOOKMARK.
If `xwidget-webkit-bookmark-jump-new-session' is non-nil, create
a new xwidget-webkit session, otherwise use an existing session."
  (let* ((url (bookmark-prop-get bookmark 'page))
	 (xwbuf (if (or xwidget-webkit-bookmark-jump-new-session
                        (not (xwidget-webkit-current-session)))
	            (xwidget-webkit--create-new-session-buffer url)
                  (xwidget-buffer (xwidget-webkit-current-session)))))
    (with-current-buffer xwbuf
      (xwidget-webkit-goto-uri (xwidget-webkit-current-session) url))
    (set-buffer xwbuf)))

;;; xwidget webkit session

(defvar xwidget-webkit-last-session-buffer nil)

(defun xwidget-webkit-last-session ()
  "Last active webkit, or nil."
  (if (buffer-live-p xwidget-webkit-last-session-buffer)
      (with-current-buffer xwidget-webkit-last-session-buffer
        (xwidget-at (point-min)))
    nil))

(defun xwidget-webkit-current-session ()
  "Either the webkit in the current buffer, or the last one used.
The latter might be nil."
  (or (xwidget-at (point-min)) (xwidget-webkit-last-session)))

(defun xwidget-adjust-size-to-content (xw)
  "Resize XW to content."
  ;; xwidgets doesn't support widgets that have their own opinions about
  ;; size well, yet this reads the desired size and resizes the Emacs
  ;; allocated area accordingly.
  (let ((size (xwidget-size-request xw)))
    (xwidget-resize xw (car size) (cadr size))))

(defun xwidget-webkit-stop ()
  "Stop trying to load the current page."
  (interactive)
  (xwidget-webkit-stop-loading (xwidget-webkit-current-session)))

(defvar xwidget-webkit-activeelement-js"
function findactiveelement(doc){
//alert(doc.activeElement.value);
   if(doc.activeElement.value != undefined){
      return doc.activeElement;
   }else{
        // recurse over the child documents:
        var frames = doc.getElementsByTagName('frame');
        for (var i = 0; i < frames.length; i++)
        {
                var d = frames[i].contentDocument;
                 var rv = findactiveelement(d);
                 if(rv != undefined){
                    return rv;
                 }
        }
    }
    return undefined;
};


"

  "Javascript that finds the active element."
  ;; Yes it's ugly, because:
  ;; - there is apparently no way to find the active frame other than recursion
  ;; - the js "for each" construct misbehaved on the "frames" collection
  ;; - a window with no frameset still has frames.length == 1, but
  ;; frames[0].document.activeElement != document.activeElement
  ;;TODO the activeelement type needs to be examined, for iframe, etc.
  )

(defun xwidget-webkit-insert-string ()
  "Insert string into the active field in the current webkit widget."
  ;; Read out the string in the field first and provide for edit.
  (interactive nil xwidget-webkit-mode)
  ;; As the prompt differs on JavaScript execution results,
  ;; the function must handle the prompt itself.
  (let ((xww (xwidget-webkit-current-session)))
    (xwidget-webkit-execute-script
     xww
     (concat xwidget-webkit-activeelement-js "
(function () {
  var res = findactiveelement(document);
  if (res)
    return [res.value, res.type];
})();")
     (lambda (field)
       "Prompt a string for the FIELD and insert in the active input."
       (let ((str (pcase field
                    (`[,val "text"]
                     (read-string "Text: " val))
                    (`[,val "password"]
                     (read-passwd "Password: " nil val))
                    (`[,val "textarea"]
                     (xwidget-webkit-begin-edit-textarea xww val)))))
         (xwidget-webkit-execute-script
          xww
          (format "findactiveelement(document).value='%s'" str)))))))

(defvar xwidget-xwbl)
(defun xwidget-webkit-begin-edit-textarea (xw text)
  "Start editing of a webkit text area.
XW is the xwidget identifier, TEXT is retrieved from the webkit."
  (switch-to-buffer
   (generate-new-buffer "textarea"))
  (setq-local xwidget-xwbl xw)
  (insert text))

(defun xwidget-webkit-end-edit-textarea ()
  "End editing of a webkit text area."
  (interactive nil xwidget-webkit-mode)
  (goto-char (point-min))
  (while (search-forward "\n" nil t)
    (replace-match "\\n" nil t))
  (xwidget-webkit-execute-script
   xwidget-xwbl
   (format "findactiveelement(document).value='%s'"
           (buffer-substring (point-min) (point-max))))
  ;;TODO convert linefeed to \n
  )

(defun xwidget-webkit-show-element (xw element-selector)
  "Make webkit xwidget XW show a named element ELEMENT-SELECTOR.
The ELEMENT-SELECTOR must be a valid CSS selector.  For example,
use this to display an anchor."
  (interactive (list (xwidget-webkit-current-session)
                     (read-string "Element selector: "))
               xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   xw
   (format "
(function (query) {
  var el = document.querySelector(query);
  if (el !== null) {
    window.scrollTo(0, el.offsetTop);
  }
})('%s');"
    element-selector)))

(defun xwidget-webkit-show-named-element (xw element-name)
  "Make webkit xwidget XW show a named element ELEMENT-NAME.
For example, use this to display an anchor."
  (interactive (list (xwidget-webkit-current-session)
                     (read-string "Element name: "))
               xwidget-webkit-mode)
  ;; TODO: This needs to be interfaced into browse-url somehow.  The
  ;; tricky part is that we need to do this in two steps: A: load the
  ;; base url, wait for load signal to arrive B: navigate to the
  ;; anchor when the base url is finished rendering
  (xwidget-webkit-execute-script
   xw
   (format "
(function (query) {
  var el = document.getElementsByName(query)[0];
  if (el !== undefined) {
    window.scrollTo(0, el.offsetTop);
  }
})('%s');"
    element-name)))

(defun xwidget-webkit-show-id-element (xw element-id)
  "Make webkit xwidget XW show an id-element ELEMENT-ID.
For example, use this to display an anchor."
  (interactive (list (xwidget-webkit-current-session)
                     (read-string "Element id: "))
               xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   xw
   (format "
(function (query) {
  var el = document.getElementById(query);
  if (el !== null) {
    window.scrollTo(0, el.offsetTop);
  }
})('%s');"
    element-id)))

(defun xwidget-webkit-show-id-or-named-element (xw element-id)
   "Make webkit xwidget XW show a name or element id ELEMENT-ID.
For example, use this to display an anchor."
  (interactive (list (xwidget-webkit-current-session)
                     (read-string "Name or element id: "))
               xwidget-webkit-mode)
  (xwidget-webkit-execute-script
   xw
   (format "
(function (query) {
  var el = document.getElementById(query) ||
           document.getElementsByName(query)[0];
  if (el !== undefined) {
    window.scrollTo(0, el.offsetTop);
  }
})('%s');"
    element-id)))

(defun xwidget-webkit-adjust-size-to-content ()
  "Adjust webkit to content size."
  (interactive nil xwidget-webkit-mode)
  (xwidget-adjust-size-to-content (xwidget-webkit-current-session)))

(defun xwidget-webkit-adjust-size-dispatch ()
  "Adjust size according to mode."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-adjust-size-to-window (xwidget-webkit-current-session))
  ;; The recenter is intended to correct a visual glitch.
  ;; It errors out if the buffer isn't visible, but then we don't get
  ;; the glitch, so silence errors.
  (ignore-errors
    (recenter-top-bottom)))

;; Utility functions

(defun xwidget-window-inside-pixel-width (window)
  "Return Emacs WINDOW body width in pixel."
  (let ((edges (window-inside-pixel-edges window)))
    (- (nth 2 edges) (nth 0 edges))))

(defun xwidget-window-inside-pixel-height (window)
  "Return Emacs WINDOW body height in pixel."
  (let ((edges (window-inside-pixel-edges window)))
    (- (nth 3 edges) (nth 1 edges))))

(defun xwidget-webkit-adjust-size-to-window (xwidget &optional window)
  "Adjust the size of the webkit XWIDGET to fit the WINDOW."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-webkit-adjust-size (w h)
  "Manually set webkit size to width W, height H."
  ;; TODO shouldn't be tied to the webkit xwidget
  (interactive "nWidth:\nnHeight:\n" xwidget-webkit-mode)
  (xwidget-resize (xwidget-webkit-current-session) w h))

(defun xwidget-webkit-fit-width ()
  "Adjust width of webkit to window width."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-adjust-size (- (nth 2 (window-inside-pixel-edges))
                                 (car (window-inside-pixel-edges)))
                              1000))

(defun xwidget-webkit-auto-adjust-size (window)
  "Adjust the size of the webkit widget in the given WINDOW."
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-webkit-mode)
      (let ((xwidget (xwidget-webkit-current-session)))
        (xwidget-webkit-adjust-size-to-window xwidget window)))))

(defun xwidget-webkit-adjust-size-in-frame (frame)
  "Dynamically adjust webkit widget for all windows of the FRAME."
  (walk-windows 'xwidget-webkit-auto-adjust-size 'no-minibuf frame))

(eval-after-load 'xwidget-webkit-mode
  (add-to-list 'window-size-change-functions
               'xwidget-webkit-adjust-size-in-frame))

(defun xwidget-webkit--create-new-session-buffer (url &optional callback)
  "Create a new webkit session buffer to display URL in an xwidget.
Optional function CALLBACK specifies the callback for webkit xwidgets;
see `xwidget-webkit-callback'."
  (let* ((bufname
          ;; Generate a temp-name based on current buffer name.  The
          ;; buffer will subsequently be renamed by
          ;; `xwidget-webkit-callback'.  This approach can avoid
          ;; flicker of buffer-name in mode-line.
          (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-webkit-callback))
         (current-session (xwidget-webkit-current-session))
         xw)
    (setq xwidget-webkit-last-session-buffer (get-buffer-create bufname))
    ;; The xwidget id is stored in a text property, so we need to have
    ;; at least character in this buffer.
    ;; Insert invisible url, good default for next `g' to browse url.
    (with-current-buffer xwidget-webkit-last-session-buffer
      (let ((start (point)))
        (insert url)
        (put-text-property start (+ start (length url)) 'invisible t)
        (setq xw (xwidget-insert
                  start 'webkit bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session)))
      (when xwidget-webkit-cookie-file
        (xwidget-webkit-set-cookie-storage-file
         xw (expand-file-name xwidget-webkit-cookie-file)))
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-webkit-display-callback)
      (xwidget-webkit-mode))
    xwidget-webkit-last-session-buffer))

(defun xwidget-webkit-new-session (url)
  "Display URL in a new webkit xwidget."
  (switch-to-buffer (xwidget-webkit--create-new-session-buffer url))
  (xwidget-webkit-goto-uri (xwidget-webkit-last-session) url))

(defun xwidget-webkit-import-widget (xwidget)
  "Create a new webkit session buffer from XWIDGET, an existing xwidget.
Return the buffer."
  (let* ((bufname
          ;; Generate a temp-name based on current buffer name. it
          ;; will be renamed by `xwidget-webkit-callback' in the
          ;; future. This approach can limit flicker of buffer-name in
          ;; mode-line.
          (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-webkit-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-webkit-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback
                   #'xwidget-webkit-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-webkit-mode))
    buffer))

(defun xwidget-webkit-display-event (event)
  "Trigger display callback for EVENT."
  (interactive "e")
  (let ((xwidget (cadr event))
        (source (caddr event)))
    (when (xwidget-get source 'display-callback)
      (funcall (xwidget-get source 'display-callback)
               xwidget source))))

(defun xwidget-webkit-display-callback (xwidget _source)
  "Import XWIDGET and display it."
  (display-buffer (xwidget-webkit-import-widget xwidget)))

(define-key special-event-map [xwidget-display-event] 'xwidget-webkit-display-event)

(defun xwidget-webkit-goto-url (url)
  "Goto URL with xwidget webkit."
  (if (xwidget-webkit-current-session)
      (progn
        (xwidget-webkit-goto-uri (xwidget-webkit-current-session) url)
        (switch-to-buffer (xwidget-buffer (xwidget-webkit-current-session))))
    (xwidget-webkit-new-session url)))

(defun xwidget-webkit-back ()
  "Go back to previous URL in xwidget webkit buffer."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-goto-history (xwidget-webkit-current-session) -1))

(defun xwidget-webkit-forward ()
  "Go forward in history."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-goto-history (xwidget-webkit-current-session) 1))

(defun xwidget-webkit-reload ()
  "Reload current URL."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-goto-history (xwidget-webkit-current-session) 0))

(defun xwidget-webkit-current-url ()
  "Display the current xwidget webkit URL and place it on the `kill-ring'."
  (interactive nil xwidget-webkit-mode)
  (let ((url (xwidget-webkit-uri (xwidget-webkit-current-session))))
    (when url (kill-new url))
    (message "URL: %s" url)))

(defun xwidget-webkit-browse-history ()
  "Display a buffer containing the history of page loads."
  (interactive)
  (setq xwidget-webkit-last-session-buffer (current-buffer))
  (let ((buffer (get-buffer-create "*Xwidget WebKit History*")))
    (with-current-buffer buffer
      (xwidget-webkit-history-mode))
    (display-buffer buffer)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun xwidget-webkit-get-selection (proc)
  "Get the webkit selection and pass it to PROC."
  (xwidget-webkit-execute-script
   (xwidget-webkit-current-session)
   "window.getSelection().toString();"
   proc))

(defun xwidget-webkit-copy-selection-as-kill ()
  "Get the webkit selection and put it on the `kill-ring'."
  (interactive nil xwidget-webkit-mode)
  (xwidget-webkit-get-selection #'kill-new))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Xwidget plist management (similar to the process plist functions)

(defun xwidget-get (xwidget propname)
  "Get an xwidget's property value.
XWIDGET is an xwidget, PROPNAME a property.
Returns the last value stored with `xwidget-put'."
  (plist-get (xwidget-plist xwidget) propname))

(defun xwidget-put (xwidget propname value)
  "Set an xwidget's property value.
XWIDGET is an xwidget, PROPNAME a property to be set to specified VALUE.
You can retrieve the value with `xwidget-get'."
  (set-xwidget-plist xwidget
                     (plist-put (xwidget-plist xwidget) propname value)))

(defvar-keymap xwidget-webkit-edit-mode-map :full t)

(define-key xwidget-webkit-edit-mode-map [backspace] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [tab] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [left] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [right] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [up] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [down] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [return] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-left] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-right] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-up] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-down] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-return] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [S-left] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [S-right] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [S-up] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [S-down] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [S-return] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [M-left] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [M-right] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [M-up] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [M-down] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [M-return] 'xwidget-webkit-pass-command-event)
(define-key xwidget-webkit-edit-mode-map [C-backspace] 'xwidget-webkit-pass-command-event)

(define-minor-mode xwidget-webkit-edit-mode
  "Minor mode for editing the content of WebKit buffers.

This defines most self-inserting characters and some common
keyboard shortcuts to `xwidget-webkit-pass-command-event', which
will pass the key events corresponding to these characters to the
WebKit widget."
  :keymap xwidget-webkit-edit-mode-map)

(substitute-key-definition 'self-insert-command
                           'xwidget-webkit-pass-command-event
                           xwidget-webkit-edit-mode-map
                           global-map)

(declare-function xwidget-webkit-search "xwidget.c")
(declare-function xwidget-webkit-next-result "xwidget.c")
(declare-function xwidget-webkit-previous-result "xwidget.c")
(declare-function xwidget-webkit-finish-search "xwidget.c")

(defvar-local xwidget-webkit-isearch--string ""
  "The current search query.")
(defvar-local xwidget-webkit-isearch--is-reverse nil
  "Whether or not the current isearch should be reverse.")
(defvar xwidget-webkit-isearch--read-string-buffer nil
  "The buffer we are reading input method text for, if any.")

(defun xwidget-webkit-isearch--update (&optional only-message)
  "Update the current buffer's WebKit widget's search query.
If ONLY-MESSAGE is non-nil, the query will not be sent to the
WebKit widget.  The query will be set to the contents of
`xwidget-webkit-isearch--string'."
  (unless only-message
    (xwidget-webkit-search xwidget-webkit-isearch--string
                           (xwidget-webkit-current-session)
                           t xwidget-webkit-isearch--is-reverse t))
  (let ((message-log-max nil))
    (message "%s" (concat (propertize "Search contents: " 'face 'minibuffer-prompt)
                          xwidget-webkit-isearch--string))))

(defun xwidget-webkit-isearch-erasing-char (count)
  "Erase the last COUNT characters of the current query."
  (interactive (list (prefix-numeric-value current-prefix-arg)))
  (when (> (length xwidget-webkit-isearch--string) 0)
    (setq xwidget-webkit-isearch--string
          (substring xwidget-webkit-isearch--string 0
                     (- (length xwidget-webkit-isearch--string) count))))
  (xwidget-webkit-isearch--update))

(defun xwidget-webkit-isearch-with-input-method ()
  "Handle a request to use the input method to modify the search query."
  (interactive)
  (let ((key (car unread-command-events))
	events)
    (setq unread-command-events (cdr unread-command-events)
	  events (funcall input-method-function key))
    (dolist (k events)
      (with-current-buffer xwidget-webkit-isearch--read-string-buffer
        (setq xwidget-webkit-isearch--string
              (concat xwidget-webkit-isearch--string
                      (char-to-string k)))))
    (exit-minibuffer)))

(defun xwidget-webkit-isearch-printing-char-with-input-method (char)
  "Handle printing char CHAR with the current input method."
  (let ((minibuffer-local-map (make-keymap))
        (xwidget-webkit-isearch--read-string-buffer (current-buffer)))
    (define-key minibuffer-local-map [with-input-method]
      'xwidget-webkit-isearch-with-input-method)
    (setq unread-command-events
          (cons 'with-input-method
                (cons char unread-command-events)))
    (read-string "Search contents: "
                 xwidget-webkit-isearch--string
                 'junk-hist nil t)
    (xwidget-webkit-isearch--update)))

(defun xwidget-webkit-isearch-printing-char (char &optional count)
  "Add ordinary character CHAR to the search string and search.
With argument, add COUNT copies of CHAR."
  (interactive (list last-command-event
                     (prefix-numeric-value current-prefix-arg)))
  (if current-input-method
      (xwidget-webkit-isearch-printing-char-with-input-method char)
    (setq xwidget-webkit-isearch--string (concat xwidget-webkit-isearch--string
                                                 (make-string (or count 1) char))))
  (xwidget-webkit-isearch--update))

(defun xwidget-webkit-isearch-forward (count)
  "Move to the next search result COUNT times."
  (interactive (list (prefix-numeric-value current-prefix-arg)))
  (let ((was-reverse xwidget-webkit-isearch--is-reverse))
    (setq xwidget-webkit-isearch--is-reverse nil)
    (when was-reverse
      (xwidget-webkit-isearch--update)
      (setq count (1- count))))
  (let ((i 0))
    (while (< i count)
      (xwidget-webkit-next-result (xwidget-webkit-current-session))
      (incf i)))
  (xwidget-webkit-isearch--update t))

(defun xwidget-webkit-isearch-backward (count)
  "Move to the previous search result COUNT times."
  (interactive (list (prefix-numeric-value current-prefix-arg)))
  (let ((was-reverse xwidget-webkit-isearch--is-reverse))
    (setq xwidget-webkit-isearch--is-reverse t)
    (unless was-reverse
      (xwidget-webkit-isearch--update)
      (setq count (1- count))))
  (let ((i 0))
    (while (< i count)
      (xwidget-webkit-previous-result (xwidget-webkit-current-session))
      (incf i)))
  (xwidget-webkit-isearch--update t))

(defun xwidget-webkit-isearch-exit ()
  "Exit incremental search of a WebKit buffer."
  (interactive)
  (xwidget-webkit-isearch-mode 0))

(defvar-keymap xwidget-webkit-isearch-mode-map
  :doc "The keymap used inside `xwidget-webkit-isearch-mode'."
  :full t)

(set-char-table-range (nth 1 xwidget-webkit-isearch-mode-map)
                      (cons 0 (max-char))
                      'xwidget-webkit-isearch-exit)

(substitute-key-definition 'self-insert-command
                           'xwidget-webkit-isearch-printing-char
                           xwidget-webkit-isearch-mode-map
                           global-map)

(define-key xwidget-webkit-isearch-mode-map (kbd "DEL")
  'xwidget-webkit-isearch-erasing-char)
(define-key xwidget-webkit-isearch-mode-map [backspace] 'xwidget-webkit-isearch-erasing-char)
(define-key xwidget-webkit-isearch-mode-map [return] 'xwidget-webkit-isearch-exit)
(define-key xwidget-webkit-isearch-mode-map "\r" 'xwidget-webkit-isearch-exit)
(define-key xwidget-webkit-isearch-mode-map "\C-g" 'xwidget-webkit-isearch-exit)
(define-key xwidget-webkit-isearch-mode-map "\C-r" 'xwidget-webkit-isearch-backward)
(define-key xwidget-webkit-isearch-mode-map "\C-s" 'xwidget-webkit-isearch-forward)
(define-key xwidget-webkit-isearch-mode-map "\C-y" 'xwidget-webkit-isearch-yank-kill)
(define-key xwidget-webkit-isearch-mode-map "\C-\\" 'toggle-input-method)
(define-key xwidget-webkit-isearch-mode-map "\t" 'xwidget-webkit-isearch-printing-char)

(let ((meta-map (make-keymap)))
  (set-char-table-range (nth 1 meta-map)
                        (cons 0 (max-char))
                        'xwidget-webkit-isearch-exit)
  (define-key xwidget-webkit-isearch-mode-map (char-to-string meta-prefix-char) meta-map))

(define-minor-mode xwidget-webkit-isearch-mode
  "Minor mode for performing incremental search inside WebKit buffers.

This resembles the regular incremental search, but it does not
support recursive edits.

If this mode is activated with `\\<xwidget-webkit-isearch-mode-map>\\[xwidget-webkit-isearch-backward]', then the search will by default
start in the reverse direction.

To navigate around the search results, type
\\<xwidget-webkit-isearch-mode-map>\\[xwidget-webkit-isearch-forward] to move forward, and
\\<xwidget-webkit-isearch-mode-map>\\[xwidget-webkit-isearch-backward] to move backward.

To insert the string at the front of the kill ring into the
search query, type \\<xwidget-webkit-isearch-mode-map>\\[xwidget-webkit-isearch-yank-kill].

Press \\<xwidget-webkit-isearch-mode-map>\\[xwidget-webkit-isearch-exit] to exit incremental search."
  :keymap xwidget-webkit-isearch-mode-map
  (if xwidget-webkit-isearch-mode
      (progn
        (setq xwidget-webkit-isearch--string "")
        (setq xwidget-webkit-isearch--is-reverse (eq last-command-event ?\C-r))
        (xwidget-webkit-isearch--update))
    (xwidget-webkit-finish-search (xwidget-webkit-current-session))))

(defun xwidget-webkit-isearch-yank-kill ()
  "Append the most recent kill from `kill-ring' to the current query."
  (interactive)
  (unless xwidget-webkit-isearch-mode
    (xwidget-webkit-isearch-mode t))
  (setq xwidget-webkit-isearch--string
        (concat xwidget-webkit-isearch--string
                (current-kill 0)))
  (xwidget-webkit-isearch--update))

(defvar-local xwidget-webkit-history--session nil
  "The xwidget this history buffer controls.")

(define-button-type 'xwidget-webkit-history 'action #'xwidget-webkit-history-select-item)

(defun xwidget-webkit-history--insert-item (item)
  "Insert specified ITEM into the current buffer."
  (let ((idx (car item))
        (title (cadr item))
        (uri (caddr item)))
    (push (list idx (vector (list (number-to-string idx)
                                  :type 'xwidget-webkit-history)
                            (list title :type 'xwidget-webkit-history)
                            (list uri :type 'xwidget-webkit-history)))
          tabulated-list-entries)))

(defun xwidget-webkit-history-select-item (pos)
  "Navigate to the history item underneath POS."
  (interactive "P")
  (let ((id (tabulated-list-get-id pos)))
    (xwidget-webkit-goto-history xwidget-webkit-history--session id))
  (xwidget-webkit-history-reload))

(defun xwidget-webkit-history-reload (&rest _ignored)
  "Reload the current history buffer."
  (interactive)
  (setq tabulated-list-entries nil)
  (let* ((back-forward-list
          (xwidget-webkit-back-forward-list xwidget-webkit-history--session))
         (back-list (car back-forward-list))
         (here (cadr back-forward-list))
         (forward-list (caddr back-forward-list)))
    (mapc #'xwidget-webkit-history--insert-item (nreverse forward-list))
    (xwidget-webkit-history--insert-item here)
    (mapc #'xwidget-webkit-history--insert-item back-list)
    (tabulated-list-print t nil)
    (goto-char (point-min))
    (let ((position (line-beginning-position (1+ (length back-list)))))
      (goto-char position)
      (setq-local overlay-arrow-position (make-marker))
      (set-marker overlay-arrow-position position))))

(define-derived-mode xwidget-webkit-history-mode tabulated-list-mode
  "Xwidget Webkit History"
  "Major mode for browsing the history of an Xwidget Webkit buffer.
Each line describes an entry in history."
  (setq truncate-lines t)
  (setq buffer-read-only t)
  (setq tabulated-list-format [("Index" 10 nil)
                               ("Title" 50 nil)
                               ("URL" 100 nil)])
  (setq tabulated-list-entries nil)
  (setq xwidget-webkit-history--session (xwidget-webkit-current-session))
  (xwidget-webkit-history-reload)
  (setq-local revert-buffer-function #'xwidget-webkit-history-reload)
  (tabulated-list-init-header))

(define-key xwidget-webkit-history-mode-map (kbd "RET")
  #'xwidget-webkit-history-select-item)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar xwidget-view-list)              ; xwidget.c
(defvar xwidget-list)                   ; xwidget.c

(defun xwidget-delete-zombies ()
  "Helper for `xwidget-cleanup'."
  (dolist (xwidget-view xwidget-view-list)
    (when (or (not (window-live-p (xwidget-view-window xwidget-view)))
              (not (memq (xwidget-view-model xwidget-view)
                         xwidget-list)))
      (delete-xwidget-view xwidget-view))))

(defun xwidget-cleanup ()
  "Delete zombie xwidgets."
  ;; During development it was sometimes easy to wind up with zombie
  ;; xwidget instances.
  ;; This function tries to implement a workaround should it occur again.
  (interactive)
  ;; Kill xviews that should have been deleted but still linger.
  (xwidget-delete-zombies)
  ;; Redraw display otherwise ghost of zombies will remain to haunt the screen
  (redraw-display))

(defun xwidget-kill-buffer-query-function ()
  "Ask before killing a buffer that has xwidgets."
  (let ((xwidgets (get-buffer-xwidgets (current-buffer))))
    (or (not xwidgets)
        (not (memq t (mapcar #'xwidget-query-on-exit-flag xwidgets)))
        (yes-or-no-p
         (format "Buffer %S has xwidgets; kill it? " (buffer-name))))))

(when (featurep 'xwidget-internal)
  (add-hook 'kill-buffer-query-functions #'xwidget-kill-buffer-query-function)
  ;; This would have felt better in C, but this seems to work well in
  ;; practice though.
  (add-hook 'window-configuration-change-hook #'xwidget-delete-zombies))


(defun xwidget-metal-adjust-size-to-content ()
  "Adjust webkit to content size."
  (interactive nil xwidget-metal-mode)
  (xwidget-adjust-size-to-content (xwidget-metal-current-session)))

(defun xwidget-metal-adjust-size-dispatch ()
  "Adjust size according to mode."
  (interactive nil xwidget-metal-mode)
  (xwidget-metal-adjust-size-to-window (xwidget-metal-current-session))
  ;; The recenter is intended to correct a visual glitch.
  ;; It errors out if the buffer isn't visible, but then we don't get
  ;; the glitch, so silence errors.
  (ignore-errors
    (recenter-top-bottom)))

;; Utility functions

(defun xwidget-metal-adjust-size-to-window (xwidget &optional window)
  "Adjust the size of the webkit XWIDGET to fit the WINDOW."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-metal-adjust-size (w h)
  "Manually set webkit size to width W, height H."
  ;; TODO shouldn't be tied to the webkit xwidget
  (interactive "nWidth:\nnHeight:\n" xwidget-metal-mode)
  (xwidget-resize (xwidget-metal-current-session) w h))

(defun xwidget-metal-fit-width ()
  "Adjust width of webkit to window width."
  (interactive nil xwidget-metal-mode)
  (xwidget-metal-adjust-size (- (nth 2 (window-inside-pixel-edges))
                                 (car (window-inside-pixel-edges)))
                              1000))

(defun xwidget-metal-auto-adjust-size (window)
  "Adjust the size of the webkit widget in the given WINDOW."
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-metal-mode)
      (let ((xwidget (xwidget-metal-current-session)))
        (xwidget-metal-adjust-size-to-window xwidget window)))))

(defun xwidget-metal-adjust-size-in-frame (frame)
  "Dynamically adjust webkit widget for all windows of the FRAME."
  (walk-windows 'xwidget-metal-auto-adjust-size 'no-minibuf frame))

(eval-after-load 'xwidget-metal-mode
  (add-to-list 'window-size-change-functions
               'xwidget-metal-adjust-size-in-frame))

(defvar xwidget-metal-last-session-buffer nil)

(defun xwidget-metal-last-session ()
  (if (buffer-live-p xwidget-metal-last-session-buffer)
      (with-current-buffer xwidget-metal-last-session-buffer
        (xwidget-at (point-min)))
      nil))

(defun xwidget-metal-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type))
          )
      )
  )

(defun xwidget-metal-buffer-kill ()
  )

(defvar xwidget-metal-mode-map
  (let ((map (make-sparse-keymap)))
   map)
  "Keymap for `xwidget-metal-mode'.")


(define-derived-mode xwidget-metal-mode special-mode "xwidget-metal"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-metal-buffer-kill)
  ;;(setq-local tool-bar-map xwidget-metal-tool-bar-map)
  (image-mode-setup-winprops)
  )

(defun xwidget-metal-current-session ()
  (or (xwidget-at (point-min)) (xwidget-metal-last-session))
  )

(defun xwidget-metal-import-widget (xwidget)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-metal-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-metal-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-metal-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-metal-mode)
      )
    buffer))

(defun xwidget-metal-display-callback (xwidget _source)
  (display-buffer (xwidget-metal-import-widget xwidget))
  )

(defun xwidget-metal-display ()
  (interactive)
  (display-buffer (xwidget-metal-import-widget (xwidget-metal-current-session)))
  )

(defun xwidget-metal--create-new-session-buffer (&optional callback)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-metal-callback))
         (current-session (xwidget-metal-current-session))
         xw
         )
    (setq xwidget-metal-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-metal-last-session-buffer
      (let ((start (point)))
        (insert "metal")
        (put-text-property start (+ start (length "metal")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'metal bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session))
        )
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-metal-display-callback)
      (xwidget-metal-mode)
      )
    xwidget-metal-last-session-buffer))

(defun xwidget-metal-new-session ()
  (switch-to-buffer (xwidget-metal--create-new-session-buffer)))

(defun xwidget-metal-goto ()
  (if (xwidget-metal-current-session)
      (progn
        (switch-to-buffer (xwidget-buffer (xwidget-metal-current-session))))
    (xwidget-metal-new-session)
    ))

;;;###autoload
(defun xwidget-metal-browse (&optional new-session)
  (interactive)
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-metal-new-session)
    (xwidget-metal-goto))
  (xwidget-metal-refit)
  )

(defun xwidget-metal-refit ()
  (interactive)
  ;; Nudge the window by 1px then back to force a relayout/redisplay so
  ;; the metal widget resizes to fit.  `window-resize' errors on the
  ;; frame's sole (root) window ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent
  ;; (a sibling to trade space with); `window-resizable' is NOT a
  ;; reliable guard here (it returns 0 for the root window).  So check
  ;; `window-parent'; otherwise just force a redisplay.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-metal-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;filament
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun xwidget-filament-adjust-size-to-content ()
  "Adjust webkit to content size."
  (interactive nil xwidget-filament-mode)
  (xwidget-adjust-size-to-content (xwidget-filament-current-session)))

(defun xwidget-filament-adjust-size-dispatch ()
  "Adjust size according to mode."
  (interactive nil xwidget-filament-mode)
  (xwidget-filament-adjust-size-to-window (xwidget-filament-current-session))
  ;; The recenter is intended to correct a visual glitch.
  ;; It errors out if the buffer isn't visible, but then we don't get
  ;; the glitch, so silence errors.
  (ignore-errors
    (recenter-top-bottom)))

;; Utility functions

(defun xwidget-filament-adjust-size-to-window (xwidget &optional window)
  "Adjust the size of the webkit XWIDGET to fit the WINDOW."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-filament-adjust-size (w h)
  "Manually set webkit size to width W, height H."
  ;; TODO shouldn't be tied to the webkit xwidget
  (interactive "nWidth:\nnHeight:\n" xwidget-filament-mode)
  (xwidget-resize (xwidget-filament-current-session) w h))

(defun xwidget-filament-fit-width ()
  "Adjust width of webkit to window width."
  (interactive nil xwidget-filament-mode)
  (xwidget-filament-adjust-size (- (nth 2 (window-inside-pixel-edges))
                                 (car (window-inside-pixel-edges)))
                              1000))

(defun xwidget-filament-auto-adjust-size (window)
  "Adjust the size of the webkit widget in the given WINDOW."
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-filament-mode)
      (let ((xwidget (xwidget-filament-current-session)))
        (xwidget-filament-adjust-size-to-window xwidget window)))))

(defun xwidget-filament-adjust-size-in-frame (frame)
  "Dynamically adjust webkit widget for all windows of the FRAME."
  (walk-windows 'xwidget-filament-auto-adjust-size 'no-minibuf frame))

(eval-after-load 'xwidget-filament-mode
  (add-to-list 'window-size-change-functions
               'xwidget-filament-adjust-size-in-frame))

(defvar xwidget-filament-last-session-buffer nil)

(defun xwidget-filament-last-session ()
  (if (buffer-live-p xwidget-filament-last-session-buffer)
      (with-current-buffer xwidget-filament-last-session-buffer
        (xwidget-at (point-min)))
      nil))

(defun xwidget-filament-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type))
          )
      )
  )

(defun xwidget-filament-buffer-kill ()
  )

(defvar xwidget-filament-mode-map
  (let ((map (make-sparse-keymap)))
   map)
  "Keymap for `xwidget-filament-mode'.")


(define-derived-mode xwidget-filament-mode special-mode "xwidget-filament"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-filament-buffer-kill)
  ;;(setq-local tool-bar-map xwidget-filament-tool-bar-map)
  (image-mode-setup-winprops)
  )

(defun xwidget-filament-current-session ()
  (or (xwidget-at (point-min)) (xwidget-filament-last-session))
  )

(defun xwidget-filament-import-widget (xwidget)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-filament-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-filament-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-filament-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-filament-mode)
      )
    buffer))

(defun xwidget-filament-display-callback (xwidget _source)
  (display-buffer (xwidget-filament-import-widget xwidget))
  )

(defun xwidget-filament-display ()
  (interactive)
  (display-buffer (xwidget-filament-import-widget (xwidget-filament-current-session)))
  )

(defun xwidget-filament--create-new-session-buffer (&optional callback)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-filament-callback))
         (current-session (xwidget-filament-current-session))
         xw
         )
    (setq xwidget-filament-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-filament-last-session-buffer
      (let ((start (point)))
        (insert "filament")
        (put-text-property start (+ start (length "filament")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'filament bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session))
        )
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-filament-display-callback)
      (xwidget-filament-mode)
      )
    xwidget-filament-last-session-buffer))

(defun xwidget-filament-new-session ()
  (switch-to-buffer (xwidget-filament--create-new-session-buffer)))

(defun xwidget-filament-goto ()
  (if (xwidget-filament-current-session)
      (progn
        (switch-to-buffer (xwidget-buffer (xwidget-filament-current-session))))
    (xwidget-filament-new-session)
    ))

;;;###autoload
(defun xwidget-filament-browse (&optional new-session)
  (interactive)
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-filament-new-session)
    (xwidget-filament-goto))
  ;;(xwidget-filament-refit)
  )

(defun xwidget-filament-refit ()
  (interactive)
  ;; See `xwidget-metal-refit': guard against resizing the frame's sole
  ;; (root) window, which errors ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-filament-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;bgfx
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar xwidget-bgfx-last-session-buffer nil)

(defun xwidget-bgfx-last-session ()
  (if (buffer-live-p xwidget-bgfx-last-session-buffer)
      (with-current-buffer xwidget-bgfx-last-session-buffer
        (xwidget-at (point-min)))
    nil))

(defun xwidget-bgfx-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type)))))

(defun xwidget-bgfx-buffer-kill ())

(defvar xwidget-bgfx-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `xwidget-bgfx-mode'.")

(define-derived-mode xwidget-bgfx-mode special-mode "xwidget-bgfx"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-bgfx-buffer-kill)
  (image-mode-setup-winprops))

(defun xwidget-bgfx-current-session ()
  (or (xwidget-at (point-min)) (xwidget-bgfx-last-session)))

(defun xwidget-bgfx-display-callback (xwidget _source)
  (display-buffer (xwidget-bgfx-import-widget xwidget)))

(defun xwidget-bgfx-import-widget (xwidget)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-bgfx-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-bgfx-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-bgfx-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-bgfx-mode))
    buffer))

(defun xwidget-bgfx--create-new-session-buffer (&optional callback)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-bgfx-callback))
         (current-session (xwidget-bgfx-current-session))
         xw)
    (setq xwidget-bgfx-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-bgfx-last-session-buffer
      (let ((start (point)))
        (insert "bgfx")
        (put-text-property start (+ start (length "bgfx")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'bgfx bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session)))
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-bgfx-display-callback)
      (xwidget-bgfx-mode))
    xwidget-bgfx-last-session-buffer))

(defun xwidget-bgfx-new-session ()
  (switch-to-buffer (xwidget-bgfx--create-new-session-buffer)))

(defun xwidget-bgfx-goto ()
  (if (xwidget-bgfx-current-session)
      (switch-to-buffer (xwidget-buffer (xwidget-bgfx-current-session)))
    (xwidget-bgfx-new-session)))

;;;###autoload
(defun xwidget-bgfx-browse (&optional new-session)
  (interactive)
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-bgfx-new-session)
    (xwidget-bgfx-goto)))

(defun xwidget-bgfx-refit ()
  (interactive)
  ;; See `xwidget-metal-refit': guard against resizing the frame's sole
  ;; (root) window, which errors ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-bgfx-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun xwidget-vulkan-adjust-size-to-content ()
  "Adjust webkit to content size."
  (interactive nil xwidget-vulkan-mode)
  (xwidget-adjust-size-to-content (xwidget-vulkan-current-session)))

(defun xwidget-vulkan-adjust-size-dispatch ()
  "Adjust size according to mode."
  (interactive nil xwidget-vulkan-mode)
  (xwidget-vulkan-adjust-size-to-window (xwidget-vulkan-current-session))
  ;; The recenter is intended to correct a visual glitch.
  ;; It errors out if the buffer isn't visible, but then we don't get
  ;; the glitch, so silence errors.
  (ignore-errors
    (recenter-top-bottom)))

;; Utility functions

(defun xwidget-vulkan-adjust-size-to-window (xwidget &optional window)
  "Adjust the size of the webkit XWIDGET to fit the WINDOW."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-vulkan-adjust-size (w h)
  "Manually set webkit size to width W, height H."
  ;; TODO shouldn't be tied to the webkit xwidget
  (interactive "nWidth:\nnHeight:\n" xwidget-vulkan-mode)
  (xwidget-resize (xwidget-vulkan-current-session) w h))

(defun xwidget-vulkan-fit-width ()
  "Adjust width of webkit to window width."
  (interactive nil xwidget-vulkan-mode)
  (xwidget-vulkan-adjust-size (- (nth 2 (window-inside-pixel-edges))
                                 (car (window-inside-pixel-edges)))
                              1000))

(defun xwidget-vulkan-auto-adjust-size (window)
  "Adjust the size of the webkit widget in the given WINDOW."
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-vulkan-mode)
      (let ((xwidget (xwidget-vulkan-current-session)))
        (xwidget-vulkan-adjust-size-to-window xwidget window)))))

(defun xwidget-vulkan-adjust-size-in-frame (frame)
  "Dynamically adjust webkit widget for all windows of the FRAME."
  (walk-windows 'xwidget-vulkan-auto-adjust-size 'no-minibuf frame))

(eval-after-load 'xwidget-vulkan-mode
  (add-to-list 'window-size-change-functions
               'xwidget-vulkan-adjust-size-in-frame))

(defvar xwidget-vulkan-last-session-buffer nil)

(defun xwidget-vulkan-last-session ()
  (if (buffer-live-p xwidget-vulkan-last-session-buffer)
      (with-current-buffer xwidget-vulkan-last-session-buffer
        (xwidget-at (point-min)))
      nil))

(defun xwidget-vulkan-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type))
          )
      )
  )

(defun xwidget-vulkan-buffer-kill ()
  )

(defvar xwidget-vulkan-mode-map
  (let ((map (make-sparse-keymap)))
   map)
  "Keymap for `xwidget-vulkan-mode'.")


(define-derived-mode xwidget-vulkan-mode special-mode "xwidget-vulkan"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-vulkan-buffer-kill)
  ;;(setq-local tool-bar-map xwidget-vulkan-tool-bar-map)
  (image-mode-setup-winprops)
  )

(defun xwidget-vulkan-current-session ()
  (or (xwidget-at (point-min)) (xwidget-vulkan-last-session))
  )

(defun xwidget-vulkan-import-widget (xwidget)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-vulkan-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-vulkan-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-vulkan-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-vulkan-mode)
      )
    buffer))

(defun xwidget-vulkan-display-callback (xwidget _source)
  (display-buffer (xwidget-vulkan-import-widget xwidget))
  )

(defun xwidget-vulkan-display ()
  (interactive)
  (display-buffer (xwidget-vulkan-import-widget (xwidget-vulkan-current-session)))
  )

(defun xwidget-vulkan--create-new-session-buffer (&optional callback)
  (let* ((bufname
          (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-vulkan-callback))
         (current-session (xwidget-vulkan-current-session))
         xw
         )
    (setq xwidget-vulkan-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-vulkan-last-session-buffer
      (let ((start (point)))
        (insert "vulkan")
        (put-text-property start (+ start (length "vulkan")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'vulkan bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session))
        )
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-vulkan-display-callback)
      (xwidget-vulkan-mode)
      )
    xwidget-vulkan-last-session-buffer))

(defun xwidget-vulkan-new-session ()
  (switch-to-buffer (xwidget-vulkan--create-new-session-buffer)))

(defun xwidget-vulkan-goto ()
  (if (xwidget-vulkan-current-session)
      (progn
        (switch-to-buffer (xwidget-buffer (xwidget-vulkan-current-session))))
    (xwidget-vulkan-new-session)
    ))

;;;###autoload
(defun xwidget-vulkan-browse (&optional new-session)
  (interactive)
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-vulkan-new-session)
    (xwidget-vulkan-goto))
  ;;(xwidget-vulkan-refit)
  )

(defun xwidget-vulkan-refit ()
  (interactive)
  ;; See `xwidget-metal-refit': guard against resizing the frame's sole
  ;; (root) window, which errors ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-vulkan-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;dawn
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar xwidget-dawn-last-session-buffer nil)

(defun xwidget-dawn-last-session ()
  (if (buffer-live-p xwidget-dawn-last-session-buffer)
      (with-current-buffer xwidget-dawn-last-session-buffer
        (xwidget-at (point-min)))
    nil))

(defun xwidget-dawn-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type)))))

(defun xwidget-dawn-buffer-kill ())

(defvar xwidget-dawn-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `xwidget-dawn-mode'.")

(define-derived-mode xwidget-dawn-mode special-mode "xwidget-dawn"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-dawn-buffer-kill)
  (image-mode-setup-winprops))

(defun xwidget-dawn-current-session ()
  (or (xwidget-at (point-min)) (xwidget-dawn-last-session)))

(defun xwidget-dawn-display-callback (xwidget _source)
  (display-buffer (xwidget-dawn-import-widget xwidget)))

(defun xwidget-dawn-import-widget (xwidget)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-dawn-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-dawn-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-dawn-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-dawn-mode))
    buffer))

(defun xwidget-dawn--create-new-session-buffer (&optional callback)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-dawn-callback))
         (current-session (xwidget-dawn-current-session))
         xw)
    (setq xwidget-dawn-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-dawn-last-session-buffer
      (let ((start (point)))
        (insert "dawn")
        (put-text-property start (+ start (length "dawn")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'dawn bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session)))
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-dawn-display-callback)
      (xwidget-dawn-mode))
    xwidget-dawn-last-session-buffer))

(defun xwidget-dawn-new-session ()
  (switch-to-buffer (xwidget-dawn--create-new-session-buffer)))

(defun xwidget-dawn-goto ()
  (if (xwidget-dawn-current-session)
      (switch-to-buffer (xwidget-buffer (xwidget-dawn-current-session)))
    (xwidget-dawn-new-session)))

;;;###autoload
(defun xwidget-dawn-browse (&optional new-session)
  (interactive)
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-dawn-new-session)
    (xwidget-dawn-goto)))

(defun xwidget-dawn-refit ()
  (interactive)
  ;; See `xwidget-metal-refit': guard against resizing the frame's sole
  ;; (root) window, which errors ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-dawn-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;slate
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar xwidget-slate-last-session-buffer nil)

(defun xwidget-slate-last-session ()
  (if (buffer-live-p xwidget-slate-last-session-buffer)
      (with-current-buffer xwidget-slate-last-session-buffer
        (xwidget-at (point-min)))
    nil))

(defun xwidget-slate-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type)))))

(defun xwidget-slate-buffer-kill ())

(defvar xwidget-slate-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `xwidget-slate-mode'.")

(define-derived-mode xwidget-slate-mode special-mode "xwidget-slate"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-slate-buffer-kill)
  (image-mode-setup-winprops))

(defun xwidget-slate-current-session ()
  (or (xwidget-at (point-min)) (xwidget-slate-last-session)))

(defun xwidget-slate-display-callback (xwidget _source)
  (display-buffer (xwidget-slate-import-widget xwidget)))

(defun xwidget-slate-import-widget (xwidget)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-slate-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-slate-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-slate-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-slate-mode))
    buffer))

(defun xwidget-slate--create-new-session-buffer (&optional callback)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-slate-callback))
         (current-session (xwidget-slate-current-session))
         xw)
    (setq xwidget-slate-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-slate-last-session-buffer
      (let ((start (point)))
        (insert "slate")
        (put-text-property start (+ start (length "slate")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'slate bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  nil current-session)))
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-slate-display-callback)
      (xwidget-slate-mode))
    xwidget-slate-last-session-buffer))

(defun xwidget-slate-new-session ()
  (switch-to-buffer (xwidget-slate--create-new-session-buffer)))

(defun xwidget-slate-goto ()
  (if (xwidget-slate-current-session)
      (switch-to-buffer (xwidget-buffer (xwidget-slate-current-session)))
    (xwidget-slate-new-session)))

;;;###autoload
(defun xwidget-slate-browse (&optional new-session)
  "Display an Unreal Slate xwidget (embedded engine, offscreen-rendered).
With a prefix argument NEW-SESSION, force a fresh session buffer."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-slate-new-session)
    (xwidget-slate-goto)))

;;;###autoload
(defun xwidget-slate-viewer-browse (&optional new-session)
  "Display SlateViewer's Starship widget gallery in an Unreal Slate xwidget.
Same embedded-engine offscreen rendering as `xwidget-slate-browse', but shows
the interactive Slate demo UI (buttons, sliders, ...) instead of the triangle,
and forwards mouse/keyboard input into it.

The embedded engine is a per-process singleton: its content is chosen the first
time a slate xwidget is created.  This command sets $SLATE_OFFSCREEN_CONTENT to
\"gallery\" so that first init selects the gallery.  If a triangle slate session
was already started in this Emacs, restart Emacs before switching content.
With a prefix argument NEW-SESSION, force a fresh session buffer."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if (fboundp 'xwidget-slate-set-content)
      (xwidget-slate-set-content "gallery")
    ;; Fallback: plain setenv only updates `process-environment', which the
    ;; embedded engine's getenv() cannot see, so this won't take effect unless
    ;; the primitive is available.
    (setenv "SLATE_OFFSCREEN_CONTENT" "gallery"))
  (if new-session
      (xwidget-slate-new-session)
    (xwidget-slate-goto)))

;;;###autoload
(defun xwidget-slate-editor-browse (&optional new-session)
  "Display the full Unreal Editor UI (docked panels) in an Unreal Slate xwidget.
Boots the real editor engine in-process (UUnrealEdEngine + the default MainFrame:
menu bar, Level Editor, Content Browser, Details, Outliner) and composites its
offscreen-rendered frame into the xwidget via the shared IOSurface.

The editor is driven with a widgets-only Slate tick (no platform/FMacApplication
polling, which would crash on the engine's game thread).  The embedded engine is
a per-process singleton, so content is fixed at first slate-xwidget creation:
this sets $SLATE_OFFSCREEN_CONTENT=editor.  If another slate session (triangle/
gallery) was already started in this Emacs, restart Emacs before switching.
With a prefix argument NEW-SESSION, force a fresh session buffer.

NOTE: editor bring-up is heavy (shader compile, asset registry) -- the first
frame can take many seconds.  Point at a real project by launching Emacs with a
game .uproject configured if you want its assets in the Content Browser."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if (fboundp 'xwidget-slate-set-content)
      (xwidget-slate-set-content "editor")
    (setenv "SLATE_OFFSCREEN_CONTENT" "editor"))
  (if new-session
      (xwidget-slate-new-session)
    (xwidget-slate-goto)))

;;;###autoload
(defun xwidget-slate-canvas-browse (&optional new-session)
  "Draw a triangle via Unreal's render library (FCanvas) in a Slate xwidget.
Unlike `xwidget-slate-browse' (which draws the triangle with Slate's
FSlateDrawElement), this uses the engine's FCanvas/FCanvasTriangleItem RHI
triangle renderer to draw directly into the offscreen render target.  It
constructs a bare UEngine (no full GEngineLoop.Init) because FCanvas's
FSceneView requires a non-null GEngine.

The embedded engine is a per-process singleton, so content is fixed at first
slate-xwidget creation: this sets $SLATE_OFFSCREEN_CONTENT=canvas.  If another
slate session was already started in this Emacs, restart Emacs before switching.
With a prefix argument NEW-SESSION, force a fresh session buffer."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if (fboundp 'xwidget-slate-set-content)
      (xwidget-slate-set-content "canvas")
    (setenv "SLATE_OFFSCREEN_CONTENT" "canvas"))
  (if new-session
      (xwidget-slate-new-session)
    (xwidget-slate-goto)))

(defun xwidget-slate-refit ()
  (interactive)
  ;; See `xwidget-metal-refit': guard against resizing the frame's sole
  ;; (root) window, which errors ("Cannot resize the root window of a
  ;; frame").  A window is only resizable this way when it has a parent.
  (let ((win (get-buffer-window
              (xwidget-buffer (xwidget-slate-current-session)))))
    (when win
      (if (window-parent win)
          (progn
            (window-resize win 1 t)
            (window-resize win -1 t))
        (force-window-update win)))))

;; Auto-resize the slate xwidget when its Emacs window changes size.  Mirrors
;; `xwidget-metal-adjust-size-in-frame' (the slate mode previously had no such
;; handler, so the embedded engine kept its original size when the window
;; changed).  `xwidget-resize' -> nsxwidget_resize resizes the MTKView, which
;; fires drawableSizeWillChange: -> SlateOffscreen_Resize on the engine.
(defun xwidget-slate-adjust-size-to-window (xwidget &optional window)
  "Resize the slate XWIDGET to fill WINDOW (or the selected window)."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-slate-auto-adjust-size (window)
  "Resize the slate widget shown in WINDOW to fit it."
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-slate-mode)
      (let ((xwidget (xwidget-slate-current-session)))
        (when xwidget
          (xwidget-slate-adjust-size-to-window xwidget window)
          ;; Mark the window for redisplay so its xwidget glyph is redrawn,
          ;; which runs `x_draw_xwidget_glyph_string' -> resizes the on-screen
          ;; clip container to the new size.  Without this the buffer text is
          ;; unchanged, so redisplay would skip the glyph row and the widget
          ;; would keep its old on-screen size until the next full redisplay.
          (force-window-update window))))))

(defvar xwidget-slate--resize-timer nil
  "Idle timer coalescing slate xwidget resizes to fit their windows.")

(defun xwidget-slate--do-adjust-in-frame (frame)
  "Resize every slate xwidget in FRAME to fit its window."
  (setq xwidget-slate--resize-timer nil)
  (when (frame-live-p frame)
    (walk-windows #'xwidget-slate-auto-adjust-size 'no-minibuf frame)))

(defun xwidget-slate-adjust-size-in-frame (frame)
  "Schedule a fit of every slate widget in FRAME to its window.
Runs from `window-size-change-functions', which executes *inside* redisplay --
where `xwidget-resize's own redisplay is a no-op and the glyph row is not
redrawn.  Defer the actual resize to a zero-delay idle timer so it runs in the
command loop (outside redisplay), where the resize and clip update take effect;
this is why a plain window drag previously needed a manual redisplay (e.g. M-x)
to catch up."
  (when (timerp xwidget-slate--resize-timer)
    (cancel-timer xwidget-slate--resize-timer))
  (setq xwidget-slate--resize-timer
        (run-with-idle-timer 0 nil #'xwidget-slate--do-adjust-in-frame frame)))

(add-hook 'window-size-change-functions #'xwidget-slate-adjust-size-in-frame)

;; Cleanly stop the embedded Unreal engine when Emacs exits.  This runs during
;; Fkill_emacs, BEFORE the C exit() that would otherwise run the engine's static
;; destructors on the host thread and crash.  `xwidget-slate-shutdown' is a
;; no-op (returns normally) if no slate xwidget was ever created; only when one
;; was does it stop the engine and hard-exit the process.
(when (fboundp 'xwidget-slate-shutdown)
  (add-hook 'kill-emacs-hook #'xwidget-slate-shutdown))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;godot
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar xwidget-godot-last-session-buffer nil)

(defvar xwidget-godot-default-project
  (expand-file-name
   "~/sourcecode/Settings/macbuild/gameengine/godot/godot-offscreen/triangle-project")
  "Default Godot project used by `xwidget-godot-browse'.")

(defun xwidget-godot-last-session ()
  (if (buffer-live-p xwidget-godot-last-session-buffer)
      (with-current-buffer xwidget-godot-last-session-buffer
        (xwidget-at (point-min)))
    nil))

(defun xwidget-godot-callback (xwidget xwidget-event-type)
  (if (not (buffer-live-p (xwidget-buffer xwidget)))
      (xwidget-log "error: callback called for xwidget with dead buffer")
    (cond (t (xwidget-log "unhandled event:%s" xwidget-event-type)))))

(defun xwidget-godot-buffer-kill ())

(defvar xwidget-godot-mode-map
  (let ((map (make-sparse-keymap)))
    map)
  "Keymap for `xwidget-godot-mode'.")

(define-derived-mode xwidget-godot-mode special-mode "xwidget-godot"
  (setq buffer-read-only t)
  (add-hook 'kill-buffer-hook #'xwidget-godot-buffer-kill)
  (image-mode-setup-winprops))

(defun xwidget-godot-current-session ()
  (or (xwidget-at (point-min)) (xwidget-godot-last-session)))

(defun xwidget-godot-display-callback (xwidget _source)
  (display-buffer (xwidget-godot-import-widget xwidget)))

(defun xwidget-godot-import-widget (xwidget)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback #'xwidget-godot-callback)
         (buffer (get-buffer-create bufname)))
    (with-current-buffer buffer
      (setq xwidget-godot-last-session-buffer buffer)
      (save-excursion
        (erase-buffer)
        (insert ".")
        (put-text-property (point-min) (point-max)
                           'display (list 'xwidget :xwidget xwidget)))
      (xwidget-put xwidget 'callback callback)
      (xwidget-put xwidget 'display-callback #'xwidget-godot-display-callback)
      (set-xwidget-buffer xwidget buffer)
      (xwidget-godot-mode))
    buffer))

(defun xwidget-godot--create-new-session-buffer (&optional callback editor project)
  (let* ((bufname (generate-new-buffer-name (buffer-name)))
         (callback (or callback #'xwidget-godot-callback))
         (current-session (xwidget-godot-current-session))
         xw)
    (setq xwidget-godot-last-session-buffer (get-buffer-create bufname))
    (with-current-buffer xwidget-godot-last-session-buffer
      (let ((start (point)))
        (insert "godot")
        (put-text-property start (+ start (length "godot")) 'invisible t)
        (setq xw (xwidget-insert
                  start 'godot bufname
                  (xwidget-window-inside-pixel-width (selected-window))
                  (xwidget-window-inside-pixel-height (selected-window))
                  (list :editor editor :project project) current-session)))
      (xwidget-put xw 'callback callback)
      (xwidget-put xw 'display-callback #'xwidget-godot-display-callback)
      (xwidget-godot-mode))
    xwidget-godot-last-session-buffer))

(defun xwidget-godot-new-session (&optional editor project)
  (switch-to-buffer (xwidget-godot--create-new-session-buffer nil editor project)))

(defun xwidget-godot-goto (&optional editor project)
  (if (xwidget-godot-current-session)
      (switch-to-buffer (xwidget-buffer (xwidget-godot-current-session)))
    (xwidget-godot-new-session editor project)))

;;;###autoload
(defun xwidget-godot-editor-browse (&optional new-session)
  "Display the Godot editor embedded in an xwidget.
Boots the (patched, tools-enabled) libgodot via libGodotOffscreen with the
embedded macOS display server, and hosts its rendered CAMetalLayer in the
xwidget via a CALayerHost.

Boots straight into `xwidget-godot-default-project' (passing --path) rather
than the Project Manager.  This matters for the in-process embedding: the
Project Manager's \"Open\" spawns a new process via the host bundle, which would
launch another emacs-fswork instead of Godot.  (Opening a *different* project or
Run/restart from inside the editor is redirected to standalone Godot by the
OS_MacOS_Embedded::create_instance patch.)

The embedded engine is a per-process singleton: content is fixed at first godot
xwidget creation.
With a prefix argument NEW-SESSION, force a fresh session buffer.

NOTE: first frame can take a few seconds (shader compile)."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-godot-new-session t xwidget-godot-default-project)
    (xwidget-godot-goto t xwidget-godot-default-project)))

;;;###autoload
(defun xwidget-godot-browse (&optional new-session)
  "Display the default embedded Godot triangle project in an xwidget.
This starts Godot in run mode, not editor mode.  The embedded engine is a
per-process singleton, so use this as the first Godot xwidget in a fresh Emacs
process when you want the triangle instead of the editor.
With a prefix argument NEW-SESSION, force a fresh session buffer."
  (interactive "P")
  (or (featurep 'xwidget-internal)
      (user-error "Your Emacs was not compiled with xwidgets support"))
  (if new-session
      (xwidget-godot-new-session nil xwidget-godot-default-project)
    (xwidget-godot-goto nil xwidget-godot-default-project)))

(defun xwidget-godot-adjust-size-to-window (xwidget &optional window)
  "Resize the godot XWIDGET to fill WINDOW."
  (xwidget-resize xwidget
                  (xwidget-window-inside-pixel-width window)
                  (xwidget-window-inside-pixel-height window)))

(defun xwidget-godot-auto-adjust-size (window)
  (with-current-buffer (window-buffer window)
    (when (eq major-mode 'xwidget-godot-mode)
      (let ((xwidget (xwidget-godot-current-session)))
        (when xwidget
          (xwidget-godot-adjust-size-to-window xwidget window)
          (force-window-update window))))))

(defvar xwidget-godot--resize-timer nil)

(defun xwidget-godot--do-adjust-in-frame (frame)
  (setq xwidget-godot--resize-timer nil)
  (when (frame-live-p frame)
    (walk-windows #'xwidget-godot-auto-adjust-size 'no-minibuf frame)))

(defun xwidget-godot-adjust-size-in-frame (frame)
  "Schedule a fit of every godot widget in FRAME (deferred; see slate variant)."
  (when (timerp xwidget-godot--resize-timer)
    (cancel-timer xwidget-godot--resize-timer))
  (setq xwidget-godot--resize-timer
        (run-with-idle-timer 0 nil #'xwidget-godot--do-adjust-in-frame frame)))

(add-hook 'window-size-change-functions #'xwidget-godot-adjust-size-in-frame)

;; Cleanly stop the embedded Godot engine when Emacs exits (see slate variant).
(when (fboundp 'xwidget-godot-shutdown)
  (add-hook 'kill-emacs-hook #'xwidget-godot-shutdown))

(provide 'xwidget)
;;; xwidget.el ends here
