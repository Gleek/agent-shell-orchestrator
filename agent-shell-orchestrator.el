;;; agent-shell-orchestrator.el --- Coordinate native agent shells -*- lexical-binding: t; -*-

;; Author: Umar Ahmad
;; Version: 0.1.0
;; URL: https://github.com/Gleek/agent-shell-orchestrator
;; Package-Requires: ((emacs "29.1") (agent-shell "0.87.10"))
;; Keywords: convenience, tools

;;; Commentary:

;; Small functions for coordinating ordinary agent-shell sessions.  Targets
;; are buffers or exact buffer names; no controller or task tracker is required.

;;; Code:

(require 'cl-lib)
(require 'agent-shell)
(require 'project)

(defgroup agent-shell-orchestrator nil
  "Coordinate native agent-shell sessions."
  :group 'applications
  :prefix "agent-shell-orchestrator-")

(defun agent-shell-orchestrator--buffer (target)
  "Resolve TARGET to an existing native shell, without project fallback."
  (let ((buffer (and (or (bufferp target) (stringp target))
                     (get-buffer target))))
    (unless (memq buffer (agent-shell-buffers))
      (user-error "No agent shell named %S" target))
    buffer))

(defun agent-shell-orchestrator--message-p (message)
  "Return non-nil for a nonblank MESSAGE string."
  (and (stringp message) (not (string-empty-p (string-trim message)))))

(defun agent-shell-orchestrator--pending ()
  "Return the current shell's native pending prompts."
  (agent-shell--prompt-queue-migrate)
  (map-elt agent-shell--state :pending-prompts))

(defun agent-shell-orchestrator--status ()
  "Return current shell status, including initialization."
  (if (agent-shell-initialized-p) (agent-shell-status) 'starting))

(cl-defun agent-shell-orchestrator-list (&key project buffers)
  "Return session plists, optionally filtered by PROJECT and BUFFERS.
PROJECT is a directory belonging to the desired Emacs project, or an
exact working directory when no project is detected.  BUFFERS is a list
of buffers or exact names.  When both are supplied, apply both filters.
Results contain :buffer, :name, :directory, :status, :queued and
:transcript-file.  The transcript path is nil when unavailable; the file
may not exist yet before the shell writes its first transcript entry."
  (let* ((root (lambda (directory)
                 (file-truename
                  (file-name-as-directory
                   (if-let* ((project (project-current nil directory)))
                       (project-root project)
                     directory)))))
         (directory (and project (funcall root project))))
    (cl-loop for buffer in (if buffers
                               (mapcar #'agent-shell-orchestrator--buffer buffers)
                             (agent-shell-buffers))
             when (or (not directory)
                      (equal directory
                             (funcall root (buffer-local-value 'default-directory buffer))))
             collect (with-current-buffer buffer
                       (list :buffer buffer :name (buffer-name)
                             :directory default-directory
                             :transcript-file agent-shell--transcript-file
                             :status (agent-shell-orchestrator--status)
                             :queued (length (agent-shell-orchestrator--pending)))))))

(defun agent-shell-orchestrator--process-queue ()
  "Process native prompts while preserving the current unsent draft.
Also restore drafts when the persistent prompt is disabled."
  (let* ((start (agent-shell--prompt-input-start))
         (draft (and start (buffer-substring start (point-max))))
         restore)
    (when start (delete-region start (point-max)))
    (setq restore
          (lambda ()
            (when (agent-shell--prompt-input-start)
              (remove-hook 'shell-maker-finish-output-hook restore t)
              (when draft
                (save-excursion (goto-char (point-max)) (insert draft))
                (setq draft nil)))))
    (add-hook 'shell-maker-finish-output-hook restore nil t)
    (unwind-protect
        (agent-shell--prompt-queue-process-next)
      (funcall restore))))

(defvar-local agent-shell-orchestrator--startup-subscription nil
  "Native subscription for draining prompts after startup.")

(defun agent-shell-orchestrator--await-startup ()
  "Arrange native queue delivery once the current shell is ready."
  (unless agent-shell-orchestrator--startup-subscription
    (let ((buffer (current-buffer)))
      (setq agent-shell-orchestrator--startup-subscription
            (agent-shell-subscribe-to
             :shell-buffer buffer :event 'init-finished
             :on-event
             (lambda (_event)
               (with-current-buffer buffer
                 (agent-shell-unsubscribe
                  :subscription agent-shell-orchestrator--startup-subscription)
                 (setq agent-shell-orchestrator--startup-subscription nil))
               ;; Let initialization finish.  Newer agent-shell versions may
               ;; drain the queue themselves before this callback runs.
               (run-at-time
                0 nil
                (lambda ()
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (when (and (agent-shell-initialized-p)
                                 (not (shell-maker-busy))
                                 (agent-shell-orchestrator--pending))
                        (agent-shell-orchestrator--process-queue))))))))))))

(cl-defun agent-shell-orchestrator-send (target message &key (delivery 'queue))
  "Send MESSAGE to TARGET using DELIVERY, either `queue' or `steer'.
Queue delivery submits immediately when idle and waits while starting or
busy.  Steer requires an initialized shell; native steering may interrupt
if the agent declines it.  Return :buffer, :delivery and :queued.
A delivery result does not imply acknowledgement by the agent."
  (unless (agent-shell-orchestrator--message-p message)
    (user-error "Message must be a nonempty string"))
  (unless (memq delivery '(queue steer))
    (user-error "Delivery must be queue or steer"))
  (with-current-buffer (agent-shell-orchestrator--buffer target)
    (save-excursion
      (let ((starting (not (agent-shell-initialized-p)))
            (busy (shell-maker-busy))
            result)
        (cond
         ((and (eq delivery 'steer) starting)
          (user-error "Cannot steer a shell that is still starting"))
         ((and (eq delivery 'steer) busy)
          (agent-shell-prompt-steer message)
          (setq result 'steered))
         (t
          (when starting (agent-shell-orchestrator--await-startup))
          (agent-shell--prompt-queue-enqueue :prompt message)
          (if (or starting busy)
              (setq result 'queued)
            (agent-shell-orchestrator--process-queue)
            (setq result 'submitted))))
        (list :buffer (current-buffer) :delivery result
              :queued (length (agent-shell-orchestrator--pending)))))))

(cl-defun agent-shell-orchestrator-create (directory &key name prompt config)
  "Create a native shell in DIRECTORY without selecting it.
NAME, when supplied, is an exact buffer name and must be unused.
PROMPT is delivered when ready.  CONFIG defaults to agent-shell's
preferred agent configuration.  Return the new buffer."
  (unless (file-directory-p directory)
    (user-error "No directory %S" directory))
  (when (and name (or (not (agent-shell-orchestrator--message-p name))
                      (get-buffer name)))
    (user-error "Name must be nonempty and unused: %S" name))
  (when (and prompt (not (agent-shell-orchestrator--message-p prompt)))
    (user-error "Prompt must be a nonempty string"))
  (let ((buffer (agent-shell--start
                 :config (or config (agent-shell--auto-preferred-config))
                 :cwd (expand-file-name directory) :no-focus t
                 :new-session t :session-strategy 'new)))
    (when name (shell-maker-set-buffer-name buffer name))
    (when prompt (agent-shell-orchestrator-send buffer prompt))
    buffer))

(defun agent-shell-orchestrator-queue (target)
  "Return a copy of TARGET's pending prompts in native queue order."
  (with-current-buffer (agent-shell-orchestrator--buffer target)
    (copy-tree (agent-shell-orchestrator--pending))))

(defun agent-shell-orchestrator-remove-queued (target index)
  "Remove and return TARGET's queued prompt at zero-based INDEX.
Inspect the queue before removal; indexes refer to its current state."
  (with-current-buffer (agent-shell-orchestrator--buffer target)
    (let ((pending (agent-shell-orchestrator--pending)))
      (unless (and (integerp index) (<= 0 index) (< index (length pending)))
        (user-error "No queued prompt at index %S" index))
      (prog1 (nth index pending)
        (map-put! agent-shell--state :pending-prompts
                  (append (seq-take pending index) (seq-drop pending (1+ index))))))))

(provide 'agent-shell-orchestrator)
;;; agent-shell-orchestrator.el ends here
