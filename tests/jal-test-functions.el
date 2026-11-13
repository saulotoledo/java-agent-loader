;;; jal-test-functions.el --- Temporary test function bindings -*- lexical-binding: t; -*-

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <https://www.gnu.org/licenses/>.

;; Author: Saulo Toledo <saulotoledo@gmail.com>


(defun jal-test--call-with-functions (bindings thunk)
  "Call THUNK with function BINDINGS, restoring definitions on exit."
  (let ((saved (mapcar (lambda (binding)
                         (cons (car binding) (symbol-function (car binding))))
                       bindings)))
    (unwind-protect
        (progn
          (dolist (binding bindings) (fset (car binding) (cdr binding)))
          (funcall thunk))
      (dolist (binding saved) (fset (car binding) (cdr binding))))))

(defmacro jal-test--with-functions (bindings &rest body)
  "Run BODY with temporary function BINDINGS."
  (declare (indent 1))
  `(jal-test--call-with-functions
    (list ,@(mapcar (lambda (binding) `(cons ',(car binding) ,(cadr binding))) bindings))
    (lambda () ,@body)))

(provide 'jal-test-functions)
;;; jal-test-functions.el ends here
