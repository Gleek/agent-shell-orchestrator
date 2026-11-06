;;; agent-shell-orchestrator-test.el --- Functional tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-shell-orchestrator)

(defmacro agent-shell-orchestrator-test--shell (&rest body)
  "Run BODY in an isolated shell using real native queue helpers."
  (declare (indent 0))
  `(with-temp-buffer
     (setq major-mode 'agent-shell-mode)
     (setq-local shell-maker--config (make-shell-maker-config :name "Agent"))
     (setq-local agent-shell--state
                 (list (cons :buffer (current-buffer))
                       (cons :session '((:id . "test")))
                       (cons :init-finished t)
                       (cons :pending-prompts nil)
                       (cons :event-subscriptions nil)
                       (cons :supports-steering nil)))
     (insert "Agent> ")
     (setq-local comint-last-prompt (cons (copy-marker 1) (copy-marker (point))))
     (let (submitted)
       ;; Only the submission boundary is replaced.  Selection, queueing,
       ;; prompt insertion, draft handling and subscriptions are native.
       (cl-letf (((symbol-function 'shell-maker-submit)
                  (lambda (&rest _)
                    (push (agent-shell--prompt-input) submitted)
                    (delete-region (agent-shell--prompt-input-start) (point-max)))))
         ,@body))))

(ert-deftest agent-shell-orchestrator-test-idle-send ()
  (agent-shell-orchestrator-test--shell
    (let ((source (current-buffer))
          (window (selected-window)))
      (insert "  draft\n ")
      (with-temp-buffer
        (let ((caller (current-buffer)))
          (should (eq 'submitted
                      (plist-get (agent-shell-orchestrator-send source "hello") :delivery)))
          (should (eq caller (current-buffer)))
          (should (eq window (selected-window)))))
      (should (equal submitted '("hello")))
      (should (equal (buffer-substring (agent-shell--prompt-input-start) (point-max))
                     "  draft\n ")))))

(ert-deftest agent-shell-orchestrator-test-busy-queue-and-removal ()
  (agent-shell-orchestrator-test--shell
    (setq-local shell-maker--busy t)
    (insert "draft")
    (should (eq 'queued (plist-get (agent-shell-orchestrator-send (current-buffer) "one")
                                       :delivery)))
    (agent-shell-orchestrator-send (current-buffer) "two")
    (agent-shell-orchestrator-send (current-buffer) "three")
    (should (equal (agent-shell-orchestrator-remove-queued (current-buffer) 1) "two"))
    (should (equal (agent-shell-orchestrator-queue (current-buffer)) '("one" "three")))
    (should-error (agent-shell-orchestrator-remove-queued (current-buffer) -1))
    (should-not submitted)
    (setq shell-maker--busy nil)
    (let ((agent-shell-prompt-queue-merge t))
      (agent-shell--prompt-queue-process-next))
    (should (equal submitted '("one\n\nthree")))
    (should (equal (agent-shell--prompt-input) "draft"))))

(ert-deftest agent-shell-orchestrator-test-startup-compatibility ()
  ;; Exercise released behavior (no automatic drain) and newer behavior.
  (dolist (auto-drain '(nil t))
    (agent-shell-orchestrator-test--shell
      (map-put! agent-shell--state :init-finished nil)
      (let (callback)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest _) (setq callback function))))
          (agent-shell-orchestrator-send (current-buffer) "initial")
          (agent-shell-orchestrator-send (current-buffer) "context")
          (should-not submitted)
          (should (= 1 (length (map-elt agent-shell--state :event-subscriptions))))
          (map-put! agent-shell--state :init-finished t)
          (funcall (map-elt (car (map-elt agent-shell--state :event-subscriptions)) :on-event)
                   '((:event . init-finished)))
          (let ((agent-shell-prompt-queue-merge t))
            (when auto-drain (agent-shell--prompt-queue-process-next))
            (funcall callback))
          (should (equal submitted '("initial\n\ncontext")))
          (should-not (agent-shell-orchestrator-queue (current-buffer)))
          (should-not agent-shell-orchestrator--startup-subscription))))))

(ert-deftest agent-shell-orchestrator-test-nonpersistent-draft ()
  (agent-shell-orchestrator-test--shell
    (let ((agent-shell-persistent-prompt-enabled nil))
      (insert "draft")
      (cl-letf (((symbol-function 'shell-maker-submit)
                 (lambda (&rest _)
                   (push (agent-shell--prompt-input) submitted)
                   (delete-region (agent-shell--prompt-input-start) (point-max))
                   (setq comint-last-prompt nil))))
        (agent-shell-orchestrator-send (current-buffer) "hello"))
      (should (equal submitted '("hello")))
      ;; A shell without a persistent prompt restores the draft at turn end.
      (let ((start (point-max)))
        (insert "Agent> ")
        (setq comint-last-prompt (cons (copy-marker start) (copy-marker (point)))))
      (run-hooks 'shell-maker-finish-output-hook)
      (should (equal (agent-shell--prompt-input) "draft")))))

(ert-deftest agent-shell-orchestrator-test-steer ()
  (agent-shell-orchestrator-test--shell
    (setq-local shell-maker--busy t)
    (should-error (agent-shell-orchestrator-send (current-buffer) "change" :delivery 'steer)
                  :type 'user-error)
    (map-put! agent-shell--state :supports-steering t)
    (let (steered)
      (cl-letf (((symbol-function 'agent-shell-experimental--send-steering)
                 (lambda (&rest args) (setq steered (plist-get args :prompt)))))
        (should (eq 'steered (plist-get (agent-shell-orchestrator-send
                                        (current-buffer) "change" :delivery 'steer)
                                       :delivery))))
      (should (equal steered "change")))
    (should-not (agent-shell-orchestrator-queue (current-buffer)))
    (map-put! agent-shell--state :init-finished nil)
    (should-error (agent-shell-orchestrator-send (current-buffer) "change" :delivery 'steer))))

(ert-deftest agent-shell-orchestrator-test-exact-targets ()
  (agent-shell-orchestrator-test--shell
    (should-error (agent-shell-orchestrator-send "missing-shell" "hello"))
    (let ((buffer (current-buffer)))
      (with-temp-buffer
        (should-error (agent-shell-orchestrator-send (current-buffer) "hello")))
      (should (= 1 (length (agent-shell-orchestrator-list :buffers (list buffer))))))
    (should-error (agent-shell-orchestrator-send (current-buffer) "hello" :delivery 'interrupt))
    (should-error (agent-shell-orchestrator-send (current-buffer) " "))))

(ert-deftest agent-shell-orchestrator-test-project-filter ()
  (agent-shell-orchestrator-test--shell
    (let ((project (expand-file-name default-directory)))
      (should (= 1 (length (agent-shell-orchestrator-list
                           :project project :buffers (list (current-buffer))))))
      (should-not (agent-shell-orchestrator-list
                   :project "/" :buffers (list (current-buffer)))))))

(ert-deftest agent-shell-orchestrator-test-list-transcripts ()
  (agent-shell-orchestrator-test--shell
    (setq-local agent-shell--transcript-file "/tmp/worker-transcript.md")
    (let ((worker (current-buffer)))
      (agent-shell-orchestrator-test--shell
        (setq-local agent-shell--transcript-file nil)
        (let* ((sessions (agent-shell-orchestrator-list
                          :buffers (list worker (current-buffer))))
               (first (car sessions))
               (second (cadr sessions)))
          (should (eq worker (plist-get first :buffer)))
          (should (equal "/tmp/worker-transcript.md"
                         (plist-get first :transcript-file)))
          (should (plist-member second :transcript-file))
          (should-not (plist-get second :transcript-file)))))))

(ert-deftest agent-shell-orchestrator-test-create ()
  (agent-shell-orchestrator-test--shell
    (let ((buffer (current-buffer))
          (directory default-directory)
          arguments)
      (cl-letf (((symbol-function 'agent-shell--start)
                 (lambda (&rest args) (setq arguments args) buffer)))
        (should (eq buffer (agent-shell-orchestrator-create directory :config 'test :prompt "hello")))
        (should (plist-get arguments :no-focus))
        (should (eq 'new (plist-get arguments :session-strategy)))
        (should (equal submitted '("hello")))
        (should-error (agent-shell-orchestrator-create directory :name (buffer-name)))
        (should-error (agent-shell-orchestrator-create directory :prompt " "))))))

(provide 'agent-shell-orchestrator-test)
;;; agent-shell-orchestrator-test.el ends here
