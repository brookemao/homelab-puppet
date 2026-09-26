# @summary Mounts the parkpack drive so Immich can read it as an external library
#
# The SELinux label comes from the context= mount option, so no files are relabelled.
# context= can't change on a remount: changing options unmounts the drive, which fails
# while Immich is running.
#
# @param device What to mount (the "Park Pack Files" partition by default)
# @param fstype Filesystem type
# @param mountpoint Where to mount it
# @param uid Owner of every file, for filesystems without Unix ownership (e.g. exfat)
# @param gid Group of every file, as for uid
# @param seltype SELinux type every file presents as; undef omits context=
# @param options Further mount options
class homelab::parkpack (
  String[1]             $device     = 'UUID=f545310e-661b-41cd-9270-5d08b25f6e22',
  String[1]             $fstype     = 'ext4',
  Stdlib::Absolutepath  $mountpoint = '/mnt/parkpack',
  Optional[Integer[0]]  $uid        = undef,
  Optional[Integer[0]]  $gid        = undef,
  Optional[String[1]]   $seltype    = 'container_ro_file_t',
  Array[String[1]]      $options    = ['nofail'],
) {
  $all_options = $options + [
    $uid ? { undef => [], default => ["uid=${uid}"] },
    $gid ? { undef => [], default => ["gid=${gid}"] },
    $seltype ? { undef => [], default => ["context=\"system_u:object_r:${seltype}:s0\""] },
  ].flatten

  # Once mounted this is the drive's root, so leave its ownership and mode alone
  file { $mountpoint:
    ensure => directory,
  }

  mount { $mountpoint:
    ensure   => mounted,
    device   => $device,
    fstype   => $fstype,
    options  => $all_options.join(','),
    atboot   => true,
    remounts => false,
    require  => File[$mountpoint],
  }
}
