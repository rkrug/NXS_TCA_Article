qs2_format <- function() {
  targets::tar_format(
    read = function(path) qs2::qs_read(path),
    write = function(object, path) qs2::qs_save(object, path),
    marshal = function(object) object,
    unmarshal = function(object) object
  )
}
