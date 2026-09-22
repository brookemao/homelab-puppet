# @summary An absolute Unix path.
#
# Local equivalent of Stdlib::Absolutepath, so this module needs no stdlib.
type Immich::Absolutepath = Pattern[/\A\/([^\n\/\0]+\/*)*\z/]
