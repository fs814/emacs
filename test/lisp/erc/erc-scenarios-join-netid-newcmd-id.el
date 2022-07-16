;;; erc-scenarios-join-netid-newcmd-id.el --- join netid newcmd scenarios -*- lexical-binding: t -*-

;; Copyright (C) 2022 Free Software Foundation, Inc.
;;
;; This file is part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

(require 'ert-x)
(eval-and-compile
  (let ((load-path (cons (ert-resource-directory) load-path)))
    (require 'erc-scenarios-common)))

(ert-deftest erc-scenarios-join-netid--newcmd-id ()
  :tags '(:expensive-test)
  (let ((connect (lambda ()
                   (erc :server "127.0.0.1"
                        :port (with-current-buffer "oofnet"
                                (process-contact erc-server-process :service))
                        :nick "tester"
                        :password "foonet:changeme"
                        :full-name "tester"
                        :id 'oofnet))))
    (erc-scenarios-common--join-network-id connect 'oofnet nil)))

(ert-deftest erc-scenarios-join-netid--newcmd-ids ()
  :tags '(:expensive-test)
  (let ((connect (lambda ()
                   (erc :server "127.0.0.1"
                        :port (with-current-buffer "oofnet"
                                (process-contact erc-server-process :service))
                        :nick "tester"
                        :password "foonet:changeme"
                        :full-name "tester"
                        :id 'oofnet))))
    (erc-scenarios-common--join-network-id connect 'oofnet 'rabnet)))

;;; erc-scenarios-join-netid-newcmd-id.el ends here
