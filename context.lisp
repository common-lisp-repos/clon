;;; context.lisp --- Context management for Clon

;; Copyright (C) 2008 Didier Verna

;; Author:        Didier Verna <didier@lrde.epita.fr>
;; Maintainer:    Didier Verna <didier@lrde.epita.fr>
;; Created:       Tue Jul  1 16:08:02 2008
;; Last Revision: Tue Jul  1 16:08:02 2008

;; This file is part of Clon.

;; Clon is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2 of the License, or
;; (at your option) any later version.

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

(in-package :clon)


;; ============================================================================
;; The Command Line Option Structure
;; ============================================================================

(defstruct cmdline-option
  name ;; the option's name as used on the cmdline
  option ;; the corresponding option object
  value ;; the converted option's cmdline value
  status ;; the conversion status
  )


;; ============================================================================
;; The Context Class
;; ============================================================================

;; #### FIXME: make final
(defclass context ()
  ((synopsis :documentation "The program synopsis."
	     :type synopsis
	     :reader synopsis
	     :initarg :synopsis)
   (progname :documentation
	     "The program name, as it appears on the command line."
	     :type string
	     :reader progname)
   (calls :documentation "The option calls."
	  :type list
	  :accessor calls)
   (remainder :documentation "The non-Clon part of the argument list."
	      :type list
	      :reader remainder)
   (junk :documentation "The unidentified part of the argument list."
	 :type list
	 :reader junk))
  (:default-initargs
      ;; #### FIXME: SBCL specific
      :cmdline sb-ext:*posix-argv*)
  (:documentation "The CONTEXT class.
This class holds the necessary information to process a particular set of
command-line options."))

(defmethod initialize-instance :before ((context context) &key synopsis cmdline)
  "Ensure that SYNOPSIS is sealed."
  (declare (ignore cmdline))
  (unless (sealedp synopsis)
    (error "Initializing context ~A: synopsis ~A not sealed." context synopsis)))

(defmethod initialize-instance :after ((context context) &key synopsis cmdline)
  "Parse CMDLINE."
  (declare (ignore synopsis))
  (setf (slot-value context 'progname) (pop cmdline))
  (let ((calls (list))
	(remainder (list))
	(junk (list)))
    (macrolet ((push-cmdline-option (calls &rest body)
		 "Push a new CMDLINE-OPTION created with BODY onto CALLS."
		 `(push (make-cmdline-option ,@body) ,calls))
	       (push-retrieved-option
		   (func calls option &optional cmdline-value cmdline name-form)
		   "Retrieve OPTION from a FUNC call and push it onto CALLS.
- FUNC must be either :long, :short or :plus,
- CMDLINE-VALUE is a potentially already parsed option argument,
- CMDILNE is where to find a potentially required argument,
- NAME-FORM is how to compute the :name slot of the CMDLINE-OPTION structure.
  If not given, the option's long or short name will be used as appropriate."
		   (let* ((value (gensym "value"))
			  (status (gensym "status"))
			  (vars (list status value))
			  (call (list option
				      (find-symbol (concatenate 'string
						     "RETRIEVE-FROM-"
						     (symbol-name func)
						     "-CALL")
						   'clon)))
			  new-cmdline)
		     (unless name-form
		       (setq name-form
			     (ecase func
			       (:long `(long-name ,option))
			       (:short `(short-name ,option))
			       (:plus `(short-name ,option)))))
		     (when cmdline-value
		       (push cmdline-value call))
		     (when cmdline
		       (setq new-cmdline (gensym "new-cmdline"))
		       (push new-cmdline vars)
		       (unless cmdline-value
			 (push nil call))
		       (push cmdline call))
		     `(multiple-value-bind ,(reverse vars) ,(reverse call)
		       ,(when cmdline `(setq ,cmdline ,new-cmdline))
		       (push-cmdline-option ,calls
			 :name ,name-form
			 :option ,option
			 :value ,value
			 :status ,status))))
	       (do-pack ((option pack context) &body body)
		 "Evaluate BODY with OPTION bound to each option from PACK.
CONTEXT is where to look for the options."
		 (let ((char (gensym "char"))
		       (name (gensym "name")))
		   `(loop :for ,char :across ,pack
		     :do (let* ((,name (make-string 1 :initial-element ,char))
				(,option (search-option ,context
					   :short-name ,name)))
			   (assert ,option)
			   ,@body)))))
      (do ((arg (pop cmdline) (pop cmdline)))
	  ((null arg))
	(cond ((string= arg "--")
	       ;; The Clon separator.
	       (setq remainder cmdline)
	       (setq cmdline nil))
	      ((string-start arg "--")
	       ;; A long call.
	       (let* ((value-start (position #\= arg :start 2))
		      (cmdline-name (subseq arg 2 value-start))
		      (cmdline-value (when value-start
				       (subseq arg (1+ value-start))))
		      option name)
		 (multiple-value-setq (option name)
		   (or (search-option context :long-name cmdline-name)
		       (search-option context :partial-name cmdline-name)))
		 (if option
		     (push-retrieved-option :long calls option
		       cmdline-value cmdline name)
		     (push-cmdline-option calls
		       :name cmdline-name
		       :value cmdline-value))))
	      ;; A short call, or a minus pack.
	      ((string-start arg "-")
	       ;; #### FIXME: check invalid syntax -foo=val
	       (let ((cmdline-name (subseq arg 1))
		     option cmdline-value)
		 (multiple-value-setq (option cmdline-value)
		   (or (search-option context :short-name cmdline-name)
		       (search-sticky-option context cmdline-name)))
		 (cond (option
			(push-retrieved-option :short calls option
			  cmdline-value cmdline))
		       ((potential-pack-p cmdline-name context)
			;; #### NOTE: When parsing a minus pack, only the last
			;; option gets a cmdline argument because only the
			;; last one is allowed to retrieve an argument from
			;; there.
			(do-pack (option
				  (subseq cmdline-name 0
					  (1- (length cmdline-name)))
				  context)
			  (push-retrieved-option :short calls option))
			(let* ((name (subseq cmdline-name
					     (1- (length cmdline-name))))
			       (option (search-option context :short-name name)))
			  (assert option)
			  (push-retrieved-option :short calls option
			    nil cmdline)))
		       (t
			(push-cmdline-option calls :name cmdline-name)))))
	      ;; A plus call or a plus pack.
	      ((string-start arg "+")
	       ;; #### FIXME: check invalid syntax +foo=val
	       (let* ((cmdline-name (subseq arg 1))
		      ;; #### NOTE: in theory, we could allow partial matches
		      ;; on short names when they're used with the +-syntax,
		      ;; because there's no sticky argument or whatever. But
		      ;; we don't. That's all. Short names are not meant to be
		      ;; long (otherwise, that would be long names right?), so
		      ;; they're not meant to be abbreviated.
		      (option (search-option context :short-name cmdline-name)))
		 (cond (option
			(push-retrieved-option :plus calls option))
		       ((potential-pack-p cmdline-name context)
			(do-pack (option cmdline-name context)
			  (push-retrieved-option :plus calls option)))
		       (t
			(push-cmdline-option calls :name cmdline-name)))))
	      (t
	       ;; Not an option call.
	       ;; #### FIXME: SBCL specific.
	       (cond ((sb-ext:posix-getenv "POSIXLY_CORRECT")
		      ;; That's the end of the Clon-specific part:
		      (setq remainder (cons arg cmdline))
		      (setq cmdline nil))
		     (t
		      ;; If there's no more option on the cmdline, consider
		      ;; this as the remainder (implicit since no "--" has
		      ;; been used). If there's still another option
		      ;; somewhere, then this is really junk.
		      (cond ((notany #'option-p cmdline)
			     (setq remainder (cons arg cmdline))
			     (setq cmdline nil))
			    (t
			     (push arg junk))))))))
      (setf (calls context) (nreverse calls))
      (setf (slot-value context 'remainder) remainder)
      (setf (slot-value context 'junk) junk))))

;; #### FIXME: SBCL-specific
(defun make-context (&rest keys &key synopsis cmdline)
  "Make a new context.
- SYNOPSIS is the program synopsis to use in that context.
- CMDLINE is the argument list (strings) to process.
  It defaults to a POSIX conformant argv."
  (declare (ignore synopsis cmdline))
  (apply #'make-instance 'context keys))


;; -----------------------
;; Potential pack protocol
;; -----------------------

(defmethod potential-pack-p (pack (context context))
  "Return t if PACK (a string) is a potential pack in CONTEXT."
  (potential-pack-p pack (synopsis context)))


;; -------------------------
;; Option searching protocol
;; -------------------------

(defmethod search-option
    ((context context) &rest keys &key short-name long-name partial-name)
  "Search for option in CONTEXT."
  (declare (ignore short-name long-name partial-name))
  (apply #'search-option (synopsis context) keys))

(defmethod search-sticky-option ((context context) namearg)
  "Search for a sticky option in CONTEXT."
  (search-sticky-option (synopsis context) namearg))


;; ============================================================================
;; The Option retrieval Protocol
;; ============================================================================

(defun getopt (context &rest keys &key short-name long-name option)
  "Get an option's value in CONTEXT.
The option can be specified either by SHORT-NAME, LONG-NAME, or directly via
an OPTION object."
  (unless option
    (setq option (apply #'search-option context keys)))
  (unless option
    (error "Getting option ~S from synopsis ~A in context ~A: unknown option."
	   (or short-name long-name)
	   (synopsis context)
	   context))
  ;; Try the command line:
  (let ((calls (list)))
    (do ((call (pop (calls context)) (pop (calls context))))
	((null call))
      ;; #### NOTE: actually, I *do* have a use for nreconc, he he ;-)
      (cond ((eq (cmdline-option-option call) option)
	     (setf (calls context) (nreconc calls (calls context)))
	     (return-from getopt (values (cmdline-option-value call)
					 (or (eq (cmdline-option-status call) t)
					     (cons (cmdline-option-name call)
						   (cmdline-option-status call)))
					 :cmdline)))
	    (t
	     (push call calls))))
    (setf (calls context) (nreverse calls)))
  ;; Otherwise, fallback to the environment or a default value:
  (fallback-retrieval option))


;;; context.lisp ends here
