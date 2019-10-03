(in-package #:cl-quil)

;;; Calibration Expansion
;;;
;;; This looks a lot like circuit expansion, and under the hood a lot of the
;;; mechanics are the same. A few differences are worth pointing out:
;;;
;;;   - The task of finding a calibration that matches a measurement or gate application
;;;     is a bit more complicated than what is done for circuit expansion (namely,
;;;     multiple definitions are allowed, with match priority given to later definitions).
;;;   - If *REQUIRE-APPLICABLE-CALIBRATION* is set, then the expansion must terminate in
;;;     non-(gate application, measure, measure discard) instructions.

(define-transform expand-calibrations (expand-calibrations)
  "This transform applies all available calibrations. The result has no gate applications or measurements for which a calibration is defined."
  expand-circuits)

(defvar *require-applicable-calibration* t
  "If T, an error will be signalled if an instruction fails to match an applicable calibration during calibration expansion.")

(defgeneric calibration-matches-p (defn instr)
  (:documentation "Check whether the calibration definition DEFN applies to the given instruction INSTR.")
  ;; The default is to not match.
  (:method (defn instr)
    nil)

  (:method ((defn gate-calibration-definition) (instr gate-application))
    (flet ((params-match (app-params cal-params)
               (and (= (length app-params)
                       (length cal-params))
                    (every (lambda (app-param cal-param)
                             (if (is-constant cal-param)
                                 (equalp app-param cal-param)
                                 (is-param cal-param)))
                           app-params
                           cal-params)))
             (args-match (app-args cal-args)
               (and (= (length app-args)
                       (length cal-args))
                    (every (lambda (app-arg cal-arg)
                             (if (qubit-p cal-arg)
                                 (equalp app-arg cal-arg)
                                 (is-formal cal-arg)))
                           app-args
                           cal-args))))
      (and (operator-description-equalp (application-operator instr)
                                        (calibration-definition-operator defn))
           (params-match (application-parameters instr)
                         (calibration-definition-parameters defn))
           (args-match (application-arguments instr)
                       (calibration-definition-arguments defn)))))

  (:method ((defn measure-calibration-definition) (instr measure))
    ;; Check that the measurement qubit matches, and the address matches.
    (and (if (qubit-p (measurement-calibration-qubit defn))
             (equalp (measurement-qubit instr) (measurement-calibration-qubit defn))
             (is-formal (measurement-calibration-qubit defn)))
         (is-formal (measure-calibration-address defn))))

  (:method ((defn measure-discard-calibration-definition) (instr measure-discard))
    ;; Just check that the measurement qubit matches.
    (if (qubit-p (measurement-calibration-qubit defn))
        (equalp (measurement-qubit instr) (measurement-calibration-qubit defn))
        (is-formal (measurement-calibration-qubit defn)))))

(defun compute-calibration-tables (parsed-program)
  "Extract the calibration definitions from PARSED-PROGRAM. Returns three values:

1. a hash table of gate calibrations (keyed by OPERATOR-DESCRIPTION),

2. a list of measure calibrations,

3. a list of measure discard calibrations."
  (let ((gate-calibrations
          (make-hash-table :test #'operator-description-equalp
                           :hash-function #'operator-description-hash))
        (measure-calibrations nil)
        (measure-discard-calibrations nil))
    (dolist (defn (parsed-program-calibration-definitions parsed-program))
      ;; Assuming that the calibration definitions are in the same order
      ;; as their position in the quilt program, this will put them in
      ;; reverse order.
      (etypecase defn
        (gate-calibration-definition
         (push defn (gethash (calibration-definition-operator defn)
                             gate-calibrations)))
        (measure-calibration-definition
         (push defn measure-calibrations))
        (measure-discard-calibration-definition
         (push defn measure-discard-calibrations))))
    (values gate-calibrations
            measure-calibrations
            measure-discard-calibrations)))

(defgeneric instantiate-applicable-calibration (instr gate-cals measure-cals measure-discard-cals)
  (:documentation "If INSTR has an associated calibration, return a list of instructions instantiated from the body of the calibration definition. Otherwise, return NIL.")

  (:method ((instr gate-application) gate-cals measure-cals measure-discard-cals)
    (declare (ignore measure-cals measure-discard-cals))
    (let ((op (application-operator instr)))
      (unless (plain-operator-p op)
        (return-from instantiate-applicable-calibration nil))

      (a:if-let ((defn (find-if (lambda (defn) (calibration-matches-p defn instr))
                                (gethash op gate-cals))))
        (instantiate-definition defn
                                (application-parameters instr)
                                (application-arguments instr))
        nil)))

  (:method ((instr measure) gate-cals measure-cals measure-discard-cals)
    (declare (ignore gate-cals measure-discard-cals))
    (a:if-let ((defn (find-if (lambda (defn) (calibration-matches-p defn instr))
                              measure-cals)))
      (instantiate-definition defn
                              nil
                              (list (measurement-qubit instr)
                                    (measure-address instr)))
      nil))

  (:method ((instr measure-discard) gate-cals measure-cals measure-discard-cals)
    (declare (ignore gate-cals measure-cals))
    (a:if-let ((defn (find-if (lambda (defn) (calibration-matches-p defn instr))
                              measure-discard-cals)))
      (instantiate-definition defn
                              nil
                              (list (measurement-qubit instr)))
      nil))

  (:method (instr gate-cals measure-cals measure-discard-cals)
    nil))

(defun recursively-expand-instruction (instr gate-cals measure-cals measure-discard-cals)
  (let ((*expansion-depth* (1+ *expansion-depth*)))
    (unless (<= *expansion-depth* *expansion-limit*)
      (quil-parse-error "Exceeded recursion limit of ~D for calibration expansion. ~
                         Current object being expanded is ~A."
                        *expansion-limit*
                        instr))
    (a:if-let ((expanded (instantiate-applicable-calibration instr gate-cals measure-cals measure-discard-cals)))
      ;; Recursively expand the new instructions
      (a:mappend (lambda (instr)
                   (recursively-expand-instruction instr
                                                   gate-cals
                                                   measure-cals
                                                   measure-discard-cals))
                 expanded)
      ;; Otherwise, handle the base case.
      (if (and *require-applicable-calibration*
               (typep instr '(or gate-application measurement)))
          (quil-expansion-error "Expected a calibration definition associated with ~A, but none was found."
                                instr)
          (list instr)))))

(defun expand-calibrations (parsed-program)
  "Expand all gate applications and measurements in PARSED-PROGRAM for which there is a corresponding calibration definition."
  (multiple-value-bind (gate-cals measure-cals measure-discard-cals)
      (compute-calibration-tables parsed-program)
    (let ((*expansion-context* ':DEFCAL)
          (*expansion-depth* 0))
      (let ((expanded
              (loop :for instr :across (parsed-program-executable-code parsed-program)
                    :for expanded-instrs := (recursively-expand-instruction instr
                                                                            gate-cals
                                                                            measure-cals
                                                                            measure-discard-cals)
                    ;; we need to resolve the new instructions (e.g. since frame
                    ;; `0 q "cz"` might instantiate to to `0 1 "cz"`)
                    :append (mapcar (lambda (i) (resolve-instruction i parsed-program))
                                    expanded-instrs))))
        (setf (parsed-program-executable-code parsed-program)
              (coerce expanded 'vector)))))
  parsed-program)