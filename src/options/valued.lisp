;;; valued.lisp --- Valued options

;; Copyright (C) 2010 Didier Verna

;; Author:        Didier Verna <didier@lrde.epita.fr>
;; Maintainer:    Didier Verna <didier@lrde.epita.fr>
;; Created:       Tue Oct  7 21:25:03 2008
;; Last Revision: Sat Jun 12 18:25:34 2010

;; This file is part of Clon.

;; Clon is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License version 3,
;; as published by the Free Software Foundation.

;; Clon is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.


;;; Commentary:

;; Contents management by FCM version 0.1.


;;; Code:

(in-package :com.dvlsoft.clon)
(in-readtable :com.dvlsoft.clon)


;; ==========================================================================
;; The Valued Option Class
;; ==========================================================================

(defabstract valued-option (option)
  ((argument-name :documentation "The option's argument display name."
		  :initarg :argument-name
		  :initform "ARG"
		  :reader argument-name)
   (argument-required-p :documentation "Whether the option's argument is required."
			;; Initialization :after wards by :argument-type
			:reader argument-required-p)
   (fallback-value :documentation "The option's fallback value."
		   :initarg :fallback-value
		   :reader fallback-value)
   (default-value :documentation "The option's default value."
		 :initarg :default-value
		 :reader default-value)
   (nullablep :documentation "Whether this option's value can be nil."
	      :initarg :nullablep
	      :initform nil
	      :reader nullablep))
  (:default-initargs
    :argument-type :required)
  (:documentation "The VALUED-OPTION class.
This is the base class for options accepting arguments."))


;; ----------------------
;; Option search protocol
;; ----------------------

(defmethod option-sticky-distance ((option valued-option) namearg)
  "Try to match OPTION's short name with a sticky argument against NAMEARG.
If OPTION matches, return its short name's length; otherwise 0."
  (with-slots (short-name) option
    (cond ((and short-name (beginning-of-string-p short-name namearg))
	   ;; This case should not happen because we always look for a
	   ;; complete match before looking for a sticky match.
	   (assert (not (string= namearg short-name)))
	   (length short-name))
	  (t
	   0))))


;; -------------------
;; Char packs protocol
;; -------------------

;; Options with a one-character short name and requiring an argument may
;; appear as the last option in a minus pack. However, we don't make them
;; appear in the usage string. This is why this function filters out options
;; with mandatory argument.
(defmethod minus-pack-char ((option valued-option) &optional as-string)
  "Return OPTION's minus pack character if OPTION's argument is optional."
  (unless (argument-required-p option)
    (potential-pack-char option as-string)))


;; ---------------------------
;; Help specification protocol
;; ---------------------------

(defgeneric short-syntax-help-spec-prefix (option)
  (:documentation "Return the help specification prefix for OPTION's short call.")
  (:method ((option valued-option))
    "-"))

(defmethod help-spec ((option valued-option) &key)
  "Return OPTION's help specification."
  (accumulate (option)
    (accumulate (syntax)
      (accumulate (short)
	(accumulate (name)
	  (when (short-name option)
	    (format nil "~A~A"
	      (short-syntax-help-spec-prefix option)
	      (short-name option))))
	(accumulate (argument)
	  (when (and (short-name option) (not (long-name option)))
	    (format nil "~:[[~A]~:;~A~]"
	      (argument-required-p option)
	      (argument-name option)))))
      (accumulate (long)
	(accumulate (name)
	  (when (long-name option)
	    (format nil "--~A" (long-name option))))
	(accumulate (argument)
	  (when (long-name option)
	    (format nil "~:[[=~A]~:;=~A~]"
	      (argument-required-p option)
	      (argument-name option))))))
    (accumulate (usage)
      (accumulate (description)
	(description option))
      ;; #### FIXME: for the 2 cases below, we should have specialized methods
      ;; for outputting the printed representation of values. The default one
      ;; is not cool; we should probably print not the /values/, but their
      ;; /argument/ form, before conversion (hence we would required the
      ;; inverse of the conversion function !!).
      (when (slot-boundp option 'fallback-value)
	`(fallback
	  (header "Fallback:")
	  (value ,(format nil "~A" (fallback-value option)))))
      (when (slot-boundp option 'default-value)
	`(default
	  (header "Default:")
	  (value ,(format nil "~A" (default-value option)))))
      (when (env-var option)
	`(environment
	  (header "Environment:")
	  (variable ,(env-var option)))))))



;; ==========================================================================
;; The Conversion Protocol
;; ==========================================================================

;; ---------------------------
;; The value check subprotocol
;; ---------------------------

;; #### FIXME: this protocol is currently used to check for the validity of
;; fallback values, default values, and values provided from a debugger
;; restart. We should also use it to check converted values.

(define-condition invalid-value (option-error)
  ((value :documentation "The invalid value."
	  :initarg :value
	  :reader value)
   (comment :documentation "An additional comment about the error."
	    :type string
	    :initarg :comment
	    :reader comment))
  (:report (lambda (error stream)
	     (format stream "Option ~A: invalid value ~S.~@[~%~A~]"
	       (option error) (value error) (comment error))))
  (:documentation "An invalid value error."))


;; #### FIXME: should we just call this check, as for convert ?

(defgeneric check-value (valued-option value)
  (:documentation "Check that VALUE is valid for VALUED-OPTION.
If VALUE is valid, return it. Otherwise, raise an invalid-value error.")
  (:method :around ((option valued-option) value)
    "Bypass the provided user method if VALUE is nil and OPTION is nullable."
    ;; #### NOTE: check-value must return the value if it is valid. This is
    ;; exactly what happens below when the unless clause fails (it returns
    ;; nil).
    (unless (and (nullablep option) (null value))
      (call-next-method))))

(defun read-value ()
  "Read an option value from standard input."
  (format t "Please type in the new value:~%")
  (list (read)))

(defun restartable-check-value (valued-option value)
  "Restartably check that VALUE is valid for VALUED-OPTION.
The only restart available, use-value, offers to try a different value from
the one that was provided."
  (restart-case (check-value valued-option value)
    (use-value (value)
      :report "Use another value instead."
      :interactive read-value
      (restartable-check-value valued-option value))))


;; ------------------------------
;; The argument check subprotocol
;; ------------------------------

(define-condition invalid-argument (option-error)
  ((argument :documentation "The invalid argument."
	     :type string
	     :initarg :argument
	     :reader argument)
   (comment :documentation "An additional comment about the error."
	    :type string
	    :initarg :comment
	    :reader comment))
  (:report (lambda (error stream)
	     (format stream "Option ~A: invalid argument ~S.~@[~%~A~]"
	       (option error) (argument error) (comment error))))
  (:documentation "An invalid argument error."))

(defgeneric convert (valued-option argument)
  (:documentation "Convert ARGUMENT to VALUED-OPTION's value.
If ARGUMENT is invalid, raise an invalid-argument error."))

(defun read-argument ()
  "Read an option argument from standard input."
  (format t "Please type in the new argument:~%")
  (list (read-line)))

;; #### NOTE: the restarts provided here are actually not used because
;; conversion errors are caught by a handler-case in the retrieval routines,
;; which provide higher-level errors and restarts. I leave them here however,
;; because they might be useful for debugging.
(defun restartable-convert (valued-option argument)
  "Restartably convert ARGUMENT to VALUED-OPTION's value.
Available restarts are:
- use-default-value: return OPTION's default value,
- use-value: return another (already converted) value,
- use-argument: return the conversion of another argument."
  (restart-case (convert valued-option argument)
    (use-default-value ()
      :test (lambda (error)
	      (declare (ignore error))
	      (slot-boundp valued-option 'default-value))
      :report (lambda (stream)
		(format stream "Use option's default value (~S) instead."
		  (default-value valued-option)))
      (default-value valued-option))
    (use-value (value)
      :report "Use another (already converted) value."
      :interactive read-value
      (restartable-check-value valued-option value))
    (use-argument (argument)
      :report "Use another (to be converted) argument."
      :interactive read-argument
      (restartable-convert valued-option argument))))



;; ==========================================================================
;; Valued Option Instance Creation
;; ==========================================================================

(defmethod initialize-instance :before
    ((option valued-option) &key argument-type
			       (fallback-value nil fallback-value-supplied-p)
			       (default-value nil default-value-supplied-p))
  (declare (ignore fallback-value default-value))
  "Check validity of the value-related initargs."
  (unless (member argument-type '(:required :mandatory :optional))
    (error "Option ~A: invalid argument type ~S." option argument-type))
  (when (and (not (eq argument-type :optional))
	     fallback-value-supplied-p)
    (warn "Option ~A: fallback value supplied for required argument." option))
  (when (and (eq argument-type :optional)
	     (not fallback-value-supplied-p)
	     (not default-value-supplied-p))
    (error "Option ~A: fallback or default value required for optional argument."
	   option)))

(defmethod initialize-instance :after
    ((option valued-option) &key argument-type
			       (fallback-value nil fallback-value-supplied-p)
			       (default-value nil default-value-supplied-p))
  "Compute uninitialized OPTION slots with indirect initargs.
This currently involves the conversion of the ARGUMENT-TYPE key to the
ARGUMENT-REQUIRED-P slot."
  (ecase argument-type
    ((:required :mandatory)
     (setf (slot-value option 'argument-required-p) t))
    (:optional
     (setf (slot-value option 'argument-required-p) nil)))
  ;; #### NOTE: previously, I performed the validity checks on FALLBACK-VALUE
  ;; and DEFAULT-VALUE in the :before method, which feels better. However,
  ;; when the ENUM option class appeared, I realized that option values could
  ;; depend on an option slot (the ENUM slot ikn that case), so we need to
  ;; delay this check until right here.
  ;; Here, we catch and convert a potential invalid-value error into a simple
  ;; error because this check is intended for the Clon user, as opposed to the
  ;; Clon end-user. In other words, a potential error here is in the program
  ;; itself; not in the usage of the program.
  (when fallback-value-supplied-p
    (handler-case (check-value option fallback-value)
      (invalid-value ()
	(error "Option ~A: invalid fallback value ~S." option fallback-value))))
  (when default-value-supplied-p
    (handler-case (check-value option default-value)
      (invalid-value ()
	(error "Option ~A: invalid default value ~S." option default-value)))))

(defmacro defoption (class superclasses slots &rest options)
  "Wrapper around defclass for defining a new Clon valued option class."
  `(defclass ,class (,@superclasses valued-option)
    ,slots
    ,@options))


;;; valued.lisp ends here
