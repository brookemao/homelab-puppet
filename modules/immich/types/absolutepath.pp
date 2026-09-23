# @summary An absolute Unix path, with no trailing or repeated slashes.
#
# Local equivalent of Stdlib::Absolutepath, so this module needs no stdlib.
# Unlike Stdlib::Absolutepath, this type does not allow trailing slashes.
type Immich::Absolutepath = Pattern[/\A\/([^\n\/\0]+(\/[^\n\/\0]+)*)?\z/]
