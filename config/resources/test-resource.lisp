(in-package :mu-cl-resources)

(define-resource test-resource ()
  :class (s-prefix "ext:TestResource")
  :properties `((:name :string ,(s-prefix "nfo:fileName")))
  :resource-base (s-url "http://data.lblod.info/test-resources/")
  :features `(include-uri)
  :on-path "files")