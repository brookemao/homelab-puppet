# nginx_uid fact: numeric UID of the local nginx account.
#
# Used by homelab::firewall to build owner-match egress rules: firewalld
# applies direct rules through the nftables iptables-restore compat layer,
# which rejects usernames in --uid-owner ('Bad value'), so the numeric UID
# is required. Absent when the nginx account does not exist yet (e.g. fresh
# host where nginx gets installed later in the same run); callers must
# handle undef.
Facter.add(:nginx_uid) do
  setcode do
    require 'etc'
    begin
      Etc.getpwnam('nginx').uid
    rescue ArgumentError
      nil
    end
  end
end
